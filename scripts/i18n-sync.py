#!/usr/bin/env python3
"""把编译时抽出来的界面文字同步进 App/Localizable.xcstrings，并找出还缺翻译的。

用法（先编译一次，编译设置里开了 SWIFT_EMIT_LOC_STRINGS）：
    python3 scripts/i18n-sync.py                      # 同步 key，列出缺英文翻译的数量
    python3 scripts/i18n-sync.py --missing out.json   # 把缺翻译的 key 写成 {"中文": ""} 交给翻译
    python3 scripts/i18n-sync.py --apply trans.json   # 把翻译好的 {"中文": "English"} 合进去
    python3 scripts/i18n-sync.py --lang ja ...        # 换一种目标语言（默认 en）

规则：命令行 xcodebuild 不会自动更新 String Catalog，所以由这个脚本做。
- 代码里已经删掉的 key 会标成 stale 保留（不丢翻译）；重新出现时恢复。
- 带格式符的 key（%lld、%@、%lf）翻译里必须原样保留同样个数、同样顺序的格式符，否则拒收那一条。
"""
import argparse, glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App", "Localizable.xcstrings")
BUILD = os.path.join(ROOT, "build", "Build", "Intermediates.noindex", "BeanPod.build")
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|\.\d+f|%)")


def extracted_keys():
    keys = {}
    for f in glob.glob(os.path.join(BUILD, "**", "*.stringsdata"), recursive=True):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        src = os.path.relpath(d.get("source", ""), ROOT)
        for table, entries in d.get("tables", {}).items():
            if table != "Localizable":
                continue
            for e in entries:
                keys.setdefault(e["key"], set()).add(src)
    return keys


def load():
    if os.path.exists(CATALOG):
        return json.load(open(CATALOG))
    return {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}


def save(cat):
    cat["strings"] = dict(sorted(cat["strings"].items()))
    with open(CATALOG, "w") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2)
        f.write("\n")


def translation(entry, lang):
    loc = entry.get("localizations", {}).get(lang, {})
    if "variations" in loc or "substitutions" in loc:      # 单复数等变体：有就算翻过了
        return "variations"
    return loc.get("stringUnit", {}).get("value")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", default="en")
    ap.add_argument("--missing")
    ap.add_argument("--apply")
    a = ap.parse_args()

    cat = load()
    strings = cat["strings"]
    keys = extracted_keys()
    if not keys:
        sys.exit("没找到抽取结果：先编译一次（xcodebuild … build）")

    for k in keys:
        e = strings.setdefault(k, {})
        e.pop("extractionState", None)
    for k, e in strings.items():
        if k not in keys and not e.get("shouldTranslate") is False:
            e["extractionState"] = "stale"

    if a.apply:
        trans = json.load(open(a.apply))
        ok = bad = 0
        for k, v in trans.items():
            if k not in strings or not isinstance(v, str) or not v.strip():
                continue
            if SPEC.findall(k) != SPEC.findall(v):
                print(f"格式符对不上，跳过：{k!r} → {v!r}")
                bad += 1
                continue
            strings[k].setdefault("localizations", {})[a.lang] = {"stringUnit": {"state": "translated", "value": v}}
            ok += 1
        print(f"合进 {ok} 条翻译，跳过 {bad} 条")

    live = [k for k, e in strings.items() if e.get("extractionState") != "stale"]
    missing = [k for k in live if not translation(strings[k], a.lang)]
    save(cat)
    print(f"key 共 {len(live)} 条（另有 {len(strings) - len(live)} 条已不在代码里），缺 {a.lang} 翻译 {len(missing)} 条")
    if a.missing:
        json.dump({k: "" for k in missing}, open(a.missing, "w"), ensure_ascii=False, indent=1)
        print(f"缺翻译的写到 {a.missing}")


if __name__ == "__main__":
    main()
