#!/usr/bin/env python3
"""
Checks the app's texts in DatabaseClient/Resources/i18n/<language>.json (the kit's own `kit_*` texts live in the kit).

English is the source. Every language has the same keys and the same {variables}; every key the Swift code uses
literally is defined, and every key is used (literally or under a prefix the code builds, such as `kind.\\(...)`).

Usage: python3 tools/check-strings.py
"""
import glob, json, os, re, sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(HERE, "DatabaseClient", "Resources", "i18n")
SRC = os.path.join(HERE, "DatabaseClient", "Sources")
LANGS = ["en", "tr", "de", "es", "fr", "pt-BR", "it", "nl", "ru", "ja", "ko"]


def vars_of(s):
    if isinstance(s, dict):
        return vars_of(s.get("other", ""))
    return sorted(set(re.findall(r"\{(\w+)\}", s)))


def main():
    code = "".join(open(f, encoding="utf-8").read() for f in glob.glob(os.path.join(SRC, "**", "*.swift"), recursive=True))
    used = set(re.findall(r'L\.(?:l10n\.)?t\("([A-Za-z0-9_.\-]+)"', code))
    used = {k for k in used if not k.startswith("kit_")}
    prefixes = set(re.findall(r'"([A-Za-z0-9_.\-]*\.)\\\(', code))
    src = json.load(open(os.path.join(DIR, "en.json"), encoding="utf-8"))
    errors = []
    missing = sorted(used - set(src))
    if missing:
        errors.append(f"en: used in Swift but not defined: {missing}")
    unused = sorted(k for k in src if f'"{k}"' not in code and not any(k.startswith(p) for p in prefixes))
    if unused:
        errors.append(f"en: defined but never used: {unused}")
    for lang in LANGS:
        t = json.load(open(os.path.join(DIR, f"{lang}.json"), encoding="utf-8"))
        if set(t) != set(src):
            errors.append(f"{lang}: keys differ from en: {sorted(set(src) ^ set(t))[:12]}")
            continue
        for k, v in src.items():
            if vars_of(t[k]) != vars_of(v):
                errors.append(f"{lang}:{k}: variables differ: {t[k]!r}")
    if errors:
        sys.exit("\n".join(errors))
    print(f"{len(src)} keys, {len(LANGS)} languages")


if __name__ == "__main__":
    main()
