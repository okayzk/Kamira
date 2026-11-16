#!/usr/bin/env python3
"""Checks the two text tables against the source code: every name passed to L("…") must
have an entry in both English and Simplified Chinese, the tables must name the same
texts with the same placeholders, no entry may be unused, and no Chinese text may be
left in the code itself (it would show to English readers). The tagline is not in the
tables: scripts/build.sh adds it from app.env."""
import glob, re, sys
from app_env import load

used = set()
stray = []
for path in sorted(glob.glob("Sources/**/*.swift", recursive=True)):
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        code = line.split("//")[0]
        used.update(re.findall(r'\bL\("((?:[^"\\]|\\.)*)"', code))
        # Sample text drawn for the annotation demo and for the text-recognition warm-up
        # is not user interface.
        samples = ("Hello 标注 123", "滚动长截图与文字识别")
        if re.search(r'"[^"]*[一-鿿][^"]*"', code) and not any(sample in code for sample in samples):
            stray.append(f"{path}:{number}: {line.strip()}")

def table(language):
    text = open(f"Resources/{language}.lproj/Localizable.strings", encoding="utf-8").read()
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$', text, re.M))

problems = [f"Chinese text in the code: {where}" for where in stray]
tables = {language: table(language) for language in ("en", "zh-Hans")}
identity = load()
for language, tagline in (("en", "TAGLINE_EN"), ("zh-Hans", "TAGLINE_ZH")):
    if "about.tagline" in tables[language]:
        problems.append(f"{language}: about.tagline belongs in app.env ({tagline}), not in the table")
    tables[language]["about.tagline"] = identity[tagline]
for language, entries in tables.items():
    problems += [f"{language}: no text for {key}" for key in sorted(used - entries.keys())]
    problems += [f"{language}: never used: {key}" for key in sorted(entries.keys() - used)]
for key in sorted(tables["en"].keys() & tables["zh-Hans"].keys()):
    holders = [sorted(re.findall(r"%[@d]", entries[key])) for entries in tables.values()]
    if holders[0] != holders[1]:
        problems.append(f"placeholders differ between the languages: {key}")
print("\n".join(problems) if problems else f"Text tables complete ({len(used)} texts, 2 languages).")
sys.exit(1 if problems else 0)
