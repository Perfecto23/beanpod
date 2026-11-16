#!/usr/bin/env python3
"""生成豆仓的示例录音库，给 README 截图、演示用。不碰真实录音。

用法：
    python3 scripts/make-demo-library.py          # 写到 ~/Library/Application Support/BeanPod/Demo/Recordings
    open -a BeanPod --args -demo                  # 用示例库启动豆仓（不连蓝牙、不开 MCP、不同步飞书）

内容全是虚构的（一家叫「青禾咖啡」的小团队）。声音用 macOS 自带的 say 合成，ffmpeg 拼接、转 16 kHz 单声道。
"""
import json, os, shutil, subprocess, tempfile, time, uuid
from datetime import datetime, timedelta

OUT = os.path.expanduser("~/Library/Application Support/BeanPod/Demo/Recordings")
REF = 978307200                                 # Swift 的 Date 从 2001-01-01 00:00 UTC 起算
VOICES = ["Tingting", "Meijia", "Tingting"]   # 系统自带、不用另外下载就能合成普通话的声音
FFMPEG = next((p for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] if os.path.exists(p)), "ffmpeg")
TODAY = datetime.now().replace(second=0, microsecond=0)


def at(days_ago, hh, mm):
    d = (TODAY - timedelta(days=days_ago)).replace(hour=hh, minute=mm)
    # 一早跑的话「今天下午」还没到：往前挪到现在之前
    return min(d, TODAY - timedelta(minutes=5 + mm % 7))


def synth(lines, path):
    """lines: [(说话人下标, 文字)]。逐句合成再拼起来，返回每句开始的秒数和总时长。"""
    tmp = tempfile.mkdtemp()
    parts, starts, t = [], [], 0.0
    for i, (spk, text) in enumerate(lines):
        aiff = os.path.join(tmp, f"{i}.aiff")
        subprocess.run(["say", "-v", VOICES[spk % len(VOICES)], "-r", "210", "-o", aiff, text], check=True)
        wav = os.path.join(tmp, f"{i}.wav")
        subprocess.run([FFMPEG, "-v", "error", "-y", "-i", aiff, "-af", "apad=pad_dur=0.35", "-ar", "16000", "-ac", "1", wav], check=True)
        dur = float(subprocess.run(["/usr/bin/afinfo", wav], capture_output=True, text=True).stdout.split("estimated duration:")[1].split()[0])
        starts.append(round(t, 2)); t += dur; parts.append(wav)
    lst = os.path.join(tmp, "list.txt")
    with open(lst, "w") as f:
        f.writelines(f"file '{p}'\n" for p in parts)
    subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-ar", "16000", "-ac", "1", path], check=True)
    shutil.rmtree(tmp)
    return starts, t


def todo(text, done=False):
    return {"id": str(uuid.uuid4()).upper(), "text": text, "done": done}


