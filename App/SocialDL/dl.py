#!/usr/bin/env python3
"""Paste a public TikTok / Douyin / Xiaohongshu share link and save the original media.

This tool requests the source file the platform already serves for playback.
It does not crop or inpaint watermarks, and it only works on public posts.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from html import unescape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional
from urllib.parse import parse_qs, quote, unquote, urlparse
from urllib.request import Request, urlopen

from curl_cffi import requests as cffi_requests

import subtitles as subs

UA_PC = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
UA_MOBILE = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)

URL_RE = re.compile(r"https?://[^\s\"'<>，。！？、；：）】》]+", re.I)
BATCH_LIMIT = 40
PROFILE_LIMIT_DEFAULT = 20
PROFILE_LIMIT_MAX = 40
ILLEGAL_FS = re.compile(r'[\\/:*?"<>|\n\r\t]+')
XHS_FILE_ID_RE = re.compile(
    r"https?://sns-webpic[^/]*\.xhscdn\.com/\d+/[0-9a-z]+/([^!]+?)!",
    re.I,
)
XHS_NOTE_RE = re.compile(
    r"/(?:explore|discovery/item|user/profile/[^/]+)/([0-9a-f]{24})",
    re.I,
)
XHS_PROFILE_RE = re.compile(r"/user/profile/([0-9a-f]{24})/?$", re.I)
DOUYIN_USER_RE = re.compile(r"douyin\.com/user/([A-Za-z0-9_-]+)/?(?:\?|$)", re.I)
AWEME_ID_RE = re.compile(r"(?:video|note|share/video|photo|embed/v2|embed)/(\d{8,})", re.I)
BROWSER_PROFILE_PATH = Path(__file__).resolve().parent / ".browser-profile"
BROWSER_LOCK = threading.Lock()
XHS_HOSTS = (
    "xiaohongshu.com",
    "xiaohongshu.cn",
    "xhslink.com",
    "xhslink.cn",
    "rednote.com",
    "rednote.cn",
)


XHS_VIDEO_HOSTS = (
    "sns-bak-v1.xhscdn.com",
    "sns-video-bd.xhscdn.com",
    "sns-video-hw.xhscdn.com",
    "sns-video-al.xhscdn.com",
    "sns-video-qc.xhscdn.com",
    "sns-video-v6.xhscdn.com",
)


@dataclass
class MediaItem:
    url: str
    kind: str  # video | image | live
    ext: str = "bin"
    index: int = 1
    backups: list[str] = field(default_factory=list)


@dataclass
class ParseResult:
    platform: str
    content_id: str
    title: str
    author: str = ""
    description: str = ""
    items: list[MediaItem] = field(default_factory=list)
    extra: dict[str, Any] = field(default_factory=dict)


class FetchError(RuntimeError):
    def __init__(self, message: str, needs_login: str = ""):
        super().__init__(message)
        # Platform key when the failure is a login wall, so the panel can offer
        # to open that site's login page instead of telling the user to re-copy.
        self.needs_login = needs_login


# yt-dlp / platform wording that means "we need a signed-in session", not "bad link".
LOGIN_WALL_RE = re.compile(
    r"login required|rate.?limit|locked behind the login|requested content is not available"
    r"|sign in to confirm|private video|account.*private|需要登录|请先登录",
    re.I,
)

# Where to send the user so the cookie-source browser picks up a session.
LOGIN_URLS = {
    "instagram": "https://www.instagram.com/accounts/login/",
    "youtube": "https://accounts.google.com/ServiceLogin?service=youtube",
    "tiktok": "https://www.tiktok.com/login",
    "bilibili": "https://passport.bilibili.com/login",
    "kuaishou": "https://passport.kuaishou.com/pc/account/login/?sid=kuaishou.server.web",
    "douyin": "https://www.douyin.com/",
    "xiaohongshu": "https://www.xiaohongshu.com/explore",
}

# `--cookies-from-browser` value -> macOS application name.
BROWSER_APPS = {
    "chrome": "Google Chrome",
    "chromium": "Chromium",
    "brave": "Brave Browser",
    "edge": "Microsoft Edge",
    "safari": "Safari",
    "firefox": "Firefox",
    "opera": "Opera",
    "vivaldi": "Vivaldi",
}


ROOT_DIR = Path(__file__).resolve().parent
ASR_PYTHON = ROOT_DIR / ".asr" / "bin" / "python"
TRANSCRIBE_SCRIPT = ROOT_DIR / "transcribe.py"
TRANSCRIPT_JSON = "transcript.json"
TRANSCRIPT_MD = "逐字稿.md"
TRANSCRIBABLE = {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".m4a", ".mp3", ".wav", ".aac", ".flac", ".ogg"}


def transcribe_ready() -> bool:
    return ASR_PYTHON.exists() and TRANSCRIBE_SCRIPT.exists()


class AsrWorker:
    """托管常驻转写子进程。

    转写要在 .asr 那个 venv 里跑（本 venv 没有 funasr），所以只能走子进程。
    模型加载要十几秒，而转写默认是开的，所以进程拉起来就不放，让模型常驻。
    """

    def __init__(self, device: str = "mps"):
        self.device = device
        self.proc: Optional[subprocess.Popen] = None
        self.lock = threading.Lock()
        self._seq = 0

    def _alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def _spawn(self) -> None:
        env = dict(os.environ)
        env["FUNASR_DEVICE"] = self.device
        env.setdefault("PYTHONUNBUFFERED", "1")
        self.proc = subprocess.Popen(
            [str(ASR_PYTHON), str(TRANSCRIBE_SCRIPT), "--worker", "--device", self.device],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,  # funasr 的进度条噪音很大，丢掉
            env=env,
            text=True,
            encoding="utf-8",
            cwd=str(ROOT_DIR),
        )
        # 等 worker 报 ready，否则第一条任务可能写进还没起来的管道
        line = self.proc.stdout.readline()
        if not line:
            raise FetchError("转写进程没能启动。")

    def transcribe(self, media: Path, progress: Any = None) -> dict[str, Any]:
        with self.lock:
            if not self._alive():
                self._spawn()
            assert self.proc and self.proc.stdin and self.proc.stdout
            self._seq += 1
            job = str(self._seq)
            self.proc.stdin.write(json.dumps({"job": job, "media": str(media)}) + "\n")
            self.proc.stdin.flush()

            while True:
                line = self.proc.stdout.readline()
                if not line:
                    self.proc = None
                    raise FetchError("转写进程意外退出。")
                try:
                    event = json.loads(line)
                except Exception:
                    continue
                kind = event.get("type")
                if kind == "progress":
                    if progress:
                        progress(str(event.get("detail") or ""))
                elif kind == "result":
                    return event.get("result") or {}
                elif kind == "error":
                    raise FetchError(str(event.get("error") or "转写失败"))

    def shutdown(self) -> None:
        with self.lock:
            if self._alive() and self.proc and self.proc.stdin:
                try:
                    self.proc.stdin.close()
                    self.proc.wait(timeout=5)
                except Exception:
                    self.proc.kill()
            self.proc = None


ASR_WORKER = AsrWorker()


def pick_transcribable(folder: Path) -> Optional[Path]:
    """挑作品目录里最值得转写的文件：有音轨的那个，取最大的。"""
    if not folder.is_dir():
        return None
    files = [
        p for p in folder.iterdir()
        if p.is_file() and p.suffix.lower() in TRANSCRIBABLE
    ]
    if not files:
        return None
    files.sort(key=lambda p: p.stat().st_size, reverse=True)
    return files[0]


def read_transcript(folder: Path) -> Optional[dict[str, Any]]:
    path = folder / TRANSCRIPT_JSON
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def transcript_brief(folder: Path) -> Optional[dict[str, Any]]:
    """给列表用的轻量摘要。整篇文稿按需再取，不然历史接口会很胖。"""
    data = read_transcript(folder)
    if data is None:
        return None
    text = data.get("text") or ""
    return {
        "chars": len(text),
        "duration": data.get("duration") or 0,
        "empty_reason": data.get("empty_reason") or "",
    }


def write_transcript(folder: Path, result: dict[str, Any], title: str = "") -> None:
    (folder / TRANSCRIPT_JSON).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    sys.path.insert(0, str(ROOT_DIR))
    try:
        import transcribe as _t

        (folder / TRANSCRIPT_MD).write_text(
            _t.to_markdown(result, title=title), encoding="utf-8"
        )
    except Exception:
        # Markdown 只是给人看的副产品，写不出来不该让整次转写失败
        pass


def open_login_page(platform: str, browser: str = "chrome") -> dict[str, Any]:
    """Open a site's login page in the browser we read cookies from.

    It has to be that exact browser: yt-dlp reads the cookie store of
    `--cookies-from-browser`, so logging in anywhere else would not be seen.
    Falls back to the system default browser when that app is missing.
    """
    import subprocess
    import webbrowser

    url = LOGIN_URLS.get(platform)
    if not url:
        raise FetchError(f"没有为 {platform} 配置登录页。")

    app = BROWSER_APPS.get((browser or "").split(":", 1)[0].lower())
    if app and sys.platform == "darwin":
        done = subprocess.run(
            ["open", "-a", app, url],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if done.returncode == 0:
            return {"browser": app, "url": url, "fallback": False}

    webbrowser.open(url)
    return {"browser": app or "默认浏览器", "url": url, "fallback": True}


def extract_urls(text: str) -> list[str]:
    found = []
    for raw in URL_RE.findall(text or ""):
        url = unescape(raw.rstrip(".,;!！。，、)）]】\"'/"))
        if url not in found:
            found.append(url)
    return found


def detect_platform(url: str) -> str:
    host = urlparse(url).netloc.lower()
    blob = f"{host} {url}".lower()
    if any(h in blob for h in XHS_HOSTS):
        return "xiaohongshu"
    if any(h in host for h in ("douyin.com", "iesdouyin.com", "iesdouyin.net")):
        return "douyin"
    if "tiktok.com" in host or host.endswith("tiktokv.com"):
        return "tiktok"
    if "weixin.qq.com" in host or "channels.weixin.qq.com" in host:
        return "weixin"
    if any(h in host for h in ("kuaishou.com", "chenzhongtech.com", "gifshow.com")):
        return "kuaishou"
    if "instagram.com" in host:
        return "instagram"
    if any(h in host for h in ("youtube.com", "youtu.be")):
        return "youtube"
    if "bilibili.com" in host or "b23.tv" in host:
        return "bilibili"
    return "generic"


def is_profile_url(url: str) -> bool:
    path = urlparse(url).path.rstrip("/")
    platform = detect_platform(url)
    if platform == "xiaohongshu":
        return bool(XHS_PROFILE_RE.search(path))
    if platform == "douyin":
        return bool(DOUYIN_USER_RE.search(url)) and "/video/" not in path
    if platform == "tiktok":
        return bool(re.search(r"tiktok\.com/@[^/]+/?$", path, re.I))
    if platform == "kuaishou":
        return "/profile/" in path and "/short-video/" not in path
    return False


def canonicalize_work_url(url: str, platform: str) -> str:
    if platform == "douyin":
        match = AWEME_ID_RE.search(url or "")
        if match:
            return f"https://www.douyin.com/video/{match.group(1)}"
    if platform == "xiaohongshu":
        match = re.search(r"([0-9a-f]{24})", urlparse(url).path, re.I)
        if match:
            token = (parse_qs(urlparse(url).query).get("xsec_token") or [""])[0]
            out = f"https://www.xiaohongshu.com/explore/{match.group(1)}"
            if token:
                out += f"?xsec_token={quote(token)}&xsec_source=pc_user"
            return out
    if platform == "tiktok":
        match = AWEME_ID_RE.search(url or "")
        if match:
            return f"https://www.tiktok.com/video/{match.group(1)}"
    return url.split("#")[0]


def _collect_profile_links(page: Any, platform: str) -> list[str]:
    if platform == "douyin":
        hrefs = page.evaluate(
            """() => [...document.querySelectorAll(
              '[data-e2e="user-post-item"] a[href*="/video/"],
              [data-e2e="user-post-item"] a[href*="/note/"]
            ')].map(a => a.href)"""
        )
    elif platform == "xiaohongshu":
        hrefs = page.evaluate(
            """() => [...document.querySelectorAll(
              'a[href*="/explore/"], a[href*="/user/profile/"]'
            ')].map(a => a.href)"""
        )
    elif platform == "tiktok":
        hrefs = page.evaluate(
            """() => [...document.querySelectorAll('a[href*="/video/"]')].map(a => a.href)"""
        )
    else:
        hrefs = page.evaluate("""() => [...document.querySelectorAll("a[href]")].map(a => a.href)""")
    found: list[str] = []
    seen: set[str] = set()
    profile_id = ""
    path = urlparse(page.url).path
    pm = XHS_PROFILE_RE.search(path)
    if pm:
        profile_id = pm.group(1).lower()
    for href in hrefs or []:
        if platform == "xiaohongshu":
            note = XHS_NOTE_RE.search(href or "")
            if not note:
                continue
            note_id = note.group(1).lower()
            if note_id == profile_id:
                continue
        canon = canonicalize_work_url(str(href), platform)
        if canon and canon not in seen and not is_profile_url(canon):
            seen.add(canon)
            found.append(canon)
    return found


SESSION_COOKIE_NAMES = {
    "douyin": {"sessionid", "sessionid_ss", "sid_guard", "sid_tt"},
    "xiaohongshu": {"web_session", "web_session_id"},
    "kuaishou": {"passToken", "userId", "kuaishou.server.web_st"},
    "tiktok": {"sessionid", "sessionid_ss", "sid_guard", "sid_tt"},
}


def _context_logged_in(context: Any, platform: str) -> bool:
    names = {str(item.get("name") or "") for item in (context.cookies() or [])}
    wanted = SESSION_COOKIE_NAMES.get(platform) or set()
    return bool(names & wanted)


def _click_login_entry(page: Any) -> None:
    for sel in (
        '[data-e2e="top-login-button"]',
        'button:has-text("登录")',
        'div:has-text("登录"):visible',
        'text=登录',
        'text=Log in',
        'text=QR code',
        'text=扫码登录',
    ):
        try:
            loc = page.locator(sel).first
            if loc.count() and loc.is_visible():
                loc.click(timeout=1500)
                return
        except Exception:
            continue


def expand_profile(url: str, limit: int = PROFILE_LIMIT_DEFAULT, progress: Any = None) -> list[str]:
    """Open the author page; if login is required, show a QR window and wait."""
    platform = detect_platform(url)
    label = PLATFORM_LABELS.get(platform, platform)
    limit = max(1, min(int(limit or PROFILE_LIMIT_DEFAULT), PROFILE_LIMIT_MAX))

    def emit(detail: str, state: str = "active") -> None:
        if progress:
            progress(
                {
                    "type": "step",
                    "id": "profile",
                    "label": f"列出{label}主页",
                    "detail": detail,
                    "state": state,
                }
            )

    emit("正在打开浏览器")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        raise FetchError("缺少浏览器组件，无法列出主页作品。请先安装 playwright。") from exc

    intercepted: list[str] = []
    BROWSER_PROFILE_PATH.mkdir(parents=True, exist_ok=True)
    _clear_chromium_profile_locks(BROWSER_PROFILE_PATH)
    with BROWSER_LOCK:
        with sync_playwright() as playwright:
            common = dict(
                headless=False,
                viewport={"width": 1280, "height": 900},
                locale="zh-CN",
                args=["--disable-blink-features=AutomationControlled"],
                ignore_default_args=["--enable-automation"],
            )
            app_name = "Google Chrome"
            try:
                context = playwright.chromium.launch_persistent_context(
                    str(BROWSER_PROFILE_PATH), channel="chrome", **common
                )
            except Exception:
                app_name = "Chromium"
                context = playwright.chromium.launch_persistent_context(
                    str(BROWSER_PROFILE_PATH), **common
                )
            try:
                page = context.pages[0] if context.pages else context.new_page()
                page.add_init_script(
                    "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
                )

                def on_response(resp: Any) -> None:
                    u = resp.url or ""
                    try:
                        if platform == "douyin" and "aweme/v1/web/aweme/post" in u:
                            data = resp.json()
                            for item in data.get("aweme_list") or []:
                                aid = str(item.get("aweme_id") or "")
                                if aid:
                                    intercepted.append(f"https://www.douyin.com/video/{aid}")
                        if platform == "xiaohongshu" and "user_posted" in u:
                            data = resp.json()
                            blob = data.get("data") if isinstance(data.get("data"), dict) else data
                            for note in (blob or {}).get("notes") or []:
                                nid = str(note.get("note_id") or note.get("id") or "")
                                token = str(note.get("xsec_token") or "")
                                if re.fullmatch(r"[0-9a-f]{24}", nid, re.I):
                                    link = f"https://www.xiaohongshu.com/explore/{nid}"
                                    if token:
                                        link += f"?xsec_token={quote(token)}&xsec_source=pc_user"
                                    intercepted.append(link)
                    except Exception:
                        return

                page.on("response", on_response)

                if not _context_logged_in(context, platform):
                    login_url = LOGIN_URLS.get(platform) or url
                    emit(f"请用{label} App 扫码登录")
                    page.goto(login_url, wait_until="domcontentloaded", timeout=45000)
                    _focus_login_page(page, app_name)
                    page.wait_for_timeout(800)
                    _click_login_entry(page)
                    _focus_login_page(page, app_name)
                    login_deadline = time.time() + 300
                    ticks = 0
                    while time.time() < login_deadline and not _context_logged_in(context, platform):
                        if page.is_closed():
                            break
                        ticks += 1
                        if ticks % 8 == 0:
                            left = max(0, int(login_deadline - time.time()))
                            emit(f"等待扫码登录（还剩 {left} 秒）")
                            try:
                                _click_login_entry(page)
                                _focus_login_page(page, app_name)
                            except Exception:
                                pass
                        page.wait_for_timeout(1000)
                    if not _context_logged_in(context, platform):
                        raise FetchError(
                            f"登录超时。请在弹出的窗口用{label} App 扫码后再试。",
                            needs_login=platform,
                        )
                    emit("登录成功，正在打开主页")

                page.goto(url, wait_until="domcontentloaded", timeout=45000)
                emit(f"已打开{label}主页，正在读取作品")
                deadline = time.time() + 90
                found: list[str] = []
                scrolls = 0
                while time.time() < deadline and len(found) < limit:
                    page.wait_for_timeout(1200)
                    from_dom = _collect_profile_links(page, platform)
                    merged: list[str] = []
                    seen: set[str] = set()
                    for item in intercepted + from_dom:
                        if item not in seen:
                            seen.add(item)
                            merged.append(item)
                    found = merged
                    emit(f"已找到 {min(len(found), limit)} 条公开作品")
                    if len(found) >= limit:
                        break
                    if scrolls >= 12:
                        break
                    page.mouse.wheel(0, 2200)
                    scrolls += 1
                found = found[:limit]
            finally:
                context.close()

    if not found:
        raise FetchError(
            f"登录后仍没能从{label}主页列出作品。请确认这是公开主页，并用 App 里刚复制的分享口令再试。",
            needs_login=platform if platform in LOGIN_URLS else "",
        )
    emit(f"准备保存 {len(found)} 条", "done")
    print(f"  主页展开 {len(found)} 条 {label}")
    return found


PLATFORM_LABELS = {
    "xiaohongshu": "小红书",
    "douyin": "抖音",
    "tiktok": "TikTok",
    "weixin": "视频号",
    "kuaishou": "快手",
    "instagram": "Instagram",
    "youtube": "YouTube",
    "bilibili": "哔哩哔哩",
}
KIND_LABELS = {"video": "视频", "image": "图片", "live": "实况"}


def format_size(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.0f} KB"
    return f"{n / (1024 * 1024):.1f} MB"


def safe_name(text: str, fallback: str = "untitled", limit: int = 80) -> str:
    cleaned = ILLEGAL_FS.sub(" ", (text or "").strip())
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .")
    return (cleaned[:limit] or fallback).rstrip()


def guess_ext(url: str, content_type: str = "", default: str = "bin") -> str:
    path = urlparse(url).path.lower()
    for ext in (".mp4", ".mov", ".m4v", ".jpg", ".jpeg", ".png", ".webp", ".heic", ".gif"):
        if path.endswith(ext):
            return "jpg" if ext == ".jpeg" else ext.lstrip(".")
    ctype = (content_type or "").split(";")[0].strip().lower()
    mapping = {
        "video/mp4": "mp4",
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/webp": "webp",
        "image/heic": "heic",
        "image/gif": "gif",
    }
    return mapping.get(ctype, default)


class Http:
    def __init__(self, timeout: int = 25, cookie: str = "", impersonate: str = "chrome"):
        self.timeout = timeout
        self.cookie = cookie
        self.impersonate = impersonate

    def headers(self, mobile: bool = False, referer: str = "", media: bool = False) -> dict[str, str]:
        headers = {
            "User-Agent": UA_MOBILE if mobile else UA_PC,
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        }
        if media:
            headers["Accept"] = "*/*"
            headers["Accept-Encoding"] = "identity"
        else:
            headers["Accept"] = (
                "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
            )
        if referer:
            headers["Referer"] = referer
        if self.cookie:
            headers["Cookie"] = self.cookie
        return headers

    def get(
        self,
        url: str,
        *,
        mobile: bool = False,
        referer: str = "",
        stream: bool = False,
        extra_headers: Optional[dict[str, str]] = None,
        impersonate: Optional[str] = None,
        timeout: Optional[int] = None,
        media: bool = False,
    ):
        headers = self.headers(mobile=mobile, referer=referer, media=media)
        if extra_headers:
            headers.update(extra_headers)
        try:
            kwargs: dict[str, Any] = {
                "headers": headers,
                "timeout": timeout or self.timeout,
                "allow_redirects": True,
                "stream": stream,
            }
            target = impersonate if impersonate is not None else self.impersonate
            if target:
                kwargs["impersonate"] = target
            return cffi_requests.get(url, **kwargs)
        except Exception as exc:
            raise FetchError(f"请求失败: {url} ({exc})") from exc


def load_js_object(text: str, marker: str) -> Optional[dict[str, Any]]:
    idx = text.find(marker)
    if idx < 0:
        return None
    start = text.find("{", idx)
    if start < 0:
        return None
    chunk = text[start:]
    chunk = re.sub(r":\s*undefined(\s*[,}])", r": null\1", chunk)
    chunk = chunk.replace("undefined", "null")
    decoder = json.JSONDecoder()
    try:
        data, _ = decoder.raw_decode(chunk)
        return data if isinstance(data, dict) else None
    except json.JSONDecodeError:
        return None


def ensure_https(url: str) -> str:
    url = unescape(str(url or "")).replace("\\/", "/").strip()
    if url.startswith("//"):
        return "https:" + url
    if url.startswith("http://"):
        return "https://" + url[7:]
    return url


class XiaohongshuExtractor:
    def __init__(self, http: Http, image_format: str = "jpeg"):
        self.http = http
        self.image_format = image_format.lower()

    def parse(self, url: str) -> ParseResult:
        resp = self.http.get(url, referer="https://www.xiaohongshu.com/")
        final_url = str(resp.url)
        html = resp.text or ""
        if not html:
            raise FetchError("小红书页面为空，可能被风控，试试带上 --cookie")

        note_id = self._note_id(final_url) or self._note_id(url)
        qs = parse_qs(urlparse(final_url).query)
        if not note_id:
            note_id = (qs.get("noteId") or qs.get("note_id") or [None])[0]
        if not note_id:
            # xhslink sometimes lands on /404?noteId=...
            note_id = (parse_qs(urlparse(unquote(final_url)).query).get("noteId") or [None])[0]

        state = load_js_object(html, "window.__INITIAL_STATE__")
        note_map = ((state or {}).get("note") or {}).get("noteDetailMap") or {}
        if not note_id and note_map:
            note_id = next(iter(note_map.keys()))
        note = ((note_map.get(note_id) or {}).get("note") if note_id else None) or {}
        if not note and note_map:
            first = next(iter(note_map.values()))
            note = (first or {}).get("note") or {}
            note_id = note.get("noteId") or note_id or next(iter(note_map.keys()))

        if not note:
            raise FetchError("未能解析小红书笔记。请复制 App 里最新的分享链接，必要时加上 --cookie")

        title = note.get("title") or ""
        desc = note.get("desc") or ""
        author = ((note.get("user") or {}).get("nickname")) or ""
        items: list[MediaItem] = []

        video_urls = expand_xhs_video_urls(self._video_urls(note))
        if video_urls:
            items.append(
                MediaItem(
                    url=video_urls[0],
                    kind="video",
                    ext="mp4",
                    index=1,
                    backups=video_urls[1:],
                )
            )
        for idx, image in enumerate(note.get("imageList") or [], start=1):
            img_url = self._image_url(image)
            if img_url:
                items.append(MediaItem(url=img_url, kind="image", ext="jpg", index=idx))
            live_url = self._live_url(image)
            if live_url:
                items.append(MediaItem(url=live_url, kind="live", ext="mp4", index=idx))

        if not items:
            raise FetchError("笔记里没有找到可下载的图片或视频")

        return ParseResult(
            platform="xiaohongshu",
            content_id=str(note_id or "unknown"),
            title=title or desc or f"xhs_{note_id}",
            author=author,
            description=desc,
            items=items,
            extra={"final_url": final_url, "note_type": note.get("type")},
        )

    @staticmethod
    def _note_id(url: str) -> Optional[str]:
        match = XHS_NOTE_RE.search(url or "")
        return match.group(1) if match else None

    def _video_urls(self, note: dict[str, Any]) -> list[str]:
        urls: list[str] = []
        origin = ((note.get("video") or {}).get("consumer") or {}).get("originVideoKey")
        if origin:
            urls.append(f"https://sns-video-bd.xhscdn.com/{origin}")
        stream = ((note.get("video") or {}).get("media") or {}).get("stream") or {}
        for items in stream.values():
            if not isinstance(items, list):
                continue
            for item in items:
                if not isinstance(item, dict):
                    continue
                for backup in item.get("backupUrls") or []:
                    urls.append(ensure_https(backup))
                if item.get("masterUrl"):
                    urls.append(ensure_https(item["masterUrl"]))
        seen = set()
        unique = []
        for url in urls:
            if url and url not in seen:
                seen.add(url)
                unique.append(url)
        return unique

    def _image_url(self, image: dict[str, Any]) -> Optional[str]:
        file_id = image.get("fileId") or image.get("traceId")
        if not file_id:
            for key in ("urlDefault", "urlPre"):
                match = XHS_FILE_ID_RE.search(str(image.get(key) or ""))
                if match:
                    file_id = match.group(1)
                    break
            if not file_id:
                for info in image.get("infoList") or []:
                    match = XHS_FILE_ID_RE.search(str((info or {}).get("url") or ""))
                    if match:
                        file_id = match.group(1)
                        break
        if file_id:
            fmt = "png" if self.image_format == "png" else "jpeg"
            return f"https://ci.xiaohongshu.com/{file_id}?imageView2/format/{fmt}"
        for info in image.get("infoList") or []:
            if (info or {}).get("imageScene") == "WB_DFT" and info.get("url"):
                return ensure_https(info["url"])
        return ensure_https(image.get("urlDefault") or image.get("urlPre") or "") or None

    @staticmethod
    def _live_url(image: dict[str, Any]) -> Optional[str]:
        stream = (image.get("stream") or {}).get("h264") or []
        if isinstance(stream, list) and stream:
            master = (stream[0] or {}).get("masterUrl")
            if master:
                return ensure_https(master)
        return None


def expand_xhs_video_urls(urls: list[str]) -> list[str]:
    found: list[str] = []
    seen = set()

    def add(url: str) -> None:
        url = ensure_https(url)
        if url and url not in seen:
            seen.add(url)
            found.append(url)

    for url in urls:
        parsed = urlparse(ensure_https(url))
        if not parsed.netloc:
            continue
        add(url)
        path = parsed.path
        add(f"https://{parsed.netloc}{path}")
        for host in XHS_VIDEO_HOSTS:
            add(f"https://{host}{path}")
    return found


class DouyinExtractor:
    FEED_APIS = (
        "https://aweme.snssdk.com/aweme/v1/feed/?aweme_id={id}",
        "https://api.amemv.com/aweme/v1/feed/?aweme_id={id}",
    )

    def __init__(self, http: Http, quality: str = "auto"):
        self.http = http
        self.quality = normalize_quality(quality)

    def parse(self, url: str) -> ParseResult:
        resp = self.http.get(url, mobile=True)
        final_url = str(resp.url)
        item_id = self._aweme_id(final_url) or self._aweme_id(url)
        if not item_id:
            item_id = urlparse(final_url).path.rstrip("/").split("/")[-1]
        item = self._fetch_aweme(item_id)
        if not item:
            raise FetchError("抖音接口没有返回作品信息，换一条刚复制的分享链接再试")

        desc = (item.get("desc") or "").strip() or f"douyin_{item_id}"
        author = ((item.get("author") or {}).get("nickname")) or ""
        media = self._media_from_aweme(item)
        if not media:
            raise FetchError("抖音作品里没有可下载的视频或图片")
        return ParseResult(
            platform="douyin",
            content_id=str(item_id),
            title=desc,
            author=author,
            description=desc,
            items=media,
            extra={"final_url": final_url},
        )

    def _fetch_aweme(self, item_id: str) -> Optional[dict[str, Any]]:
        headers = {"User-Agent": "okhttp/3.12.1 com.ss.android.ugc.aweme/250901"}
        for tmpl in self.FEED_APIS:
            try:
                resp = self.http.get(
                    tmpl.format(id=item_id),
                    extra_headers=headers,
                    impersonate="chrome",
                    timeout=20,
                    media=True,
                )
                payload = resp.json()
            except Exception:
                continue
            for aweme in payload.get("aweme_list") or []:
                if str(aweme.get("aweme_id") or "") == str(item_id):
                    return aweme
            if payload.get("aweme_list"):
                return payload["aweme_list"][0]
        return None

    @staticmethod
    def _aweme_id(url: str) -> Optional[str]:
        match = AWEME_ID_RE.search(url or "")
        return match.group(1) if match else None

    @staticmethod
    def _clean_play(url: str) -> str:
        url = ensure_https(url).replace("playwm", "play")
        return url.replace("watermark=1", "watermark=0")

    def _media_from_aweme(self, item: dict[str, Any]) -> list[MediaItem]:
        items: list[MediaItem] = []
        images = item.get("images") or []
        if images:
            for idx, image in enumerate(images, start=1):
                url_list = image.get("url_list") or []
                if url_list:
                    items.append(MediaItem(url=ensure_https(url_list[0]), kind="image", ext="jpg", index=idx))
            return items

        video = item.get("video") or {}
        urls: list[str] = []
        cap = quality_height(self.quality)

        def rate_height(rate: dict[str, Any]) -> int:
            addr = rate.get("play_addr") or {}
            return int(addr.get("height") or rate.get("height") or 0)

        bitrates = list(video.get("bit_rate") or [])
        bitrates.sort(key=lambda b: (rate_height(b), b.get("bit_rate") or 0), reverse=True)
        if cap:
            under = [b for b in bitrates if rate_height(b) and rate_height(b) <= cap]
            if under:
                bitrates = under + [b for b in bitrates if b not in under]
        for rate in bitrates:
            for raw in ((rate.get("play_addr") or {}).get("url_list") or []):
                urls.append(self._clean_play(raw))
        for raw in ((video.get("play_addr") or {}).get("url_list") or []):
            urls.append(self._clean_play(raw))
        uri = (video.get("play_addr") or {}).get("uri")
        if uri:
            urls.append(f"https://aweme.snssdk.com/aweme/v1/play/?video_id={uri}&ratio=1080p&line=0")
        seen = set()
        unique = []
        for raw in urls:
            if raw and raw not in seen:
                seen.add(raw)
                unique.append(raw)
        if unique:
            items.append(MediaItem(url=unique[0], kind="video", ext="mp4", index=1, backups=unique[1:8]))
        return items


class TikTokExtractor:
    def __init__(self, http: Http):
        self.http = http

    def parse(self, url: str) -> ParseResult:
        item_id = self._video_id(url)
        if not item_id:
            resp = self.http.get(url, impersonate="chrome131", timeout=20)
            item_id = self._video_id(str(resp.url)) or self._video_id(resp.text or "")
        if not item_id:
            raise FetchError("没有从链接里识别到 TikTok 视频 ID")

        embed = f"https://www.tiktok.com/embed/v2/{item_id}"
        page = self.http.get(embed, impersonate="chrome131", timeout=25, referer="https://www.tiktok.com/")
        html = page.text or ""
        state = self._frontity_state(html)
        video_data = self._video_data(state, item_id)
        if not video_data:
            raise FetchError("TikTok 嵌入页没有视频数据")

        info = video_data.get("itemInfos") or {}
        author_info = video_data.get("authorInfos") or {}
        title = (info.get("text") or "").strip() or f"tiktok_{item_id}"
        author = author_info.get("nickName") or author_info.get("uniqueId") or ""
        video = info.get("video") or {}
        urls = [ensure_https(u) for u in (video.get("urls") or []) if u]
        images: list[MediaItem] = []
        for idx, cover in enumerate(info.get("covers") or video.get("covers") or [], start=1):
            if cover:
                images.append(MediaItem(url=ensure_https(cover), kind="image", ext="jpg", index=idx))
        items: list[MediaItem] = []
        if urls:
            items.append(MediaItem(url=urls[0], kind="video", ext="mp4", index=1, backups=urls[1:]))
        items.extend(images)
        if not items:
            raise FetchError("TikTok 没有可下载的视频或图片")
        return ParseResult(
            platform="tiktok",
            content_id=str(item_id),
            title=title,
            author=author,
            description=title,
            items=items,
            extra={"final_url": embed},
        )

    @staticmethod
    def _video_id(text: str) -> Optional[str]:
        match = AWEME_ID_RE.search(text or "")
        return match.group(1) if match else None

    @staticmethod
    def _frontity_state(html: str) -> Optional[dict[str, Any]]:
        match = re.search(
            r'<script[^>]*id="__FRONTITY_CONNECT_STATE__"[^>]*>(.*?)</script>',
            html or "",
            re.S,
        )
        if not match:
            return load_js_object(html, "__FRONTITY_CONNECT_STATE__")
        try:
            return json.loads(match.group(1))
        except json.JSONDecodeError:
            return None

    @staticmethod
    def _video_data(state: Optional[dict[str, Any]], item_id: str) -> Optional[dict[str, Any]]:
        if not state:
            return None
        source = ((state.get("source") or {}).get("data") or {})
        for value in source.values():
            if isinstance(value, dict) and isinstance(value.get("videoData"), dict):
                data = value["videoData"]
                info = data.get("itemInfos") or {}
                if not item_id or str(info.get("id") or "") == str(item_id):
                    return data
        return None


class KuaishouExtractor:
    PHOTO_ID_RE = re.compile(
        r"(?:short-video|fw/photo|photo)/([A-Za-z0-9_-]+)|photoId=([A-Za-z0-9_-]+)",
        re.I,
    )

    def __init__(self, http: Http, quality: str = "auto"):
        self.http = http
        self.quality = normalize_quality(quality)

    def parse(self, url: str) -> ParseResult:
        resp = self.http.get(url, referer="https://www.kuaishou.com/")
        final_url = str(resp.url)
        html = resp.text or ""
        if not html:
            raise FetchError("快手页面为空。请用 App 里刚复制的分享口令。")
        state = load_js_object(html, "window.__APOLLO_STATE__") or {}
        client = state.get("defaultClient") if isinstance(state.get("defaultClient"), dict) else state
        photo, author = self._photo_and_author(client)
        if not photo:
            raise FetchError("未能解析快手作品。请用 App 里刚复制的分享口令。")
        photo_id = str(photo.get("id") or self._photo_id(final_url) or self._photo_id(url) or "")
        caption = (photo.get("caption") or "").strip() or f"kuaishou_{photo_id}"
        author_name = str((author or {}).get("name") or "")
        picked = self._pick(self._representations(photo, client))
        items: list[MediaItem] = []
        if picked:
            urls = [picked["url"], *(picked.get("backups") or [])]
            seen: set[str] = set()
            unique: list[str] = []
            for item_url in urls:
                item_url = ensure_https(item_url)
                if item_url and item_url not in seen:
                    seen.add(item_url)
                    unique.append(item_url)
            items.append(MediaItem(url=unique[0], kind="video", ext="mp4", index=1, backups=unique[1:6]))
        cover = photo.get("coverUrl")
        if cover:
            items.append(MediaItem(url=ensure_https(str(cover)), kind="image", ext="jpg", index=1))
        if not any(it.kind == "video" for it in items):
            raise FetchError("快手作品里没有可下载的视频。")
        return ParseResult(
            platform="kuaishou",
            content_id=photo_id or "unknown",
            title=caption,
            author=author_name,
            description=caption,
            items=items,
            extra={"final_url": final_url, "height": int((picked or {}).get("label_h") or 0)},
        )

    @classmethod
    def _photo_id(cls, url: str) -> Optional[str]:
        match = cls.PHOTO_ID_RE.search(url or "")
        if not match:
            return None
        return match.group(1) or match.group(2)

    @staticmethod
    def _unwrap(value: Any) -> Any:
        if isinstance(value, dict) and value.get("type") == "json" and "json" in value:
            return value.get("json")
        return value

    @classmethod
    def _photo_and_author(cls, client: dict[str, Any]) -> tuple[Optional[dict[str, Any]], Optional[dict[str, Any]]]:
        photo = None
        author = None
        for key, value in (client or {}).items():
            if not isinstance(value, dict):
                continue
            if str(key).startswith("VisionVideoDetailPhoto:") and value.get("photoUrl"):
                photo = value
            if str(key).startswith("VisionVideoDetailAuthor:") and value.get("name"):
                author = value
        return photo, author

    @classmethod
    def _representations(cls, photo: dict[str, Any], client: dict[str, Any]) -> list[dict[str, Any]]:
        reps: list[dict[str, Any]] = []

        def add(rep: Any) -> None:
            if not isinstance(rep, dict):
                return
            if rep.get("type") == "id" and rep.get("id"):
                resolved = client.get(str(rep["id"]))
                if isinstance(resolved, dict):
                    rep = resolved
            url = ensure_https(str(rep.get("url") or ""))
            backups: list[str] = []
            raw_backup = cls._unwrap(rep.get("backupUrl"))
            if isinstance(raw_backup, str) and raw_backup:
                backups.append(ensure_https(raw_backup))
            elif isinstance(raw_backup, list):
                backups.extend(ensure_https(str(item)) for item in raw_backup if item)
            width, height = int(rep.get("width") or 0), int(rep.get("height") or 0)
            label = min(width, height) if width and height else 0
            if not label:
                match = re.search(r"(\d+)", str(rep.get("qualityType") or ""))
                label = int(match.group(1)) if match else 0
            if url:
                reps.append(
                    {
                        "url": url,
                        "backups": backups,
                        "label_h": label,
                        "bitrate": int(rep.get("avgBitrate") or 0),
                    }
                )

        def add_manifest(manifest: Any) -> None:
            data = cls._unwrap(manifest)
            if not isinstance(data, dict):
                return
            for aset in data.get("adaptationSet") or []:
                if not isinstance(aset, dict):
                    continue
                for rep in aset.get("representation") or []:
                    add(rep)

        video_resource = cls._unwrap(photo.get("videoResource"))
        if isinstance(video_resource, dict):
            for codec in video_resource.values():
                add_manifest(codec)
        add_manifest(photo.get("manifestH265"))
        add_manifest(photo.get("manifest"))
        for key in ("photoUrl", "photoH265Url"):
            if photo.get(key):
                add({"url": photo[key], "width": 0, "height": 0, "avgBitrate": 0})
        for key, value in (client or {}).items():
            if str(key).startswith("VisionVideoSetRepresentation:") and isinstance(value, dict):
                add(value)
        return reps

    def _pick(self, reps: list[dict[str, Any]]) -> Optional[dict[str, Any]]:
        if not reps:
            return None
        reps = sorted(reps, key=lambda item: (item.get("label_h") or 0, item.get("bitrate") or 0), reverse=True)
        cap = quality_height(self.quality)
        if cap:
            under = [item for item in reps if item.get("label_h") and item["label_h"] <= cap]
            if under:
                return under[0]
        return reps[0]


SPH_ID_RE = re.compile(r"(?:weixin\.qq\.com/sph/|pages/sph\?id=)([A-Za-z0-9]+)", re.I)
WEIXIN_COOKIE_PATH = Path(__file__).resolve().parent / "weixin.cookie"
WEIXIN_PROFILE_PATH = Path(__file__).resolve().parent / ".weixin-profile"
WEIXIN_LOGIN_LOCK = threading.Lock()


def weixin_cookie_ready(cookie: str) -> bool:
    blob = cookie or ""
    return "hy_user=" in blob and "hy_token=" in blob


def read_weixin_cookie() -> str:
    for path in (WEIXIN_COOKIE_PATH, Path.home() / ".social-dl" / "weixin.cookie"):
        if path.exists():
            try:
                return path.read_text(encoding="utf-8").strip()
            except OSError:
                continue
    return ""


def write_weixin_cookie(header: str) -> None:
    WEIXIN_COOKIE_PATH.write_text(header.strip() + "\n", encoding="utf-8")
    try:
        WEIXIN_COOKIE_PATH.chmod(0o600)
    except OSError:
        pass


def _hy_session(cookies: list[dict[str, Any]]) -> tuple[str, str]:
    user = ""
    token = ""
    for item in cookies or []:
        name = str(item.get("name") or "")
        value = str(item.get("value") or "")
        if name == "hy_user" and value:
            user = value
        elif name == "hy_token" and value:
            token = value
    return user, token


def weixin_cookie_header(cookies: list[dict[str, Any]]) -> str:
    parts = []
    seen = set()
    for item in cookies:
        domain = str(item.get("domain") or "")
        name = str(item.get("name") or "")
        if not name:
            continue
        if "yuanbao.tencent.com" in domain or name.startswith("hy_"):
            key = f"{name}="
            if key in seen:
                continue
            seen.add(key)
            parts.append(f"{name}={item.get('value') or ''}")
    return "; ".join(parts)


def _clear_chromium_profile_locks(profile: Path) -> None:
    for name in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
        path = profile / name
        try:
            if path.exists() or path.is_symlink():
                path.unlink()
        except OSError:
            pass


def _bring_login_window_front(app_name: str = "", notify: str = "") -> None:
    """把登录用的那个浏览器拉到最前。

    不能按名字里带不带 Chrome 去抢：用户自己的 Google Chrome 会被拉到前面，
    真正的扫码窗口（多半是 Chromium）反而被盖住。
    """
    names = [app_name] if app_name else ["Chromium", "Google Chrome for Testing", "Google Chrome"]
    try:
        import subprocess

        safe_names = []
        for name in names:
            cleaned = (name or "").replace("\\", "").replace('"', "").strip()
            if cleaned and cleaned not in safe_names:
                safe_names.append(cleaned)
        if not safe_names:
            return
        lines = ['set targetApp to ""', 'tell application "System Events"']
        for name in safe_names:
            lines.append(f'if targetApp is "" and exists process "{name}" then')
            lines.append(f'set targetApp to "{name}"')
            lines.append("end if")
        lines.extend(
            [
                "end tell",
                'if targetApp is not "" then',
                "tell application targetApp to activate",
                "end if",
            ]
        )
        subprocess.run(
            ["osascript", "-e", "\n".join(lines)],
            timeout=4,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if notify:
            note = notify.replace("\\", "").replace('"', "")[:80]
            subprocess.run(
                [
                    "osascript",
                    "-e",
                    f'display notification "{note}" with title "登录视频号"',
                ],
                timeout=4,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    except Exception:
        pass


def _launch_login_context(playwright: Any, profile: Path) -> tuple[Any, str]:
    """单独开一个看得见的窗口。优先 Chromium，避免和用户正在用的 Chrome 挤在一起。"""
    common = dict(
        headless=False,
        viewport={"width": 1100, "height": 800},
        locale="zh-CN",
        timezone_id="Asia/Shanghai",
        user_agent=UA_PC,
        args=[
            "--disable-blink-features=AutomationControlled",
            "--window-position=60,40",
            "--window-size=1100,820",
        ],
        ignore_default_args=["--enable-automation"],
    )
    errors: list[str] = []
    for app_name, extra in (("Chromium", {}), ("Google Chrome", {"channel": "chrome"})):
        try:
            context = playwright.chromium.launch_persistent_context(str(profile), **common, **extra)
            return context, app_name
        except Exception as exc:
            errors.append(str(exc).splitlines()[0][:160])
    msg = errors[-1] if errors else "未知错误"
    if "Executable doesn't exist" in msg or "playwright install" in msg:
        raise FetchError(
            "还没装好登录用的浏览器。请在终端执行：.venv/bin/playwright install chromium",
            needs_login="weixin",
        )
    raise FetchError(f"无法打开登录窗口：{msg}", needs_login="weixin")


def _qr_visible(page: Any) -> bool:
    for sel in ("canvas", "img[src*='qrcode']", "img[src*='qr']", "[class*='qrcode' i]"):
        try:
            loc = page.locator(sel).first
            if not loc.count() or not loc.is_visible():
                continue
            box = loc.bounding_box()
            if box and box.get("width", 0) >= 80 and box.get("height", 0) >= 80:
                return True
        except Exception:
            continue
    return False


def _open_weixin_qr(page: Any) -> None:
    """元宝首页通常要先点登录，二维码才会出来。已经有二维码就不要再点，以免把弹层关掉。"""
    if _qr_visible(page):
        return

    def visible_click(selectors: tuple[str, ...]) -> bool:
        for sel in selectors:
            try:
                loc = page.locator(sel).first
                if loc.count() and loc.is_visible():
                    loc.click(timeout=1200)
                    return True
            except Exception:
                continue
        return False

    wechat = (
        'button:has-text("微信登录")',
        'button:has-text("微信扫码")',
        'text=/微信扫码/',
        'text=/微信登录/',
    )
    if visible_click(wechat):
        return
    visible_click(
        (
            'button:has-text("登录")',
            'a:has-text("登录")',
            'text=/^登录$/',
        )
    )
    try:
        page.wait_for_timeout(700)
    except Exception:
        return
    visible_click(wechat)


def _focus_login_page(page: Any, app_name: str, notify: str = "") -> None:
    try:
        page.bring_to_front()
    except Exception:
        pass
    _bring_login_window_front(app_name, notify=notify)


def ensure_weixin_cookie(progress: Any = None, timeout: int = 300, force: bool = False) -> str:
    """Open a visible login window on first use (or when the saved session expired)."""
    with WEIXIN_LOGIN_LOCK:
        existing = read_weixin_cookie()
        if weixin_cookie_ready(existing) and not force:
            return existing

        def emit(detail: str, state: str = "active") -> None:
            if not progress:
                return
            try:
                progress(
                    {
                        "type": "step",
                        "id": "login",
                        "label": "登录视频号",
                        "detail": detail,
                        "state": state,
                    }
                )
            except (BrokenPipeError, ConnectionResetError, OSError):
                # 页面提示断了也不能把扫码窗口关掉
                return

        emit("正在打开扫码窗口")
        try:
            from playwright.sync_api import sync_playwright
        except ImportError as exc:
            raise FetchError("缺少登录组件。请先安装 playwright。", needs_login="weixin") from exc

        WEIXIN_PROFILE_PATH.mkdir(parents=True, exist_ok=True)
        _clear_chromium_profile_locks(WEIXIN_PROFILE_PATH)
        header = ""
        closed_early = False
        try:
            with sync_playwright() as playwright:
                context, app_name = _launch_login_context(playwright, WEIXIN_PROFILE_PATH)
                try:
                    page = context.pages[0] if context.pages else context.new_page()
                    page.add_init_script(
                        "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
                    )
                    _, old_token = _hy_session(context.cookies())
                    if force:
                        # 上次的登录还在这个窗口里。不清掉的话，一打开就会被当成“已经扫完”而马上关掉。
                        try:
                            context.clear_cookies()
                        except Exception:
                            pass
                    else:
                        old_token = ""
                    page.goto(
                        "https://yuanbao.tencent.com/",
                        wait_until="domcontentloaded",
                        timeout=45000,
                    )
                    if force:
                        try:
                            page.evaluate("() => { localStorage.clear(); sessionStorage.clear(); }")
                            context.clear_cookies()
                        except Exception:
                            pass
                        page.goto(
                            "https://yuanbao.tencent.com/",
                            wait_until="domcontentloaded",
                            timeout=45000,
                        )
                    _focus_login_page(
                        page,
                        app_name,
                        notify="请用微信扫这个窗口里的二维码。扫完之前窗口会一直开着",
                    )
                    page.wait_for_timeout(800)
                    _open_weixin_qr(page)
                    _focus_login_page(page, app_name)
                    emit(f"扫码窗口已打开（{app_name}）。请用微信扫完，扫完之前不要关，它也不会自己关")
                    deadline = time.time() + timeout
                    ticks = 0
                    while time.time() < deadline:
                        if page.is_closed():
                            closed_early = True
                            break
                        user, token = _hy_session(context.cookies())
                        # 重新登录时，旧 token 不算数，必须是扫码之后新出现的
                        fresh = bool(user and token) and token != old_token
                        if fresh:
                            page.wait_for_timeout(800)
                            user, token = _hy_session(context.cookies())
                            if user and token and token != old_token:
                                header = weixin_cookie_header(context.cookies())
                                break
                        ticks += 1
                        if ticks in (8, 20) and not _qr_visible(page):
                            _open_weixin_qr(page)
                        if ticks % 10 == 0:
                            left = max(0, int(deadline - time.time()))
                            emit(f"还在等微信扫码（还剩 {left} 秒）。窗口请保持打开")
                            _focus_login_page(page, app_name)
                        page.wait_for_timeout(1000)
                finally:
                    context.close()
        except FetchError:
            raise
        except Exception as exc:
            msg = str(exc)
            if "Executable doesn't exist" in msg or "playwright install" in msg:
                raise FetchError(
                    "还没装好登录用的浏览器。请在终端执行：.venv/bin/playwright install chromium",
                    needs_login="weixin",
                ) from exc
            raise FetchError(f"无法打开登录窗口：{msg.splitlines()[0][:120]}", needs_login="weixin") from exc

        if not weixin_cookie_ready(header):
            if closed_early:
                raise FetchError(
                    "扫码还没完成，窗口就被关掉了。请再打开一次，用微信扫完再等它自己关。",
                    needs_login="weixin",
                )
            raise FetchError(
                "登录超时。扫码窗口会一直开到你扫完，请看 Dock 里的浏览器后再试。",
                needs_login="weixin",
            )
        write_weixin_cookie(header)
        emit("登录成功，已记住本机登录状态", "done")
        return header


class WeixinExtractor:
    FEED_API = "https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info"
    YUANBAO_API = "https://yuanbao.tencent.com/api/weixin/get_parse_result"

    def __init__(self, http: Http, progress: Any = None):
        self.http = http
        self.progress = progress

    def parse(self, url: str) -> ParseResult:
        sph_id = self._sph_id(url)
        if not sph_id:
            raise FetchError("没有从链接里识别到视频号 ID")
        cookie = read_weixin_cookie()
        feed = None
        had_session = weixin_cookie_ready(cookie)
        if had_session:
            try:
                feed = self._feed_via_yuanbao(url, cookie)
            except Exception:
                feed = None
        if not self._media_urls(feed):
            cookie = ensure_weixin_cookie(self.progress, force=had_session)
            feed = self._feed_via_yuanbao(url, cookie)
        if not feed:
            feed = self._feed_via_short_uri(sph_id)
        info = (feed.get("feedInfo") or {}) if feed else {}
        author = ((feed.get("authorInfo") or {}).get("nickname") if feed else "") or ""
        title = (info.get("description") or "").strip() or f"weixin_{sph_id}"
        video_urls = self._media_urls(feed)
        items: list[MediaItem] = []
        if video_urls:
            items.append(MediaItem(url=video_urls[0], kind="video", ext="mp4", index=1, backups=video_urls[1:]))
        cover = info.get("coverUrl")
        if cover:
            items.append(MediaItem(url=ensure_https(cover), kind="image", ext="jpg", index=1))
        if not video_urls:
            raise FetchError(
                f"已识别视频号「{author or '未知作者'}」：{title[:40]}。"
                "登录后仍未拿到视频地址，请再打开扫码窗口重新登录。",
                needs_login="weixin",
            )
        return ParseResult(
            platform="weixin",
            content_id=sph_id,
            title=title,
            author=author,
            description=title,
            items=items,
            extra={"final_url": url},
        )

    def _feed_via_short_uri(self, sph_id: str) -> dict[str, Any]:
        from curl_cffi import requests as cffi

        r = cffi.post(
            self.FEED_API,
            json={"baseReq": {"generalToken": ""}, "shortUri": sph_id},
            headers={
                "content-type": "application/json",
                "origin": "https://channels.weixin.qq.com",
                "accept": "application/json, text/plain, */*",
                "referer": f"https://channels.weixin.qq.com/finder-preview/pages/sph?id={sph_id}",
                "user-agent": UA_PC,
            },
            timeout=20,
            impersonate="chrome",
        )
        payload = r.json() if r.text else {}
        return payload.get("data") or {}

    def _feed_via_yuanbao(self, share_url: str, cookie: str) -> dict[str, Any]:
        from curl_cffi import requests as cffi

        r = cffi.post(
            self.YUANBAO_API,
            json={"type": "video_channel_url", "url": share_url, "scene": 1},
            headers={
                "content-type": "application/json",
                "origin": "https://yuanbao.tencent.com",
                "referer": "https://yuanbao.tencent.com/",
                "cookie": cookie,
                "user-agent": UA_PC,
            },
            timeout=20,
            impersonate="chrome",
        )
        if r.status_code in (401, 403):
            raise FetchError("登录已过期，需要重新登录腾讯元宝")
        payload = r.json() if r.text else {}
        data = payload.get("data") or {}
        playable = data.get("playable_url") or ""
        parsed = urlparse(playable)
        qs = parse_qs(parsed.query)
        token = (qs.get("token") or [""])[0]
        eid = (qs.get("eid") or [""])[0]
        if not token or not eid:
            raise FetchError("元宝未能返回视频号预览凭证")
        from curl_cffi import requests as cffi2

        r2 = cffi2.post(
            self.FEED_API,
            json={"baseReq": {"generalToken": token}, "exportId": eid},
            headers={
                "content-type": "application/json",
                "origin": "https://channels.weixin.qq.com",
                "referer": "https://channels.weixin.qq.com/finder-preview/pages/feed",
                "user-agent": UA_PC,
            },
            timeout=20,
            impersonate="chrome",
        )
        return (r2.json() or {}).get("data") or {}

    @staticmethod
    def _media_urls(feed: Optional[dict[str, Any]]) -> list[str]:
        info = (feed or {}).get("feedInfo") or {}
        urls: list[str] = []
        for key in ("h264VideoInfo", "h265VideoInfo"):
            vu = ((info.get(key) or {}).get("videoUrl") or "").strip()
            if vu:
                urls.append(ensure_https(vu))
        if info.get("videoUrl"):
            urls.append(ensure_https(info["videoUrl"]))
        seen = set()
        unique = []
        for item in urls:
            if item and item not in seen:
                seen.add(item)
                unique.append(item)
        return unique

    @staticmethod
    def _sph_id(url: str) -> Optional[str]:
        match = SPH_ID_RE.search(url or "")
        return match.group(1) if match else None

    @staticmethod
    def _cookie() -> str:
        return read_weixin_cookie()


YOUTUBE_ID_RE = re.compile(
    r"(?:youtube\.com/(?:watch\?(?:[^#]*&)?v=|shorts/|embed/|live/|v/)|youtu\.be/)([A-Za-z0-9_-]{11})",
    re.I,
)

QUALITY_CHOICES = ("auto", "1080", "720", "480", "360")
QUALITY_BANDS = {
    360: (300, 420),
    480: (430, 600),
    720: (640, 820),
    1080: (900, 1400),
}


def normalize_quality(value: str) -> str:
    key = str(value or "auto").strip().lower().replace("p", "")
    if key in {"best", "max", "highest", ""}:
        return "auto"
    return key if key in QUALITY_CHOICES else "auto"


def quality_height(quality: str) -> Optional[int]:
    key = normalize_quality(quality)
    if key == "auto":
        return None
    return int(key)


def ffmpeg_path() -> str:
    found = shutil.which("ffmpeg") or ""
    if found:
        return found
    try:
        import imageio_ffmpeg

        path = imageio_ffmpeg.get_ffmpeg_exe()
        if path and Path(path).is_file():
            return path
    except Exception:
        pass
    return ""


def height_matches(quality: str, actual: int) -> bool:
    cap = quality_height(quality)
    if cap is None:
        return actual > 0
    if not actual:
        return False
    lo, hi = QUALITY_BANDS.get(cap, (cap - 80, cap + 200))
    return lo <= actual <= hi


def probe_video_height(path: Path) -> int:
    ffmpeg = ffmpeg_path()
    if not ffmpeg or not path.is_file():
        return 0
    try:
        proc = subprocess.run(
            [ffmpeg, "-hide_banner", "-i", str(path)],
            capture_output=True,
            text=True,
            timeout=20,
        )
        blob = (proc.stderr or "") + (proc.stdout or "")
        match = re.search(r"Video:.*?\s(\d{2,5})x(\d{2,5})\b", blob)
        if match:
            width, height = int(match.group(1)), int(match.group(2))
            # 竖屏 720x1280 的「720p」看短边，不要把长边当成 1080p。
            return min(width, height)
    except Exception:
        pass
    return 0


def ytdlp_bin_path() -> str:
    path = ROOT_DIR / "bin" / "yt-dlp-macos"
    if sys.platform == "darwin" and path.is_file() and os.access(path, os.X_OK):
        return str(path)
    return ""


def ytdlp_format_spec(quality: str, can_merge: bool, *, strict: bool = False) -> str:
    """Pick a yt-dlp format string. Merge needs ffmpeg; otherwise only muxed mp4.

    strict=True means do not fall through to 360p itag 18 when the user asked
    for 720/1080. That silent downgrade is what made the selector lie.
    """
    height = quality_height(quality)
    if height:
        lo = QUALITY_BANDS.get(height, (height - 80, height))[0]
        cap = f"[height<=?{height}][height>={lo}]"
    else:
        cap = ""
    if can_merge:
        spec = (
            f"bv*{cap}[ext=mp4]+ba[ext=m4a]/"
            f"bv*{cap}+ba/"
            f"b{cap}[ext=mp4]/"
            f"b{cap}"
        )
        if not strict:
            spec += "/18/best"
        return spec
    spec = f"b{cap}[ext=mp4][acodec!=none][vcodec!=none]"
    if not strict:
        spec += "/22/18/best[ext=mp4]/best"
    return spec


def youtube_attempts(quality: str) -> list[dict[str, Any]]:
    can_merge = bool(ffmpeg_path())
    q = normalize_quality(quality)
    strict = q not in {"auto", "360"}
    spec = ytdlp_format_spec(quality, can_merge, strict=strict)
    muxed = ytdlp_format_spec(quality, False, strict=strict)
    label = "自动" if q == "auto" else f"{q}p"
    attempts: list[dict[str, Any]] = []
    if ytdlp_bin_path():
        attempts.append(
            {
                "engine": "bin",
                "client": [],
                "format": spec,
                "cookies": False,
                "label": f"{label}",
            }
        )
        attempts.append(
            {
                "engine": "bin",
                "client": [],
                "format": spec,
                "cookies": True,
                "label": f"{label} + 登录",
            }
        )
    # 360p 用一体流更快；更高清晰度才值得拆轨再合并。
    if can_merge and q != "360":
        attempts.append(
            {
                "engine": "py",
                "client": ["android_vr"],
                "format": spec,
                "cookies": False,
                "label": f"Android VR {label}",
            }
        )
    if q in {"auto", "360"}:
        attempts.append(
            {
                "engine": "py",
                "client": ["android"],
                "format": muxed,
                "cookies": False,
                "label": f"Android 直链 {label}",
            }
        )
        attempts.append(
            {
                "engine": "py",
                "client": ["android"],
                "format": muxed,
                "cookies": True,
                "label": f"Android + 登录 {label}",
            }
        )
    return attempts


def canonicalize_youtube_url(url: str) -> str:
    match = YOUTUBE_ID_RE.search(url or "")
    if match:
        return f"https://www.youtube.com/watch?v={match.group(1)}"
    return url


def _ytdlp_result(info: dict[str, Any], url: str, local: Optional[str]) -> ParseResult:
    if "entries" in info and info["entries"]:
        info = info["entries"][0]
    media_url = info.get("url") or ""
    ext = info.get("ext") or "mp4"
    return ParseResult(
        platform=info.get("extractor_key") or detect_platform(url),
        content_id=str(info.get("id") or ""),
        title=info.get("title") or "",
        author=info.get("uploader") or info.get("channel") or "",
        description=info.get("description") or "",
        items=[MediaItem(url=media_url, kind="video", ext=ext, index=1)],
        extra={
            "filepath": local,
            "webpage_url": info.get("webpage_url"),
            "height": info.get("height") or 0,
            "width": info.get("width") or 0,
        },
    )


def _ytdlp_once(
    url: str,
    out_dir: Path,
    info_only: bool,
    cookie: str,
    cookies_from_browser: str,
    attempt: Optional[dict[str, Any]],
    progress: Any = None,
    format_override: str = "",
) -> ParseResult:
    import yt_dlp

    out_dir.mkdir(parents=True, exist_ok=True)
    opts: dict[str, Any] = {
        "outtmpl": str(out_dir / "%(extractor)s_%(uploader,NA)s_%(id)s_%(title).80s.%(ext)s"),
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "overwrites": True,
        "merge_output_format": "mp4",
        "format": "b/bv*+ba/best",
        "format_sort": ["res", "vcodec:h264", "acodec:m4a", "ext:mp4"],
        "retries": 5,
        "fragment_retries": 8,
        "skip_unavailable_fragments": False,
        "concurrent_fragment_downloads": 1,
        "http_headers": {"User-Agent": UA_PC},
    }
    ffmpeg = ffmpeg_path()
    if ffmpeg:
        opts["ffmpeg_location"] = ffmpeg
    use_cookies = bool(cookies_from_browser)
    if format_override:
        opts["format"] = format_override
    if attempt:
        opts["format"] = attempt["format"]
        clients = list(attempt.get("client") or [])
        if clients:
            opts["extractor_args"] = {"youtube": {"player_client": clients}}
        use_cookies = bool(attempt.get("cookies")) and bool(cookies_from_browser)
        # SABR HLS is the failure mode we are walking away from.
        opts["abort_on_unavailable_fragments"] = True
    else:
        try:
            from yt_dlp.networking.impersonate import ImpersonateTarget

            opts["impersonate"] = ImpersonateTarget("chrome")
        except Exception:
            pass
    if cookie:
        opts.setdefault("http_headers", {})["Cookie"] = cookie
    if use_cookies:
        opts["cookiesfrombrowser"] = (cookies_from_browser,)

    def hook(status: dict[str, Any]) -> None:
        if not progress or status.get("status") != "downloading":
            return
        received = int(status.get("downloaded_bytes") or 0)
        total = int(status.get("total_bytes") or status.get("total_bytes_estimate") or 0)
        progress(
            {
                "type": "progress",
                "id": "file-video-1",
                "label": "下载视频",
                "received": received,
                "total": total,
            }
        )

    opts["progress_hooks"] = [hook]
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=not info_only)
    except Exception as exc:
        raise FetchError(str(exc).split("please report")[0].strip()) from exc
    if info is None:
        raise FetchError("yt-dlp 没有返回信息")
    if "entries" in info and info["entries"]:
        info = info["entries"][0]
    requested = info.get("requested_downloads") or [{}]
    local = requested[0].get("filepath") if requested else None
    if not info_only:
        path = Path(local) if local else None
        if path is None or not path.is_file() or path.stat().st_size < 2048:
            if path and path.exists():
                try:
                    path.unlink()
                except OSError:
                    pass
            raise FetchError("下载结果是空文件")
        probed = probe_video_height(path)
        if probed:
            info["height"] = probed
    return _ytdlp_result(info, url, local)


def _ytdlp_bin_once(
    url: str,
    out_dir: Path,
    quality: str,
    cookies_from_browser: str,
    attempt: dict[str, Any],
    progress: Any = None,
) -> ParseResult:
    bin_path = ytdlp_bin_path()
    if not bin_path:
        raise FetchError("没有找到 YouTube 下载引擎")
    out_dir.mkdir(parents=True, exist_ok=True)
    vid = canonicalize_youtube_url(url).rsplit("v=", 1)[-1]
    stem = f"youtube_{vid}_{normalize_quality(quality)}"
    outtmpl = str(out_dir / (stem + ".%(ext)s"))
    ffmpeg = ffmpeg_path()
    cmd = [
        bin_path,
        url,
        "--no-playlist",
        "--newline",
        "--retries",
        "5",
        "--fragment-retries",
        "8",
        "--merge-output-format",
        "mp4",
        "-f",
        str(attempt["format"]),
        "-S",
        "res,vcodec:h264,acodec:m4a,ext:mp4",
        "-o",
        outtmpl,
        "--print",
        "after_move:%(filepath)s",
        "--print",
        "after_move:%(height)s",
        "--print",
        "after_move:%(title)s",
        "--print",
        "after_move:%(uploader)s",
        "--print",
        "after_move:%(id)s",
        "--no-warnings",
    ]
    if ffmpeg:
        cmd.extend(["--ffmpeg-location", ffmpeg])
    if attempt.get("cookies") and cookies_from_browser:
        cmd.extend(["--cookies-from-browser", cookies_from_browser])

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    printed: list[str] = []
    err_lines: list[str] = []
    assert proc.stderr is not None and proc.stdout is not None
    pct_re = re.compile(r"\[download\]\s+(\d+(?:\.\d+)?)%")
    of_re = re.compile(r"of\s+~?([\d.]+)\s*(KiB|MiB|GiB)")

    def to_bytes(num: str, unit: str) -> int:
        n = float(num)
        return int(n * {"KiB": 1024, "MiB": 1024**2, "GiB": 1024**3}[unit])

    while True:
        line = proc.stderr.readline()
        if not line:
            break
        err_lines.append(line.rstrip())
        match = pct_re.search(line)
        if match and progress:
            pct = float(match.group(1))
            size_m = of_re.search(line)
            total = to_bytes(size_m.group(1), size_m.group(2)) if size_m else 0
            received = int(total * pct / 100) if total else 0
            progress(
                {
                    "type": "progress",
                    "id": "file-video-1",
                    "label": "下载视频",
                    "received": received,
                    "total": total,
                }
            )
    stdout = proc.stdout.read() if proc.stdout else ""
    code = proc.wait()
    printed = [ln.strip() for ln in stdout.splitlines() if ln.strip()]
    if code != 0:
        blob = "\n".join(err_lines[-8:])
        raise FetchError(blob.split("please report")[0].strip() or "YouTube 下载失败")

    filepath = printed[0] if printed else ""
    height = int(printed[1]) if len(printed) > 1 and str(printed[1]).isdigit() else 0
    title = printed[2] if len(printed) > 2 else ""
    uploader = printed[3] if len(printed) > 3 else ""
    content_id = printed[4] if len(printed) > 4 else vid
    if not filepath:
        cands = [
            p
            for p in out_dir.glob(stem + ".*")
            if p.suffix.lower() in {".mp4", ".mkv", ".webm", ".m4a"}
        ]
        if cands:
            filepath = str(sorted(cands, key=lambda p: p.stat().st_mtime)[-1])
    path = Path(filepath) if filepath else None
    if path is None or not path.is_file() or path.stat().st_size < 2048:
        raise FetchError("下载结果是空文件")
    probed = probe_video_height(path) or height
    info = {
        "extractor_key": "Youtube",
        "id": content_id,
        "title": title,
        "uploader": uploader,
        "ext": path.suffix.lstrip(".") or "mp4",
        "url": "",
        "webpage_url": url,
        "height": probed,
        "width": 0,
    }
    return _ytdlp_result(info, url, str(path))


def ytdlp_download(
    url: str,
    out_dir: Path,
    info_only: bool,
    cookie: str,
    cookies_from_browser: str = "",
    progress: Any = None,
    quality: str = "auto",
) -> ParseResult:
    platform = detect_platform(url)
    quality = normalize_quality(quality)
    if platform != "youtube":
        return _ytdlp_once(
            url,
            out_dir,
            info_only,
            cookie,
            cookies_from_browser,
            None,
            progress,
            format_override=ytdlp_format_spec(quality, bool(ffmpeg_path())),
        )

    url = canonicalize_youtube_url(url)
    errors: list[str] = []
    wanted = quality_height(quality)
    for attempt in youtube_attempts(quality):
        label = str(attempt["label"])
        if progress:
            progress(
                {
                    "type": "step",
                    "id": "parse",
                    "label": "解析作品",
                    "detail": f"YouTube · {label}",
                    "state": "active",
                }
            )
        print(f"  YouTube 尝试 {label}")
        try:
            if attempt.get("engine") == "bin":
                result = _ytdlp_bin_once(
                    url, out_dir, quality, cookies_from_browser or "chrome", attempt, progress
                )
            else:
                result = _ytdlp_once(
                    url, out_dir, info_only, cookie, cookies_from_browser, attempt, progress
                )
        except Exception as exc:
            msg = str(exc).strip().splitlines()[0][:160]
            errors.append(f"{label}: {msg}")
            print(f"  YouTube {label} 失败: {msg}")
            continue
        actual = int((result.extra or {}).get("height") or 0)
        if wanted and not height_matches(quality, actual):
            path = result.extra.get("filepath")
            if path:
                try:
                    Path(str(path)).unlink()
                except OSError:
                    pass
            msg = f"要的是 {wanted}p，实际是 {actual or '?'}p"
            errors.append(f"{label}: {msg}")
            print(f"  YouTube {label} 清晰度不符: {msg}")
            continue
        return result
    if wanted:
        raise FetchError(
            f"要不到 {wanted}p。"
            "YouTube 把这一档的直链拦了，请改选更低清晰度，或在 Chrome 登录后再试。"
            + ((" " + errors[-1]) if errors else "")
        )
    raise FetchError(
        "YouTube 网页端被改成加密流，直链客户端也没拿到完整文件。"
        + (errors[-1] if errors else "")
    )


def _media_headers(referer: str, cookie: str = "") -> dict[str, str]:
    headers = {
        "User-Agent": UA_PC,
        "Accept": "*/*",
        "Accept-Encoding": "identity",
        "Referer": referer or "https://www.xiaohongshu.com/",
        "Origin": "https://www.xiaohongshu.com",
        "Connection": "close",
    }
    if cookie:
        headers["Cookie"] = cookie
    return headers


def _save_stream(
    resp,
    dest: Path,
    url: str,
    default_ext: str,
    content_type: str = "",
    total: int = 0,
    on_progress: Any = None,
) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix((dest.suffix or ".bin") + ".part")
    size = 0
    with tmp.open("wb") as handle:
        while True:
            chunk = resp.read(256 * 1024)
            if not chunk:
                break
            handle.write(chunk)
            size += len(chunk)
            if on_progress:
                on_progress(size, total or 0)
    if size < 1024:
        tmp.unlink(missing_ok=True)
        raise FetchError(f"下载内容过小: {url}")
    ext = guess_ext(url, content_type, default_ext)
    path = dest.with_suffix("." + ext)
    tmp.replace(path)
    return path


def _download_urllib(
    url: str,
    dest: Path,
    referer: str,
    cookie: str,
    default_ext: str,
    on_progress: Any = None,
) -> Path:
    req = Request(url, headers=_media_headers(referer, cookie))
    with urlopen(req, timeout=45) as resp:
        total = int(resp.headers.get("Content-Length") or 0)
        return _save_stream(
            resp,
            dest,
            url,
            default_ext,
            resp.headers.get("Content-Type", ""),
            total=total,
            on_progress=on_progress,
        )


def _download_httpx(
    url: str,
    dest: Path,
    referer: str,
    cookie: str,
    default_ext: str,
    on_progress: Any = None,
) -> Path:
    import httpx

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix((dest.suffix or ".bin") + ".part")
    with httpx.Client(
        headers=_media_headers(referer, cookie),
        timeout=45,
        follow_redirects=True,
        http2=False,
    ) as client:
        with client.stream("GET", url) as resp:
            if resp.status_code >= 400:
                raise FetchError(f"下载失败 HTTP {resp.status_code}: {url}")
            size = 0
            total = int(resp.headers.get("content-length") or 0)
            with tmp.open("wb") as handle:
                for chunk in resp.iter_bytes(256 * 1024):
                    if not chunk:
                        continue
                    handle.write(chunk)
                    size += len(chunk)
                    if on_progress:
                        on_progress(size, total)
            ctype = resp.headers.get("content-type", "")
    if size < 1024:
        tmp.unlink(missing_ok=True)
        raise FetchError(f"下载内容过小: {url}")
    ext = guess_ext(url, ctype, default_ext)
    path = dest.with_suffix("." + ext)
    tmp.replace(path)
    return path


def _download_cffi(http: Http, url: str, dest: Path, referer: str, default_ext: str) -> Path:
    extra = {"Origin": "https://www.xiaohongshu.com"} if "xiaohongshu" in referer else {}
    resp = http.get(
        url,
        referer=referer,
        extra_headers=extra,
        impersonate="",
        timeout=45,
        media=True,
    )
    if resp.status_code >= 400:
        raise FetchError(f"下载失败 HTTP {resp.status_code}: {url}")
    data = resp.content
    if not data or len(data) < 1024:
        raise FetchError(f"下载内容过小: {url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    ext = guess_ext(url, resp.headers.get("content-type", ""), default_ext)
    path = dest.with_suffix("." + ext)
    path.write_bytes(data)
    return path


def download_item(
    http: Http,
    item: MediaItem,
    dest: Path,
    referer: str,
    on_progress: Any = None,
) -> Path:
    raw_urls = [item.url, *item.backups]
    if any("xhscdn.com" in (u or "") or "xiaohongshu" in (u or "") for u in raw_urls):
        urls = expand_xhs_video_urls(raw_urls)
    else:
        urls = []
        seen = set()
        for url in raw_urls:
            url = ensure_https(url)
            if url and url not in seen:
                seen.add(url)
                urls.append(url)
    errors: list[str] = []
    for url in urls:
        for name, worker in (
            ("urllib", lambda u: _download_urllib(u, dest, referer, http.cookie, item.ext, on_progress)),
            ("httpx", lambda u: _download_httpx(u, dest, referer, http.cookie, item.ext, on_progress)),
            ("cffi", lambda u: _download_cffi(http, u, dest, referer, item.ext)),
        ):
            try:
                return worker(url)
            except Exception as exc:
                errors.append(f"{name} {urlparse(url).netloc}: {exc}")
                continue
    raise FetchError("视频下载失败，CDN 连接被断开。已尝试备用线路。" + " | ".join(errors[:4]))


def parse_and_download(
    text: str,
    out_dir: Path,
    http: Http,
    image_format: str,
    info_only: bool,
    prefer_ytdlp: bool,
    cookies_from_browser: str = "",
    progress: Any = None,
    transcribe: bool = False,
    quality: str = "auto",
    profile_limit: int = PROFILE_LIMIT_DEFAULT,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    quality = normalize_quality(quality)
    profile_limit = max(1, min(int(profile_limit or PROFILE_LIMIT_DEFAULT), PROFILE_LIMIT_MAX))

    def emit(event: dict[str, Any]) -> None:
        if progress:
            progress(event)

    urls = extract_urls(text)
    if not urls:
        raise FetchError("请先粘贴一条分享口令。")
    expanded: list[str] = []
    for raw in urls:
        if is_profile_url(raw):
            expanded.extend(expand_profile(raw, limit=profile_limit, progress=emit))
        else:
            expanded.append(raw)
    urls = []
    seen_u: set[str] = set()
    for item in expanded:
        if item not in seen_u:
            seen_u.add(item)
            urls.append(item)
    if len(urls) > BATCH_LIMIT:
        urls = urls[:BATCH_LIMIT]

    def process_one(url: str, emit: Any) -> dict[str, Any]:
        platform = detect_platform(url)
        label = PLATFORM_LABELS.get(platform, platform)
        print(f"\n→ {platform}: {url}")
        emit({"type": "step", "id": "link", "label": "识别链接", "detail": label, "state": "done"})
        emit({"type": "step", "id": "parse", "label": "解析作品", "detail": "正在读取页面", "state": "active"})

        if platform == "xiaohongshu":
            engines = ["xiaohongshu", "yt-dlp"]
        elif prefer_ytdlp:
            engines = ["yt-dlp"]
        elif platform == "douyin":
            engines = ["douyin", "yt-dlp"]
        elif platform == "tiktok":
            engines = ["tiktok", "yt-dlp"]
        elif platform == "weixin":
            engines = ["weixin"]
        elif platform == "kuaishou":
            engines = ["kuaishou", "yt-dlp"]
        else:
            engines = ["yt-dlp"]

        result: Optional[ParseResult] = None
        used = engines[0]
        errors: list[str] = []
        for engine in engines:
            try:
                if engine == "xiaohongshu":
                    result = XiaohongshuExtractor(http, image_format=image_format).parse(url)
                elif engine == "douyin":
                    result = DouyinExtractor(http, quality=quality).parse(url)
                elif engine == "tiktok":
                    result = TikTokExtractor(http).parse(url)
                elif engine == "weixin":
                    result = WeixinExtractor(http, progress=emit).parse(url)
                elif engine == "kuaishou":
                    result = KuaishouExtractor(http, quality=quality).parse(url)
                else:
                    result = ytdlp_download(
                        url,
                        out_dir,
                        info_only,
                        http.cookie,
                        cookies_from_browser=cookies_from_browser or "chrome",
                        progress=emit,
                        quality=quality,
                    )
                used = engine
                emit(
                    {
                        "type": "step",
                        "id": "parse",
                        "label": "解析作品",
                        "detail": (result.title or "")[:36],
                        "state": "done",
                    }
                )
                break
            except Exception as exc:
                msg = str(exc).strip()
                errors.append(f"{engine}: {msg}")
                print(f"  {engine} 失败: {msg}")
                emit(
                    {
                        "type": "step",
                        "id": "parse",
                        "label": "解析作品",
                        "detail": "换一种方式",
                        "state": "active",
                    }
                )
        if result is None and platform != "xiaohongshu" and any(
            "XiaoHongShu" in e or "xiaohongshu" in e.lower() for e in errors
        ):
            try:
                result = XiaohongshuExtractor(http, image_format=image_format).parse(url)
                used = "xiaohongshu"
                emit(
                    {
                        "type": "step",
                        "id": "parse",
                        "label": "解析作品",
                        "detail": (result.title or "")[:36],
                        "state": "done",
                    }
                )
            except Exception as exc:
                errors.append(f"xiaohongshu: {exc}")
                print(f"  xiaohongshu 失败: {exc}")
        if result is None:
            hint = ""
            if platform in {"tiktok", "douyin"}:
                hint = "。可再试 --cookies-from-browser chrome"
            friendly = {
                "douyin": "这条抖音暂时打不开。请重新复制一条最新分享口令再试。",
                "xiaohongshu": "这条小红书暂时打不开。请用 App 里刚复制的分享口令。",
                "tiktok": "这条 TikTok 暂时打不开。可先在浏览器登录后再试。",
                "weixin": "已识别到视频号。扫码窗口是单独的浏览器，不在这个页面里。用微信扫码后即可保存。如果被挡住了，看 Dock 里的 Chromium。",
                "kuaishou": "这条快手暂时打不开。请用 App 里刚复制的分享口令。",
                "youtube": "YouTube 正在限制网页直链。已自动换客户端重试仍失败，请在 Chrome 登录 YouTube 后再试。",
            }.get(platform, "没能识别或打开这条链接。")
            if platform == "weixin" and errors:
                friendly = errors[-1].split(": ", 1)[-1]
            if platform == "youtube" and errors:
                last = errors[-1].split(": ", 1)[-1]
                if "YouTube" in last or "加密流" in last:
                    friendly = last
            # 视频号走自己的扫码窗口，不要改去打开别的站点登录页
            wall = platform != "weixin" and any(LOGIN_WALL_RE.search(e) for e in errors)
            if wall and platform in LOGIN_URLS:
                label = PLATFORM_LABELS.get(platform, platform)
                raise FetchError(
                    f"{label} 要求登录后才能读取这条内容。",
                    needs_login=platform,
                )
            if platform == "weixin" and re.search(r"登录|扫码", friendly):
                raise FetchError(friendly, needs_login="weixin")
            raise FetchError(friendly)

        assert result is not None
        folder_name = safe_name(f"{result.platform}_{result.author}_{result.title}_{result.content_id}")
        target_dir = out_dir / folder_name
        saved: list[str] = []

        if info_only:
            print(f"  标题: {result.title}")
            print(f"  作者: {result.author}")
            for item in result.items:
                print(f"  [{item.kind}] {item.url}")
        elif used == "yt-dlp" and result.extra.get("filepath"):
            src = Path(str(result.extra["filepath"]))
            target_dir.mkdir(parents=True, exist_ok=True)
            dest = target_dir / src.name
            if src.exists() and src.resolve() != dest.resolve():
                if dest.exists():
                    dest.unlink()
                shutil.move(str(src), str(dest))
                src = dest
            saved.append(str(src))
            result.extra["filepath"] = str(src)
            print(f"  已保存: {src}")
            probed = probe_video_height(src)
            if probed:
                result.extra["height"] = probed
        else:
            referer = {
                "xiaohongshu": "https://www.xiaohongshu.com/",
                "douyin": "https://www.douyin.com/",
                "tiktok": "https://www.tiktok.com/",
                "weixin": "https://channels.weixin.qq.com/",
                "kuaishou": "https://www.kuaishou.com/",
            }.get(result.platform, url)
            failures: list[str] = []
            total_items = len(result.items)
            for item in result.items:
                stem = f"{item.kind}_{item.index:02d}"
                kind_name = KIND_LABELS.get(item.kind, item.kind)
                step_id = f"file-{item.kind}-{item.index}"
                emit(
                    {
                        "type": "step",
                        "id": step_id,
                        "label": f"下载{kind_name}",
                        "detail": f"{item.index}/{total_items}",
                        "state": "active",
                    }
                )

                def on_bytes(received: int, total: int, sid: str = step_id, kn: str = kind_name) -> None:
                    emit(
                        {
                            "type": "progress",
                            "id": sid,
                            "label": f"下载{kn}",
                            "received": received,
                            "total": total,
                        }
                    )

                try:
                    path = download_item(
                        http,
                        item,
                        target_dir / stem,
                        referer,
                        on_progress=on_bytes,
                    )
                except Exception as exc:
                    failures.append(f"{item.kind}{item.index}: {exc}")
                    print(f"  {item.kind} {item.index} 失败: {exc}")
                    emit(
                        {
                            "type": "step",
                            "id": step_id,
                            "label": f"下载{kind_name}",
                            "detail": "失败，跳过",
                            "state": "error",
                        }
                    )
                    continue
                saved.append(str(path))
                size_mb = path.stat().st_size / (1024 * 1024)
                print(f"  已保存 {item.kind} {item.index}: {path} ({size_mb:.2f} MB)")
                emit(
                    {
                        "type": "step",
                        "id": step_id,
                        "label": f"下载{kind_name}",
                        "detail": format_size(path.stat().st_size),
                        "state": "done",
                    }
                )
            if not saved:
                raise FetchError("全部文件下载失败: " + " | ".join(failures[:3]))
            if failures:
                print("  部分失败: " + " | ".join(failures[:3]))

        for saved_path in saved:
            probed = probe_video_height(Path(saved_path))
            if probed:
                result.extra["height"] = probed
                break
        actual_h = int((result.extra or {}).get("height") or 0)
        wanted_h = quality_height(quality)
        if wanted_h and actual_h and not height_matches(quality, actual_h):
            raise FetchError(
                f"你选的是 {normalize_quality(quality)}p，实际文件是 {actual_h}p。"
                "没有按选项保存。请改清晰度后再试。"
            )

        meta_path = target_dir / "meta.json"
        meta_path.parent.mkdir(parents=True, exist_ok=True)
        meta_path.write_text(
            json.dumps(
                {
                    "title": result.title,
                    "author": result.author,
                    "platform": result.platform,
                    "id": result.content_id,
                    "height": int((result.extra or {}).get("height") or 0),
                    "quality": normalize_quality(quality),
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

        report = {
            "platform": result.platform,
            # Must match the id /api/recent reports for the same folder, or the
            # panel shows one row for the fresh result and one for the history entry.
            "id": str(result.content_id or folder_name),
            "dir": folder_name,
            "title": result.title,
            "author": result.author,
            "created": int(time.time()),
            "engine": used,
            "files": saved,
            "previews": [file_preview(Path(p), out_dir) for p in saved],
            "urls": [item.url for item in result.items],
            "height": int((result.extra or {}).get("height") or 0),
            "quality": normalize_quality(quality),
        }

        if transcribe and not info_only:
            report["transcript"] = run_transcription(
                target_dir, title=result.title, progress=emit
            )
            report["previews"] = _folder_previews(target_dir, out_dir)

        return report

    reports: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    total = len(urls)
    base_emit = emit

    for index, url in enumerate(urls, start=1):
        prefix = f"i{index}-"

        def item_emit(
            event: dict[str, Any],
            _prefix: str = prefix,
            _index: int = index,
            _total: int = total,
        ) -> None:
            ev = dict(event)
            if ev.get("type") in {"step", "progress"} and ev.get("id"):
                eid = str(ev["id"])
                if eid != "batch" and not eid.startswith("i"):
                    ev["id"] = _prefix + eid
            if _total > 1 and ev.get("type") == "step" and str(ev.get("id") or "").endswith("-parse"):
                ev["label"] = f"解析作品 {_index}/{_total}"
            base_emit(ev)

        if total > 1:
            base_emit(
                {
                    "type": "step",
                    "id": "batch",
                    "label": "批量保存",
                    "detail": f"{index}/{total}",
                    "state": "active",
                }
            )

        try:
            report = process_one(url, item_emit)
        except FetchError as exc:
            fail = {
                "index": index,
                "total": total,
                "url": url,
                "error": str(exc),
                "needs_login": getattr(exc, "needs_login", "") or "",
            }
            failures.append(fail)
            base_emit({"type": "item", "ok": False, **fail})
            base_emit(
                {
                    "type": "step",
                    "id": prefix + "parse",
                    "label": f"解析作品 {index}/{total}" if total > 1 else "解析作品",
                    "detail": str(exc)[:48],
                    "state": "error",
                }
            )
            print(f"  跳过 ({index}/{total}): {exc}")
            continue
        except Exception as exc:
            fail = {
                "index": index,
                "total": total,
                "url": url,
                "error": str(exc).strip()[:160],
                "needs_login": "",
            }
            failures.append(fail)
            base_emit({"type": "item", "ok": False, **fail})
            print(f"  跳过 ({index}/{total}): {exc}")
            continue

        reports.append(report)
        base_emit({"type": "item", "ok": True, "index": index, "total": total, "report": report})

    if total > 1:
        base_emit(
            {
                "type": "step",
                "id": "batch",
                "label": "批量保存",
                "detail": f"成功 {len(reports)} · 失败 {len(failures)}",
                "state": "done" if reports else "error",
            }
        )

    if not reports:
        login = next((str(f.get("needs_login") or "") for f in failures if f.get("needs_login")), "")
        if len(failures) == 1:
            raise FetchError(str(failures[0]["error"]), needs_login=login)
        raise FetchError(
            f"{len(failures)} 条都没保存成功。" + (str(failures[0]["error"]) if failures else ""),
            needs_login=login,
        )
    return reports, failures


def run_transcription(folder: Path, title: str = "", progress: Any = None) -> dict[str, Any]:
    """转写一个作品目录。失败不该拖垮下载——文件已经存好了。"""

    def emit(detail: str, state: str = "active") -> None:
        if progress:
            progress(
                {
                    "type": "step",
                    "id": "transcribe",
                    "label": "转文案",
                    "detail": detail,
                    "state": state,
                }
            )

    existing = read_transcript(folder)
    if existing:
        emit("已有逐字稿", "done")
        return existing

    if not transcribe_ready():
        emit("转写环境未就绪", "error")
        return {"error": "转写环境未安装。"}

    media = pick_transcribable(folder)
    if media is None:
        emit("没有可转写的音视频", "done")
        return {"skipped": "这条没有音视频文件。"}

    emit("准备转写")
    try:
        result = ASR_WORKER.transcribe(media, progress=lambda msg: emit(msg))
    except Exception as exc:
        print(f"  转写失败: {exc}")
        emit("转写失败", "error")
        return {"error": str(exc)}

    write_transcript(folder, result, title=title)
    cues = subs.cues_from_segments(result.get("segments") or [])
    if cues:
        try:
            subs.save_subtitle_set(
                folder,
                cues,
                title=title,
                language="transcript",
                source="transcript",
                approximate=True,
            )
        except subs.SubtitleError:
            pass
    if result.get("empty_reason"):
        emit("没识别到人声", "done")
    else:
        emit(f"{len(result.get('text') or '')} 字", "done")
    return result


def file_kind(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in {".mp4", ".mov", ".m4v", ".webm"}:
        return "video"
    if ext in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic"}:
        return "image"
    return "file"


def file_mime(path: Path) -> str:
    return {
        ".mp4": "video/mp4",
        ".mov": "video/quicktime",
        ".m4v": "video/mp4",
        ".webm": "video/webm",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".webp": "image/webp",
        ".gif": "image/gif",
        ".vtt": "text/vtt",
        ".srt": "application/x-subrip",
        ".txt": "text/plain",
    }.get(path.suffix.lower(), "application/octet-stream")


def file_preview(path: Path, out_dir: Path) -> dict[str, Any]:
    resolved = path.expanduser().resolve()
    try:
        rel = resolved.relative_to(out_dir.expanduser().resolve())
    except ValueError:
        rel = Path(resolved.name)
    href = "/media/" + quote(str(rel).replace("\\", "/"))
    return {
        "name": resolved.name,
        "kind": file_kind(resolved),
        "href": href,
        "size": resolved.stat().st_size,
    }


def list_recent(out_dir: Path, limit: int = 12) -> list[dict[str, Any]]:
    if not out_dir.exists():
        return []
    folders = [p for p in out_dir.iterdir() if p.is_dir() and not p.name.startswith(".")]
    folders.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    recent = []
    for folder in folders[:limit]:
        # meta.json 和转写产物都不是作品文件，别混进预览里
        sidecars = {"meta.json", TRANSCRIPT_JSON, TRANSCRIPT_MD, subs.SUBS_JSON}
        files = [
            p
            for p in sorted(folder.iterdir(), key=lambda x: x.name)
            if p.is_file() and not p.name.endswith(".part") and p.name not in sidecars
        ]
        if not files:
            continue
        meta = {}
        meta_file = folder / "meta.json"
        if meta_file.exists():
            try:
                meta = json.loads(meta_file.read_text(encoding="utf-8"))
            except Exception:
                meta = {}
        title = (meta.get("title") or "").strip() or folder.name
        recent.append(
            {
                # The panel dedupes history by id, so fall back to the folder name
                # when meta.json predates this field.
                "id": str(meta.get("id") or folder.name),
                "dir": folder.name,
                "title": title,
                "author": meta.get("author") or "",
                "platform": meta.get("platform") or folder.name.split("_", 1)[0],
                "height": int(meta.get("height") or 0),
                "quality": meta.get("quality") or "",
                "created": int(folder.stat().st_mtime),
                "transcript": transcript_brief(folder),
                "previews": [file_preview(p, out_dir) for p in files],
            }
        )
    return recent


def resolve_item_dir(out_dir: Path, name: str) -> Path:
    """把前端传来的目录名解析成真实路径，并挡住路径穿越。"""
    if not name or "/" in name or "\\" in name or name.startswith("."):
        raise FetchError("目录名不合法。")
    base = out_dir.expanduser().resolve()
    target = (base / name).resolve()
    if target != base and base not in target.parents:
        raise FetchError("目录名不合法。")
    if not target.is_dir():
        raise FetchError("这个作品目录不存在。")
    return target


def _folder_previews(folder: Path, out_dir: Path) -> list[dict[str, Any]]:
    sidecars = {"meta.json", TRANSCRIPT_JSON, TRANSCRIPT_MD, subs.SUBS_JSON}
    files = [
        path
        for path in sorted(folder.iterdir(), key=lambda item: item.name)
        if path.is_file() and not path.name.endswith(".part") and path.name not in sidecars
    ]
    return [file_preview(path, out_dir) for path in files]


def _subtitle_public(folder: Path, out_dir: Path, bundle: dict[str, Any], fmt: str) -> dict[str, Any]:
    meta = bundle["meta"]
    fmt = subs.normalize_format(fmt)
    return {
        "ok": True,
        "dir": folder.name,
        "title": meta.get("title") or "",
        "language": meta.get("language") or "",
        "language_label": subs.language_label(str(meta.get("language") or "")),
        "source": meta.get("source") or "",
        "source_label": subs.source_label(str(meta.get("source") or ""), bool(meta.get("approximate"))),
        "approximate": bool(meta.get("approximate")),
        "format": fmt,
        "text": (bundle.get("texts") or {}).get(fmt) or subs.render(
            bundle["cues"], fmt, note="时间按字数估算，不是平台精确字幕。" if meta.get("approximate") else ""
        ),
        "cues": bundle["cues"],
        "files": [file_preview(path, out_dir) for path in bundle.get("files") or []],
    }


def _bundle_from_folder(folder: Path) -> dict[str, Any]:
    saved = subs.read_saved(folder)
    if saved and saved.get("cues"):
        return subs.save_subtitle_set(
            folder,
            saved["cues"],
            title=str(saved.get("title") or ""),
            language=str(saved.get("language") or ""),
            source=str(saved.get("source") or "platform"),
            approximate=bool(saved.get("approximate")),
            url=str(saved.get("url") or ""),
        )
    transcript = read_transcript(folder)
    segments = (transcript or {}).get("segments") or []
    cues = subs.cues_from_segments(segments)
    if not cues:
        raise FetchError("这个作品还没有字幕。可以先保存视频，再用本机语音转成字幕。")
    meta_file = folder / "meta.json"
    title = ""
    if meta_file.is_file():
        try:
            title = str(json.loads(meta_file.read_text(encoding="utf-8")).get("title") or "")
        except Exception:
            title = ""
    return subs.save_subtitle_set(
        folder,
        cues,
        title=title,
        language="transcript",
        source="transcript",
        approximate=True,
    )


def _write_item_meta(folder: Path, title: str, platform: str, content_id: str) -> None:
    path = folder / "meta.json"
    if path.exists():
        return
    path.write_text(
        json.dumps(
            {
                "title": title,
                "author": "",
                "platform": platform,
                "id": content_id,
                "quality": "",
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


_SUB_LOGIN_RE = re.compile(r"sign in|login|403|bot|confirm you", re.I)


def _friendly_sub_error(url: str, detail: str) -> str:
    low = detail.lower()
    if "unavailable" in low or "private video" in low or "目前打不开" in detail:
        return "这条视频目前打不开，所以也拿不到字幕。"
    if "没有可下载的平台字幕" in detail or "no subtitles" in low:
        return (
            "这条没有可下载的平台字幕。"
            "YouTube 和 B 站一般有；抖音、小红书、TikTok 多数没有。"
            "可以先保存视频，再用本机语音转成字幕。"
        )
    if LOGIN_WALL_RE.search(detail) or _SUB_LOGIN_RE.search(detail):
        label = PLATFORM_LABELS.get(detect_platform(url), "这个网站")
        return f"{label} 要登录后才能读字幕。"
    text = (detail or "").strip().splitlines()[-1][:120] if detail else ""
    if text and "ERROR" not in text:
        return f"没能取到字幕。{text}"
    return "没能取到字幕。"


def _fetch_subs_retry(url: str, work: Path, lang: str, cookies_from_browser: str) -> dict[str, Any]:
    binary = ytdlp_bin_path()
    ytdlp = [binary] if binary else [sys.executable, "-m", "yt_dlp"]
    ffmpeg = ffmpeg_path()
    try:
        return subs.fetch_platform_subtitles(
            url, work, lang=lang, ytdlp=ytdlp, ffmpeg=ffmpeg
        )
    except subs.SubtitleError as first:
        # 只有像登录墙的失败才读浏览器 Cookie。普通“没有字幕”不重试，避免弹钥匙串、也避免等两遍。
        loginish = bool(_SUB_LOGIN_RE.search(str(first)) or LOGIN_WALL_RE.search(str(first)))
        if not loginish:
            raise FetchError(_friendly_sub_error(url, str(first)))
        browser = cookies_from_browser or "chrome"
        try:
            return subs.fetch_platform_subtitles(
                url,
                work,
                lang=lang,
                ytdlp=ytdlp,
                ffmpeg=ffmpeg,
                cookies_from_browser=browser,
            )
        except subs.SubtitleError as second:
            login = ""
            blob = str(first) + "\n" + str(second)
            if LOGIN_WALL_RE.search(blob) or _SUB_LOGIN_RE.search(blob):
                login = detect_platform(url)
            raise FetchError(_friendly_sub_error(url, str(second)), needs_login=login)


def _subs_folder_for_url(out_dir: Path, url: str, video_id: str, title: str) -> Path:
    platform = detect_platform(url) if url else "generic"
    ident = video_id
    if not ident and url:
        match = YOUTUBE_ID_RE.search(url)
        ident = match.group(1) if match else ""
    if not ident:
        import hashlib

        ident = hashlib.sha1((url or title or "item").encode("utf-8")).hexdigest()[:12]
    folder = out_dir / safe_name(f"subs_{platform}_{ident}")
    folder.mkdir(parents=True, exist_ok=True)
    _write_item_meta(folder, title, platform, ident)
    return folder


def prepare_subtitles(payload: dict[str, Any], out_dir: Path, cookies_from_browser: str) -> dict[str, Any]:
    fmt = subs.normalize_format(str(payload.get("format") or "srt"))
    lang = subs.normalize_lang(str(payload.get("lang") or "auto"))
    url = str(payload.get("url") or "").strip()
    dirname = str(payload.get("dir") or "").strip()
    incoming = payload.get("cues")
    title = str(payload.get("title") or "").strip()
    language = str(payload.get("language") or "").strip()
    source = str(payload.get("source") or "").strip()
    approximate = bool(payload.get("approximate"))
    folder: Optional[Path] = None
    if dirname:
        folder = resolve_item_dir(out_dir, dirname)

    if isinstance(incoming, list) and incoming:
        if source not in {"platform", "auto", "page", "transcript"}:
            source = "page"
        if source == "transcript":
            approximate = True
        if folder is None:
            folder = _subs_folder_for_url(out_dir, url, "", title)
        bundle = subs.save_subtitle_set(
            folder,
            incoming,
            title=title,
            language=language or lang,
            source=source,
            approximate=approximate,
            url=url,
        )
        if title:
            _write_item_meta(folder, title, detect_platform(url) if url else "generic", folder.name)
        return _subtitle_public(folder, out_dir, bundle, fmt)

    if folder is not None and not url:
        return _subtitle_public(folder, out_dir, _bundle_from_folder(folder), fmt)

    if not url:
        raise FetchError("没有链接，也没有现成的字幕。")

    work = out_dir / f".subs-work-{uuid.uuid4().hex[:8]}"
    try:
        found = _fetch_subs_retry(url, work, lang, cookies_from_browser)
    finally:
        subs.discard_tree(work)

    if folder is None:
        folder = _subs_folder_for_url(
            out_dir, url, str(found.get("video_id") or ""), str(found.get("title") or title)
        )
    else:
        _write_item_meta(
            folder,
            str(found.get("title") or title),
            detect_platform(url),
            str(found.get("video_id") or ""),
        )
    bundle = subs.save_subtitle_set(
        folder,
        found["cues"],
        title=str(found.get("title") or title),
        language=str(found.get("language") or ""),
        source=str(found.get("source") or "platform"),
        approximate=False,
        url=url,
    )
    return _subtitle_public(folder, out_dir, bundle, fmt)


INDEX_PATH = Path(__file__).resolve().parent / "static" / "index.html"


def start_server(host: str, port: int, options: dict[str, Any]) -> ThreadingHTTPServer:
    out_dir: Path = options["out_dir"]
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: Any) -> None:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

        def _cors(self) -> None:
            # 插件从 chrome-extension:// 或网页访问本机时，Chrome 会先做私网预检。
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Allow-Private-Network", "true")

        def _send(self, code: int, body: bytes, content_type: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self._cors()
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self) -> None:  # noqa: N802
            self.send_response(204)
            self._cors()
            self.end_headers()

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            path = parsed.path
            if path in ("/", "/index.html"):
                html = INDEX_PATH.read_text(encoding="utf-8").encode("utf-8")
                self._send(200, html, "text/html; charset=utf-8")
                return
            if path == "/health":
                self._send(200, b'{"ok":true}', "application/json")
                return
            if path == "/api/recent":
                body = json.dumps({"ok": True, "reports": list_recent(out_dir)}, ensure_ascii=False).encode("utf-8")
                self._send(200, body, "application/json; charset=utf-8")
                return
            if path == "/api/weixin-status":
                body = json.dumps(
                    {"ok": True, "logged_in": weixin_cookie_ready(read_weixin_cookie())},
                    ensure_ascii=False,
                ).encode("utf-8")
                self._send(200, body, "application/json; charset=utf-8")
                return
            if path == "/api/env":
                usage = shutil.disk_usage(str(out_dir.expanduser()))
                body = json.dumps(
                    {
                        "ok": True,
                        "out_dir": str(out_dir.expanduser()),
                        "disk_free": usage.free,
                        "disk_total": usage.total,
                        "transcribe_ready": transcribe_ready(),
                    },
                    ensure_ascii=False,
                ).encode("utf-8")
                self._send(200, body, "application/json; charset=utf-8")
                return
            if path == "/api/transcript":
                name = (parse_qs(parsed.query).get("dir") or [""])[0]
                try:
                    folder = resolve_item_dir(out_dir, name)
                except FetchError as exc:
                    body = json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False).encode()
                    self._send(400, body, "application/json; charset=utf-8")
                    return
                data = read_transcript(folder)
                body = json.dumps(
                    {"ok": True, "transcript": data}, ensure_ascii=False
                ).encode("utf-8")
                self._send(200, body, "application/json; charset=utf-8")
                return
            if path == "/api/subtitles":
                query = parse_qs(parsed.query)
                name = (query.get("dir") or [""])[0]
                fmt = subs.normalize_format((query.get("format") or ["srt"])[0])
                try:
                    folder = resolve_item_dir(out_dir, name)
                    public = _subtitle_public(folder, out_dir, _bundle_from_folder(folder), fmt)
                except FetchError as exc:
                    body = json.dumps(
                        {"ok": False, "error": str(exc), "can_transcribe": transcribe_ready()},
                        ensure_ascii=False,
                    ).encode("utf-8")
                    self._send(400, body, "application/json; charset=utf-8")
                    return
                body = json.dumps(public, ensure_ascii=False).encode("utf-8")
                self._send(200, body, "application/json; charset=utf-8")
                return
            if path.startswith("/media/"):
                self._send_media(path)
                return
            self._send(404, b"not found", "text/plain; charset=utf-8")

        def _send_media(self, path: str) -> None:
            rel = unquote(path[len("/media/") :])
            root = out_dir.expanduser().resolve()
            candidate = (root / rel).resolve()
            if root not in candidate.parents and candidate != root:
                self._send(403, b"forbidden", "text/plain; charset=utf-8")
                return
            if not candidate.is_file():
                self._send(404, b"not found", "text/plain; charset=utf-8")
                return
            size = candidate.stat().st_size
            ctype = file_mime(candidate)
            if ctype.startswith("text/") or ctype == "application/x-subrip":
                ctype += "; charset=utf-8"
            start, end = 0, size - 1
            status = 200
            rng = self.headers.get("Range")
            if rng and rng.startswith("bytes=") and size:
                spec = rng.replace("bytes=", "").split("-", 1)
                start = int(spec[0] or 0)
                end = int(spec[1]) if spec[1] else size - 1
                end = min(max(end, start), size - 1)
                status = 206
            length = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "private, max-age=3600")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            with candidate.open("rb") as handle:
                handle.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = handle.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)

        def _begin_ndjson(self) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self._cors()
            self.end_headers()
            self._ndjson = True

        def _emit_ndjson(self, event: dict[str, Any]) -> None:
            line = json.dumps(event, ensure_ascii=False) + "\n"
            self.wfile.write(line.encode("utf-8"))
            self.wfile.flush()

        def _fail_ndjson(self, message: str, **extra: Any) -> None:
            try:
                if not getattr(self, "_ndjson", False):
                    self._begin_ndjson()
                self._emit_ndjson({"type": "error", "error": message, **extra})
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

        def do_POST(self) -> None:  # noqa: N802
            path = urlparse(self.path).path
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            if path == "/api/weixin-login":
                try:
                    self._begin_ndjson()
                    with lock:
                        cookie = ensure_weixin_cookie(self._emit_ndjson, force=True)
                    self._emit_ndjson(
                        {
                            "type": "done",
                            "ok": True,
                            "logged_in": weixin_cookie_ready(cookie),
                        }
                    )
                except FetchError as exc:
                    self._fail_ndjson(str(exc), needs_login=getattr(exc, "needs_login", "") or "weixin")
                except Exception as exc:
                    self._fail_ndjson(str(exc), needs_login="weixin")
                return
            if path == "/api/reveal":
                try:
                    payload = json.loads(raw.decode("utf-8") or "{}")
                    name = str(payload.get("dir") or "")
                except Exception:
                    name = ""
                try:
                    target = resolve_item_dir(out_dir, name) if name else out_dir.expanduser()
                    subprocess.run(["open", str(target)], check=False,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    body = json.dumps({"ok": True}, ensure_ascii=False).encode()
                    self._send(200, body, "application/json; charset=utf-8")
                except Exception as exc:
                    body = json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False).encode()
                    self._send(400, body, "application/json; charset=utf-8")
                return
            if path == "/api/transcribe":
                try:
                    payload = json.loads(raw.decode("utf-8") or "{}")
                    name = str(payload.get("dir") or "")
                    title = str(payload.get("title") or "")
                    force = bool(payload.get("force"))
                except Exception:
                    name, title, force = "", "", False
                try:
                    self._begin_ndjson()
                    folder = resolve_item_dir(out_dir, name)
                    if force:
                        (folder / TRANSCRIPT_JSON).unlink(missing_ok=True)
                    result = run_transcription(folder, title=title, progress=self._emit_ndjson)
                    self._emit_ndjson({"type": "done", "ok": True, "transcript": result})
                except FetchError as exc:
                    self._fail_ndjson(str(exc))
                except Exception as exc:
                    self._fail_ndjson(str(exc))
                return
            if path == "/api/site-login":
                try:
                    payload = json.loads(raw.decode("utf-8") or "{}")
                    platform = str(payload.get("platform") or "")
                except Exception:
                    platform = ""
                try:
                    info = open_login_page(platform, options["cookies_from_browser"] or "chrome")
                    body = json.dumps({"ok": True, **info}, ensure_ascii=False).encode("utf-8")
                    self._send(200, body, "application/json; charset=utf-8")
                except Exception as exc:
                    body = json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False).encode("utf-8")
                    self._send(400, body, "application/json; charset=utf-8")
                return
            if path == "/api/subtitles":
                try:
                    payload = json.loads(raw.decode("utf-8") or "{}")
                except Exception:
                    body = json.dumps({"ok": False, "error": "JSON 无效"}, ensure_ascii=False).encode()
                    self._send(400, body, "application/json; charset=utf-8")
                    return
                if not isinstance(payload, dict):
                    body = json.dumps({"ok": False, "error": "JSON 无效"}, ensure_ascii=False).encode()
                    self._send(400, body, "application/json; charset=utf-8")
                    return
                try:
                    has_cues = isinstance(payload.get("cues"), list) and bool(payload.get("cues"))
                    dirname = str(payload.get("dir") or "").strip()
                    page_url = str(payload.get("url") or "").strip()
                    # 只有向平台要字幕时才占下载锁，避免和正在保存的视频抢 yt-dlp。
                    if has_cues or (dirname and not page_url):
                        public = prepare_subtitles(payload, out_dir, options["cookies_from_browser"])
                    else:
                        with lock:
                            public = prepare_subtitles(payload, out_dir, options["cookies_from_browser"])
                    body = json.dumps(public, ensure_ascii=False).encode("utf-8")
                    self._send(200, body, "application/json; charset=utf-8")
                except FetchError as exc:
                    body = json.dumps(
                        {
                            "ok": False,
                            "error": str(exc),
                            "needs_login": getattr(exc, "needs_login", "") or "",
                            "can_transcribe": transcribe_ready(),
                        },
                        ensure_ascii=False,
                    ).encode("utf-8")
                    self._send(400, body, "application/json; charset=utf-8")
                except subs.SubtitleError as exc:
                    body = json.dumps(
                        {"ok": False, "error": str(exc), "can_transcribe": transcribe_ready()},
                        ensure_ascii=False,
                    ).encode("utf-8")
                    self._send(400, body, "application/json; charset=utf-8")
                return
            if path != "/api/download":
                self._send(404, b"not found", "text/plain; charset=utf-8")
                return
            try:
                payload = json.loads(raw.decode("utf-8"))
                text = str(payload.get("text") or "")
                want_transcript = bool(payload.get("transcribe"))
                want_quality = normalize_quality(str(payload.get("quality") or "auto"))
                want_profile_limit = payload.get("profile_limit")
                try:
                    want_profile_limit = int(want_profile_limit)
                except (TypeError, ValueError):
                    want_profile_limit = PROFILE_LIMIT_DEFAULT
            except Exception:
                self._send(400, json.dumps({"ok": False, "error": "JSON 无效"}).encode(), "application/json")
                return
            try:
                self._begin_ndjson()

                def emit(event: dict[str, Any]) -> None:
                    self._emit_ndjson(event)

                with lock:
                    reports, failures = parse_and_download(
                        text,
                        out_dir=out_dir,
                        http=options["http"],
                        image_format=options["image_format"],
                        info_only=options["info_only"],
                        prefer_ytdlp=options["prefer_ytdlp"],
                        cookies_from_browser=options["cookies_from_browser"],
                        progress=emit,
                        transcribe=want_transcript,
                        quality=want_quality,
                        profile_limit=want_profile_limit,
                    )
                emit({"type": "done", "ok": True, "reports": reports, "failures": failures})
            except FetchError as exc:
                # 带上 needs_login，面板据此直接打开对应站点的登录页
                self._fail_ndjson(str(exc), needs_login=getattr(exc, "needs_login", "") or "")
            except Exception as exc:
                self._fail_ndjson(str(exc))

    httpd = ThreadingHTTPServer((host, port), Handler)
    return httpd


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="从 TikTok / 抖音 / 小红书等公开分享链接下载无水印原片",
    )
    parser.add_argument("inputs", nargs="*", help="分享文本或链接，可多个")
    parser.add_argument("-f", "--file", help="从文本文件读取链接，一行一条")
    parser.add_argument("-o", "--out", default=str(Path.home() / "Downloads" / "social-dl"), help="保存目录")
    parser.add_argument("--cookie", default="", help="可选 Cookie，小红书高清视频经常需要")
    parser.add_argument(
        "--cookies-from-browser",
        default="",
        help="让 yt-dlp 读取浏览器 Cookie，例如 chrome / safari / firefox",
    )
    parser.add_argument("--image-format", choices=("jpeg", "png"), default="jpeg")
    parser.add_argument("--info", action="store_true", help="只解析直链，不下载")
    parser.add_argument("--ytdlp", action="store_true", help="TikTok/抖音等优先走 yt-dlp")
    parser.add_argument("--transcribe", action="store_true", help="下载后本地转成逐字稿")
    parser.add_argument(
        "--quality",
        choices=QUALITY_CHOICES,
        default="auto",
        help="视频清晰度：auto / 1080 / 720 / 480 / 360，批量时对每条都生效",
    )
    parser.add_argument(
        "--profile-limit",
        type=int,
        default=PROFILE_LIMIT_DEFAULT,
        help=f"作者主页最多保存几条公开作品，默认 {PROFILE_LIMIT_DEFAULT}，最多 {PROFILE_LIMIT_MAX}",
    )
    parser.add_argument("--serve", action="store_true", help="启动本地面板")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    chunks = list(args.inputs)
    if args.file:
        chunks.append(Path(args.file).read_text(encoding="utf-8"))
    if not chunks and not sys.stdin.isatty():
        chunks.append(sys.stdin.read())

    http = Http(cookie=args.cookie)
    out_dir = Path(args.out).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    options = {
        "out_dir": out_dir,
        "http": http,
        "image_format": args.image_format,
        "info_only": args.info,
        "prefer_ytdlp": args.ytdlp,
        "cookies_from_browser": args.cookies_from_browser,
    }

    if args.serve or not chunks:
        server = start_server(args.host, args.port, options)
        url = f"http://{args.host}:{args.port}/"
        print(f"面板已启动: {url}")
        print(f"保存目录: {out_dir}")
        print("把分享口令贴进去即可，Ctrl+C 停止")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("已停止", file=sys.stderr)
            return 130
        return 0

    try:
        reports, failures = parse_and_download(
            "\n".join(chunks),
            out_dir=out_dir,
            http=http,
            image_format=args.image_format,
            info_only=args.info,
            prefer_ytdlp=args.ytdlp,
            cookies_from_browser=args.cookies_from_browser,
            transcribe=args.transcribe,
            quality=args.quality,
            profile_limit=args.profile_limit,
        )
    except FetchError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("已取消", file=sys.stderr)
        return 130

    print(f"\n完成 {len(reports)} 条。默认保存到 {out_dir}")
    if failures:
        print(f"失败 {len(failures)} 条：", file=sys.stderr)
        for item in failures:
            print(f"  - {item.get('error')}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
