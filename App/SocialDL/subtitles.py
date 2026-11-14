"""字幕解析和格式转换。

平台字幕（YouTube / B 站等）保留原始时间轴。
本机语音转写只有按字数摊出来的时间，调用方要标成估算，不能当成精确字幕。
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from html import unescape
from pathlib import Path
from typing import Any, Optional

SUB_FORMATS = ("srt", "vtt", "txt")
SUBS_JSON = "subtitles.json"

_TAG_RE = re.compile(r"<[^>]+>")
_TS_RE = re.compile(
    r"(?:(\d{1,2}):)?(\d{1,2}):(\d{2})([.,](\d{1,3}))?"
)
# 不要用 zh.* / en.*。yt-dlp 会把它展开成「英语译成德语」这种上百条，很容易 429。
_LANG_PRESETS = {
    "zh": "zh-Hans,zh-CN,zh-Hant,zh",
    "en": "en-US,en-GB,en",
    "auto": "zh-Hans,zh-CN,zh-Hant,zh,en-US,en",
}


class SubtitleError(RuntimeError):
    pass


def normalize_lang(value: str) -> str:
    key = (value or "auto").strip().lower().replace("_", "-")
    if key in {"zh", "en", "auto"}:
        return key
    if key.startswith("zh"):
        return "zh"
    if key.startswith("en"):
        return "en"
    return "auto"


def normalize_format(value: str) -> str:
    key = (value or "srt").strip().lower().lstrip(".")
    return key if key in SUB_FORMATS else "srt"


def language_label(code: str) -> str:
    c = (code or "").lower()
    if c.startswith("zh"):
        return "中文"
    if c.startswith("en"):
        return "英文"
    if c in {"transcript", "asr"}:
        return "语音转写"
    return code or "未知"


def source_label(source: str, approximate: bool = False) -> str:
    if approximate or source == "transcript":
        return "语音转写 · 时间按字数估算"
    return {
        "platform": "平台字幕",
        "auto": "平台自动字幕",
        "page": "页面字幕",
    }.get(source, "字幕")


def clean_text(value: str) -> str:
    text = unescape(value or "")
    text = text.replace("\r", "")
    text = _TAG_RE.sub("", text)
    text = text.replace("\n", " ")
    return re.sub(r"[ \t]+", " ", text).strip()


def _stamp(seconds: float, comma: bool) -> str:
    ms_total = max(0, int(round(float(seconds) * 1000)))
    hours, ms_total = divmod(ms_total, 3_600_000)
    minutes, ms_total = divmod(ms_total, 60_000)
    secs, ms = divmod(ms_total, 1000)
    sep = "," if comma else "."
    return f"{hours:02d}:{minutes:02d}:{secs:02d}{sep}{ms:03d}"


def _parse_ts(token: str) -> Optional[float]:
    match = _TS_RE.search(token.strip())
    if not match:
        return None
    hours = int(match.group(1) or 0)
    minutes = int(match.group(2))
    seconds = int(match.group(3))
    frac = match.group(5) or "0"
    frac = (frac + "000")[:3]
    return hours * 3600 + minutes * 60 + seconds + int(frac) / 1000


def normalize_cues(raw: list[dict[str, Any]], limit: int = 8000) -> list[dict[str, Any]]:
    cleaned: list[dict[str, Any]] = []
    for item in raw or []:
        if not isinstance(item, dict):
            continue
        text = clean_text(str(item.get("text") or ""))
        if not text:
            continue
        try:
            start = float(item.get("start") or 0)
            end = float(item.get("end") or 0)
        except (TypeError, ValueError):
            continue
        if start < 0:
            start = 0
        if end <= start:
            end = start + 0.8
        cleaned.append({"start": round(start, 3), "end": round(end, 3), "text": text[:500]})
        if len(cleaned) >= limit:
            break
    cleaned.sort(key=lambda cue: (cue["start"], cue["end"]))
    deduped: list[dict[str, Any]] = []
    for cue in cleaned:
        if deduped and abs(deduped[-1]["start"] - cue["start"]) < 0.05:
            if len(cue["text"]) >= len(deduped[-1]["text"]):
                deduped[-1] = cue
            continue
        deduped.append(cue)
    for index in range(len(deduped) - 1):
        nxt = deduped[index + 1]["start"]
        if deduped[index]["end"] > nxt > deduped[index]["start"]:
            deduped[index]["end"] = round(nxt, 3)
    return deduped


def cues_from_segments(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return normalize_cues(
        [
            {
                "start": item.get("start") or 0,
                "end": item.get("end") or 0,
                "text": item.get("text") or "",
            }
            for item in segments or []
            if isinstance(item, dict)
        ]
    )


def cues_to_srt(cues: list[dict[str, Any]]) -> str:
    blocks = []
    for index, cue in enumerate(cues, start=1):
        blocks.append(
            f"{index}\n{_stamp(cue['start'], True)} --> {_stamp(cue['end'], True)}\n{cue['text']}\n"
        )
    return "\n".join(blocks).strip() + ("\n" if blocks else "")


def cues_to_vtt(cues: list[dict[str, Any]], note: str = "") -> str:
    lines = ["WEBVTT", ""]
    if note:
        lines.extend([f"NOTE {note}", ""])
    for cue in cues:
        lines.append(f"{_stamp(cue['start'], False)} --> {_stamp(cue['end'], False)}")
        lines.append(cue["text"])
        lines.append("")
    return "\n".join(lines).strip() + "\n"


def cues_to_txt(cues: list[dict[str, Any]]) -> str:
    return "\n".join(cue["text"] for cue in cues).strip() + ("\n" if cues else "")


def render(cues: list[dict[str, Any]], fmt: str, note: str = "") -> str:
    fmt = normalize_format(fmt)
    if fmt == "vtt":
        return cues_to_vtt(cues, note=note)
    if fmt == "txt":
        return cues_to_txt(cues)
    return cues_to_srt(cues)


def parse_vtt(text: str) -> list[dict[str, Any]]:
    cues: list[dict[str, Any]] = []
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        if "-->" not in line:
            index += 1
            continue
        start_s, _, rest = line.partition("-->")
        end_token = rest.strip().split(" ", 1)[0]
        start = _parse_ts(start_s)
        end = _parse_ts(end_token)
        index += 1
        buf: list[str] = []
        while index < len(lines) and lines[index].strip():
            buf.append(lines[index].strip())
            index += 1
        if start is None or end is None:
            continue
        cues.append({"start": start, "end": end, "text": " ".join(buf)})
    return normalize_cues(cues)


def parse_srt(text: str) -> list[dict[str, Any]]:
    return parse_vtt(text)


def parse_json3(text: str) -> list[dict[str, Any]]:
    try:
        data = json.loads(text)
    except Exception as exc:
        raise SubtitleError("字幕文件不是合法的 json3") from exc
    cues = []
    for event in data.get("events") or []:
        segs = event.get("segs") or []
        if not segs:
            continue
        raw = "".join(str(seg.get("utf8") or "") for seg in segs)
        if not raw.strip():
            continue
        start = float(event.get("tStartMs") or 0) / 1000
        dur = float(event.get("dDurationMs") or 0) / 1000
        cues.append({"start": start, "end": start + dur, "text": raw})
    return normalize_cues(cues)


_XML_TEXT_RE = re.compile(
    r"<text\b([^>]*)>(.*?)</text>",
    re.I | re.S,
)
_XML_P_RE = re.compile(
    r"<p\b([^>]*)>(.*?)</p>",
    re.I | re.S,
)
_ATTR_RE = re.compile(r"""([A-Za-z_:][\w:.-]*)\s*=\s*["']([^"']*)["']""")


def _attrs(blob: str) -> dict[str, str]:
    return {key: value for key, value in _ATTR_RE.findall(blob)}


def parse_timedtext_xml(text: str) -> list[dict[str, Any]]:
    cues = []
    pairs = _XML_TEXT_RE.findall(text) or _XML_P_RE.findall(text)
    for attrs, body in pairs:
        meta = _attrs(attrs)
        raw = clean_text(body)
        if not raw:
            continue
        if "t" in meta and "d" in meta:
            start = float(meta.get("t") or 0) / 1000
            end = start + float(meta.get("d") or 0) / 1000
        else:
            start = float(meta.get("start") or 0)
            end = start + float(meta.get("dur") or meta.get("duration") or 0)
        cues.append({"start": start, "end": end, "text": raw})
    return normalize_cues(cues)


def parse_subtitle_file(path: Path) -> list[dict[str, Any]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    suffix = path.suffix.lower()
    if suffix == ".json3" or suffix == ".json":
        return parse_json3(text)
    if suffix in {".xml", ".srv3", ".ttml"}:
        return parse_timedtext_xml(text)
    if suffix == ".srt":
        return parse_srt(text)
    return parse_vtt(text)


def _lang_of(path: Path) -> str:
    parts = path.name.split(".")
    if len(parts) >= 3:
        return parts[-2]
    return ""


def _rank(path: Path, pref: str) -> tuple:
    lang = _lang_of(path).lower().replace("_", "-")
    auto_penalty = 1 if "auto" in path.name.lower() else 0
    ext_penalty = {".vtt": 0, ".srt": 1, ".json3": 2, ".xml": 3, ".srv3": 3}.get(
        path.suffix.lower(), 4
    )
    if pref == "en":
        lang_rank = 0 if lang.startswith("en") else 2
    elif pref == "zh":
        if lang.startswith("zh-hans") or lang.startswith("zh-cn"):
            lang_rank = 0
        elif lang.startswith("zh"):
            lang_rank = 1
        else:
            lang_rank = 3
    else:
        if lang.startswith("zh-hans") or lang.startswith("zh-cn"):
            lang_rank = 0
        elif lang.startswith("zh"):
            lang_rank = 1
        elif lang.startswith("en"):
            lang_rank = 2
        else:
            lang_rank = 3
    return (lang_rank, auto_penalty, ext_penalty, path.name)


def pick_subtitle_file(folder: Path, pref: str) -> Optional[Path]:
    found = [
        path
        for path in folder.rglob("*")
        if path.is_file() and path.suffix.lower() in {".vtt", ".srt", ".json3", ".xml", ".srv3"}
        and path.name != SUBS_JSON
    ]
    if not found:
        return None
    found.sort(key=lambda path: _rank(path, pref))
    return found[0]


def file_stem(language: str, source: str) -> str:
    if source == "transcript":
        return "字幕"
    safe = re.sub(r"[^A-Za-z0-9_-]+", "", language or "") or "subs"
    return f"字幕.{safe}"


def save_subtitle_set(
    folder: Path,
    cues: list[dict[str, Any]],
    *,
    title: str = "",
    language: str = "",
    source: str = "platform",
    approximate: bool = False,
    url: str = "",
) -> dict[str, Any]:
    cues = normalize_cues(cues)
    if not cues:
        raise SubtitleError("没有字幕内容。")
    folder.mkdir(parents=True, exist_ok=True)
    note = "时间按字数估算，不是平台精确字幕。" if approximate else ""
    stem = file_stem(language, source)
    written: list[Path] = []
    texts: dict[str, str] = {}
    for fmt in SUB_FORMATS:
        body = render(cues, fmt, note=note)
        path = folder / f"{stem}.{fmt}"
        path.write_text(body, encoding="utf-8")
        written.append(path)
        texts[fmt] = body
    meta = {
        "title": title,
        "language": language,
        "source": source,
        "approximate": bool(approximate),
        "url": url,
        "cues": cues,
    }
    (folder / SUBS_JSON).write_text(
        json.dumps(meta, ensure_ascii=False),
        encoding="utf-8",
    )
    return {"cues": cues, "files": written, "texts": texts, "meta": meta}


def read_saved(folder: Path) -> Optional[dict[str, Any]]:
    path = folder / SUBS_JSON
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    data["cues"] = normalize_cues(data.get("cues") or [])
    return data


def _info_meta(folder: Path) -> tuple:
    title = ""
    video_id = ""
    for path in folder.glob("*.info.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        title = str(data.get("title") or "")
        video_id = str(data.get("id") or "")
        break
    return title, video_id


def fetch_platform_subtitles(
    url: str,
    work_dir: Path,
    *,
    lang: str,
    ytdlp: list[str],
    ffmpeg: str = "",
    cookies_from_browser: str = "",
    timeout: int = 90,
) -> dict[str, Any]:
    """用 yt-dlp 只下字幕，不下载视频。"""
    if not ytdlp:
        raise SubtitleError("没有找到字幕下载引擎。")
    pref = normalize_lang(lang)
    work_dir.mkdir(parents=True, exist_ok=True)
    cmd = list(ytdlp)
    if ffmpeg:
        cmd.extend(["--ffmpeg-location", ffmpeg, "--convert-subs", "vtt"])
    cmd.extend(
        [
            url,
            "--skip-download",
            "--no-playlist",
            "--write-subs",
            "--write-auto-subs",
            "--ignore-no-formats-error",
            "--sub-langs",
            _LANG_PRESETS[pref],
            "--sub-format",
            "vtt/srt/json3/best",
            "-o",
            str(work_dir / "%(id)s.%(ext)s"),
            "--quiet",
            "--write-info-json",
        ]
    )
    if cookies_from_browser:
        cmd.extend(["--cookies-from-browser", cookies_from_browser])

    try:
        done = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise SubtitleError("向平台要字幕超时了。") from exc

    title, video_id = _info_meta(work_dir)
    chosen = pick_subtitle_file(work_dir, pref)
    if chosen is None:
        err = (done.stderr or "").strip()
        low = err.lower()
        tail = err.splitlines()[-1][:180] if err else ""
        if any(token in low for token in ("unavailable", "private video", "sign in to", "login required")):
            raise SubtitleError(tail or "这条视频目前打不开。")
        if done.returncode != 0 and tail:
            raise SubtitleError(tail)
        raise SubtitleError("这条没有可下载的平台字幕。")
    cues = parse_subtitle_file(chosen)
    if not cues:
        raise SubtitleError("平台返回了字幕文件，但里面是空的。")
    language = _lang_of(chosen)
    automatic = "auto" in chosen.name.lower()
    return {
        "title": title,
        "video_id": video_id,
        "language": language,
        "cues": cues,
        "source": "auto" if automatic else "platform",
        "approximate": False,
    }


def discard_tree(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
