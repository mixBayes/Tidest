#!/usr/bin/env python3
"""Check new layout strings, duplicate keys and format placeholders in all app languages."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans", "zh-Hant", "ja", "ko")
PAIR = re.compile(r'^("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");\s*$', re.M)
sources = [*ROOT.glob("tidest/MultiWindowLayout*.swift"), ROOT / "tidest/LayoutTemplateStore.swift"]
required = {"窗口定位", "窗口定位快捷键", "快速布局", "快速布局快捷键", "未设置",
            "这个快捷键用于窗口定位，请选择其他快捷键。", "默认未设置，可从菜单栏打开快速布局。"}
for source in sources:
    for literal in re.findall(r'"([^"\n\\]*)"', source.read_text()):
        if re.search(r"[\u4e00-\u9fff]", literal):
            required.add(literal)
errors = []
for language in LANGUAGES:
    table = {}
    for key, value in PAIR.findall((ROOT / "tidest" / f"{language}.lproj" / "Localizable.strings").read_text()):
        key, value = json.loads(key), json.loads(value)
        if key in table:
            errors.append(f"{language}: duplicate key: {key}")
        table[key] = value
        if sorted(re.findall(r"%(?:\d+\$)?[@diuf]", key)) != sorted(re.findall(r"%(?:\d+\$)?[@diuf]", value)):
            errors.append(f"{language}: placeholder mismatch: {key}")
    for missing in sorted(required - table.keys()):
        errors.append(f"{language}: missing key: {missing}")
    print(f"{language}: {len(table)} strings, {len(required)} required layout keys checked")
if errors:
    raise SystemExit("\n".join(errors))
print("Layout localization checks passed.")