def recording(rid, when, title, scene, lines, *, speakers=(), summary="", sections=(), todos=(), tags=(),
              people=(), origin=None, source=None, starred=False, marks=(), project=None, text_only=False,
              typed_into=None, audio=True, transcribed_by="Qwen3‑ASR 0.6B"):
    transcript = "\n".join(t for _, t in lines)
    rec = {
        "id": rid, "date": when.timestamp() - REF, "title": title, "titleEdited": False, "tagsEdited": False,
        "downloaded": True, "onDevice": False, "transcript": transcript, "transcribedBy": transcribed_by,
        "speakers": list(speakers), "rewrites": [], "scene": scene, "sceneLocked": False, "summary": summary or None,
        "sections": [{"heading": h, "items": list(items)} for h, items in sections], "todos": list(todos),
        "tags": list(tags), "people": list(people), "analyzedBy": "mimo-v2.6-pro" if summary else None,
        "starred": starred, "marks": list(marks), "textOnly": text_only, "videos": [], "segments": [],
    }
    for k, v in (("origin", origin), ("source", source), ("project", project), ("typedInto", typed_into)):
        if v is not None:
            rec[k] = v
    if audio and not text_only:
        starts, total = synth(lines, os.path.join(OUT, f"{rid}.wav"))
        rec["duration"] = round(total, 3)
        rec["size"] = int(total * 32000)
        rec["segments"] = [{"start": s, "text": t, "speaker": spk if speakers else None} for s, (spk, t) in zip(starts, lines)]
    else:
        rec["duration"] = 0 if text_only and not speakers else round(len(transcript) / 4.2, 1)
        rec["size"] = len(transcript.encode())
    return {k: v for k, v in rec.items() if v is not None}


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    project = {"id": str(uuid.uuid4()).upper(), "name": "冬季新品", "created": at(6, 9, 0).timestamp() - REF}
    rid = lambda d: int(d.timestamp())
    lib = []

    d = at(0, 9, 40)
    lib.append(recording(rid(d), d, "周会：冬季新品定在 12 月 5 日上线，退款率先查小程序", "meeting", [
        (0, "好，人齐了，我们开始周会。今天就两件事，冬季新品什么时候上，还有上周退款率为什么涨了。"),
        (1, "新品这边，桂花拿铁和焦糖海盐两款，包装下周三能到，我建议十二月五号上线，正好是周五。"),
        (2, "我同意五号。门店那边要提前两天培训，我来排时间。"),
        (0, "好，那就定五号。退款率呢？从百分之一点二涨到了百分之二点八。"),
        (1, "我看了一下，基本都集中在小程序下单，用户选错了门店，到店取不了，就申请退款了。"),
        (0, "那先查小程序，下单页把门店距离标出来，选了很远的门店要再确认一次。周航你来跟。"),
        (1, "没问题，周四之前给方案。"),
        (2, "另外新品的海报，我想周一先发一版给大家看看。"),
        (0, "可以。那今天就这样，散会。"),
    ], speakers=["林悦", "周航", "陈默"], people=["林悦", "周航", "陈默"], starred=True, marks=[52.0], project=project["id"],
        summary="冬季新品桂花拿铁和焦糖海盐定在 12 月 5 日（周五）上线，门店提前两天培训。上周退款率从 1.2% 涨到 2.8%，主要是小程序选错门店导致，先改下单页。",
        sections=[("结论与决定", ["冬季新品 12 月 5 日上线，包装下周三到货", "门店提前两天培训，陈默排时间", "退款率上涨主要来自小程序选错门店，先改下单页：标出门店距离，选远的门店要二次确认"]),
                  ("还没定的", ["新品海报的风格，周一看第一版再定"])],
        todos=[todo("周四前给出小程序下单页的修改方案（周航）"), todo("排好门店新品培训的时间（陈默）"), todo("周一发新品海报第一版"), todo("确认包装下周三到货", True)],
        tags=["冬季新品", "退款率", "周会"]))

    d = at(0, 14, 5)
    lib.append(recording(rid(d), d, "播客选题：慢下来的咖啡店", "memo", [
        (0, "记一下，突然想到一个播客选题，叫慢下来的咖啡店。"),
        (0, "聊聊为什么有些小店坚持手冲、不做外卖，反而活得挺好。可以找两三个老板来聊，问问他们怎么算账。"),
    ], summary="一个播客选题：「慢下来的咖啡店」，聊坚持手冲、不做外卖的小店怎么活下来，找两三位老板聊账本。",
        sections=[("想法", ["选题：慢下来的咖啡店", "核心问题：不做外卖的小店怎么算账", "嘉宾：两三位独立咖啡店老板"])],
        todos=[todo("列三位可以邀请的独立店老板")], tags=["播客", "选题"]))

    d = at(0, 13, 20)
    lib.append(recording(rid(d), d, "访谈：独立咖啡店老板谈订货的麻烦", "interview", [
        (0, "您现在订豆子一般怎么订？"),
        (1, "微信上跟三家供应商订，每周盘一次库存，全靠我自己记，忙起来经常忘。"),
        (0, "最头疼的是哪一步？"),
        (1, "是算量。周末和平时差两倍，订多了放久了不新鲜，订少了周六下午就断货。"),
        (0, "如果有个东西能帮您按过去几周的销量提醒，您愿意用吗？"),
        (1, "愿意，但别太复杂，最好就在微信里提醒我。"),
    ], speakers=["采访者", "老板"], origin="导入的音频", people=["李老板"],
        summary="独立店老板靠微信向三家供应商订豆、每周手工盘库存。最大的麻烦是算量：周末销量是平时两倍，容易囤货不新鲜或周末断货。希望有按历史销量的订货提醒，最好就在微信里。",
        sections=[("痛点", ["订货靠微信和记忆，忙时会忘", "周末和平时销量差两倍，算量难", "订多不新鲜，订少周六断货"]),
                  ("对产品的期待", ["按过去几周的销量自动提醒订多少", "要简单，最好在微信里提醒"])],
        todos=[todo("整理三位老板的访谈共性")], tags=["用户访谈", "订货"]))

    d = at(1, 15, 0)
    lib.append(recording(rid(d), d, "线上评审：小程序下单流程改版", "meeting", [
        (0, "我们看一下下单流程的新稿。第一步选门店，现在默认按距离排序，最近的放最上面。"),
        (1, "距离超过五公里的门店，下单前弹一个确认，写清楚这家店在哪。"),
        (2, "确认框别太吓人，一句话就行：这家店离你六点二公里，确定吗。"),
        (0, "好。第二步支付页，我们把取餐时间放大一点，现在太小了。"),
        (1, "可以，下周二出开发排期。"),
    ], speakers=["周航", "设计 · 小安", "开发 · 阿杰"], origin="Mac · 麦克风 + 电脑里的声音", project=project["id"],
        summary="小程序下单改版：门店按距离排序；超过 5 公里弹一句话确认；支付页放大取餐时间。下周二出开发排期。",
        sections=[("结论与决定", ["门店列表默认按距离排序", "超过 5 公里的门店下单前一句话确认", "支付页取餐时间字号放大"])],
        todos=[todo("下周二给出开发排期（阿杰）"), todo("确认框文案定稿（小安）")], tags=["小程序", "下单流程", "评审"]))

    d = at(1, 19, 40)
    lib.append(recording(rid(d), d, "电话：和供应商确认冬季豆子到货", "call", [
        (0, "喂，张经理，我想确认一下云南那批豆子，下周二能到吗？"),
        (1, "能到，周一发货，周二上午送到你们仓库。"),
        (0, "好，另外桂花的那批辅料也一起吗？"),
        (1, "辅料晚一天，周三到。"),
    ], speakers=["林悦", "张经理"], people=["张经理"],
        summary="云南咖啡豆周一发货、下周二上午到仓库；桂花辅料晚一天，周三到。",
        sections=[("确认的事", ["云南豆周二上午到仓库", "桂花辅料周三到"])],
        todos=[todo("周三收桂花辅料后通知门店")], tags=["供应商", "到货"]))

    d = at(2, 9, 30)
    lib.append(recording(rid(d), d, "分享会：门店怎么用录音做复盘", "talk", [
        (0, "今天跟大家分享一下，我们门店是怎么用录音做每周复盘的。"),
        (0, "以前开完会没人记，现在录下来，自动出纪要和待办，谁负责什么一目了然。"),
        (0, "关键是第二周开会前，先把上周的待办过一遍，没做完的说明原因。"),
    ], origin="飞书妙记", text_only=True, transcribed_by="飞书妙记",
        summary="分享门店每周复盘的做法：会议录音自动出纪要和待办，下次开会前先过上周待办。",
        sections=[("要点", ["会议录下来自动出纪要和待办", "责任人写进待办里", "下次开会先过上周待办，没做完的说原因"])],
        tags=["复盘", "分享会"]))
    lib[-1]["duration"] = 1520.0          # 飞书只给文字稿；时长按妙记里写的

    d = at(3, 11, 10)
    lib.append(recording(rid(d), d, "拜访：连锁门店试用方案", "sales", [
        (0, "我们这次带来的方案是先在你们三家店试用一个月，不收费。"),
        (1, "试用可以，但我们要看到数据，最好每周给一份报告。"),
        (0, "没问题，每周一发上周的出杯量和退款情况。"),
        (1, "那就先从南山那三家开始吧。"),
    ], speakers=["林悦", "王店长"], people=["王店长"], project=project["id"],
        summary="和连锁门店谈好先在南山三家店免费试用一个月，每周一提供出杯量和退款报告。",
        sections=[("谈成的", ["南山三家店免费试用一个月", "每周一发上周出杯量和退款报告"])],
        todos=[todo("准备试用合同"), todo("每周一发数据报告")], tags=["试用", "连锁门店"]))

    d = at(3, 20, 15)
    note = "下季度三件事：\n一、冬季新品上线后，看两周的复购。\n二、小程序改版上线，退款率压回百分之一点五以下。\n三、把门店复盘做成固定流程。"
    rec = recording(rid(d), d, "下季度三件事", "memo", [(0, note)], origin="文字笔记", text_only=True, transcribed_by="外部文字",
                    summary="下季度重点：看冬季新品两周复购、小程序改版把退款率压到 1.5% 以下、门店复盘流程化。",
                    sections=[("三件事", ["冬季新品看两周复购", "退款率压回 1.5% 以下", "门店复盘做成固定流程"])], tags=["计划"])
    rec["duration"] = 0
    lib.append(rec)

    # 素材：从链接导入的视频
    d = at(4, 21, 0)
    lib.append(recording(rid(d), d, "手冲咖啡的萃取原理，三分钟讲清楚", "media", [
        (0, "手冲咖啡好不好喝，关键是萃取。水温、研磨度、时间，三个变量一起决定味道。"),
        (0, "水温高、磨得细、时间长，萃取就多，容易苦；反过来就容易酸。"),
    ], origin="B 站 · @咖啡研究所", source="https://www.bilibili.com/video/BV1demo00000",
        summary="手冲的味道由水温、研磨度、时间三者决定：萃取过多偏苦，过少偏酸。",
        sections=[("要点", ["三个变量：水温、研磨度、时间", "萃取多偏苦，萃取少偏酸"])], tags=["手冲", "萃取"]))

    # 语音输入：像输入法的历史，不进录音列表
    for days, hh, mm, text, app in [
        (0, 9, 12, "帮我把明天十点的会挪到下午两点，顺便跟大家说一声。", "微信"),
        (0, 11, 48, "这周周报先写三点：新品排期、退款率排查、门店试用。", "备忘录"),
        (1, 17, 30, "收到，我晚上把报价单发给你。", "飞书"),
    ]:
        d = at(days, hh, mm)
        r = recording(rid(d), d, text[:40], None, [(0, text)], origin="语音输入", typed_into=app, transcribed_by="Qwen3‑ASR 0.6B")
        r.pop("scene", None)
        lib.append(r)

    lib.sort(key=lambda r: r["date"], reverse=True)
    with open(os.path.join(OUT, "library.json"), "w") as f:
        json.dump(lib, f, ensure_ascii=False)
    with open(os.path.join(OUT, "projects.json"), "w") as f:
        json.dump([project], f, ensure_ascii=False)

    # 最近删除里放两条
    trash, tdir = [], os.path.join(OUT, "Trash")
    for days, hh, mm, title, deleted_days_ago in [(2, 13, 33, "试音", 1), (5, 10, 2, "周会（重复录的一段）", 4)]:
        d = at(days, hh, mm)
        r = recording(rid(d), d, title, "other", [(0, "试一下录音效果，一二三。")])
        sub = f"{r['id']}-{int(time.time())}-demo"
        os.makedirs(os.path.join(tdir, sub))
        shutil.move(os.path.join(OUT, f"{r['id']}.wav"), os.path.join(tdir, sub, f"{r['id']}.wav"))
        trash.append({"id": str(uuid.uuid4()).upper(), "recording": r, "deletedAt": (TODAY - timedelta(days=deleted_days_ago)).timestamp() - REF,
                      "folder": sub, "files": [f"{r['id']}.wav"]})
    with open(os.path.join(OUT, "trash.json"), "w") as f:
        json.dump(trash, f, ensure_ascii=False)
    print(f"示例录音库：{OUT}（{len(lib)} 条，最近删除 {len(trash)} 条）")


if __name__ == "__main__":
    main()
