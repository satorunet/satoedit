#!/usr/bin/env python3
"""英語の対応がない画面の言葉を探す (L("…") の日本語 → Mac 版 I18nEnglish か iOS 版 Strings.swift にあるか)"""
import re, glob, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def table(text):
    t, pending = {}, None
    for raw in text.split("\n"):
        if raw == "" or (pending is None and raw.startswith("#")):
            pending = None; continue
        if pending is not None:
            t[pending] = raw; pending = None
        else:
            pending = raw
    return t
mac = open(os.path.join(root, "../mac/Sources/HinokiCore/I18nEnglish.swift")).read()
mac = mac[mac.index('"""') + 3: mac.rindex('"""')]
ios = open(os.path.join(root, "SatoruEditor/Strings.swift")).read()
ios = ios[ios.index('"""') + 3: ios.rindex('"""')]
known = {**table(mac), **table(ios)}
known = {k.replace("\\n", "\n") for k in known}
missing = set()
for f in glob.glob(os.path.join(root, "SatoruEditor/*.swift")):
    src = open(f).read()
    for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', src):
        k = m.group(1).encode().decode("unicode_escape").encode("latin1").decode("utf8")
        if re.search(r'[぀-ヿ一-鿿]', k) and k not in known:
            missing.add(k)
    for m in re.finditer(r'(?:titleKey|instructionKey): "((?:[^"\\]|\\.)*)"', src):
        k = m.group(1)
        if k not in known: missing.add(k)
for k in sorted(missing): print(repr(k))
print(len(missing), "missing")
