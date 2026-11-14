"""豆仓调用 social-dl（用户自己的下载工具，dl.py / subtitles.py 原样放在旁边）的薄包装。

    python beanpod_social.py <链接> <保存目录>
    环境变量 BEANPOD_COOKIE：豆仓登录窗口里这个平台的登录状态（可以没有）

只用 social-dl 自己写的平台解析器（小红书、抖音、快手、TikTok），把作品的音视频下到保存目录：
- 不走它的 yt-dlp 后备：那条默认去读 Chrome 里的登录状态，豆仓不读浏览器的登录状态。
  解析器拿不到时，豆仓自己再调 yt-dlp，带的是豆仓登录窗口里的登录。
- 不走视频号：豆仓自己做了，用的是在豆仓登录窗口里扫码登录的腾讯元宝。
每一步用一行「BPJSON {...}」报给豆仓，最后一行 type=result 是结果。
"""

import json
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

OWN_PLATFORMS = ("xiaohongshu", "douyin", "kuaishou", "tiktok")


def say(event: dict) -> None:
    sys.stdout.write("BPJSON " + json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> int:
    if len(sys.argv) < 3:
        say({"type": "result", "ok": False, "error": "用法：beanpod_social.py <链接> <保存目录>"})
        return 2
    url, out = sys.argv[1], Path(sys.argv[2])

    import dl

    def no_ytdlp(*args, **kwargs):
        raise dl.FetchError("这一步交给豆仓自己的 yt-dlp")

    dl.ytdlp_download = no_ytdlp

    platform = dl.detect_platform(url)
    if platform not in OWN_PLATFORMS:
        say({"type": "result", "ok": False, "skip": True, "error": f"{platform} 不归 social-dl 的解析器管"})
        return 2

    out.mkdir(parents=True, exist_ok=True)
    try:
        reports, failures = dl.parse_and_download(
            url,
            out_dir=out,
            http=dl.Http(cookie=os.environ.get("BEANPOD_COOKIE", "")),
            image_format="jpeg",
            info_only=False,
            prefer_ytdlp=False,
            cookies_from_browser="",
            progress=say,
        )
    except dl.FetchError as exc:
        say({"type": "result", "ok": False, "error": str(exc), "needs_login": getattr(exc, "needs_login", "") or ""})
        return 1
    except Exception as exc:  # 解析器里任何意外都别让豆仓卡住
        say({"type": "result", "ok": False, "error": f"{type(exc).__name__}: {exc}"[:300]})
        return 1

    if not reports:
        first = failures[0] if failures else {}
        say({"type": "result", "ok": False, "error": first.get("error") or "没有拿到作品", "needs_login": first.get("needs_login") or ""})
        return 1
    r = reports[0]
    say({
        "type": "result",
        "ok": True,
        "platform": r.get("platform", ""),
        "id": r.get("id", ""),
        "title": r.get("title", ""),
        "author": r.get("author", ""),
        "engine": r.get("engine", ""),
        "files": r.get("files", []),
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
