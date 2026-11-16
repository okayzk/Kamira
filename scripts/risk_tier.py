#!/usr/bin/env python3
"""Names the checks a change needs beyond `make check`, from the paths it touches.
Tests cannot see windows, glass, permissions or memory, so those are checked by hand;
this prints which of them apply. Pass file paths, or none to use the uncommitted changes
(or, with a clean tree, the last commit)."""
import subprocess, sys
from app_env import load

NAME = load()["NAME"]

GATES = [
    ("Sources/", "Memory: `footprint <pid>` of the menu bar app after the change, idle and after use; "
                 "idle must stay under 50 MB (AGENTS.md, Rules)."),
    ("Sources/App/AppDelegate.swift", "Entry points: menu, Quick Panel and shortcut reach the same code; "
                                      "check each one the change touches."),
    ("Sources/Settings/", "Hand test: login item, hidden menu bar icon and reopening the app "
                                   "(internal/release-checklist.md, Settings)."),
    ("Sources/Editor/", "Screenshots: `--demo-draw` and `--demo-move` in both languages; hand test real "
                        "mouse drawing, selecting and dragging (internal/release-checklist.md, Editor)."),
    ("Sources/Preview/", "Screenshots: `--demo-preview`, `--demo-pin`, `--demo-recording` within 10 s of "
                         "launch; hand test Copy, Save, drag out."),
    ("Sources/Recording/", "Run `--demo-record 3` (and with `--gif`, `--mic`); hand test stopping from the "
                           "menu bar and from the system's control; measure the helper's memory."),
    ("Sources/ScrollCapture/", "Run a real scrolling capture on a page with a fixed header and on a "
                               "terminal (internal/release-checklist.md, Scrolling capture)."),
    ("Sources/TextRecognition/", "Time `--ocr <image>` in a fresh process on mixed Chinese and "
                                             "code; it took 15 s with the wrong settings."),
    ("Sources/Selection/", "Hand test the selector on every screen: drag, whole screen, "
                                             "window, Esc."),
    ("Sources/", "Run `scripts/accessibility_audit.sh`: every control keeps a name and an identifier."),
    ("Resources/", "Look at the changed text in the app in both languages "
                   "(`-AppleLanguages \"(zh-Hans)\"` and `\"(en)\"`)."),
    ("Bundle/", f"Run `make package`, then open dist/{NAME}.dmg and start the app from it."),
    ("app.env", f"Run `make package`, then open dist/{NAME}.dmg and start the app from it; "
                "look at About in Settings in both languages."),
    ("scripts/build.sh", "Run `make build` and `make package`."),
    ("scripts/package.sh", "Run `make package`; check `lipo -archs` and `codesign --verify`."),
    ("scripts/notarize.sh", "Cannot be tested without a Developer ID certificate: say so in the change."),
    ("scripts/release.sh", "Run `make release-dry-run`; never run the full script to test it."),
    (".github/RELEASE_NOTES.md", "Run `scripts/check_release_notes.sh`; read both languages aloud."),
]

def changed():
    def git(*args):
        return subprocess.run(["git", *args], capture_output=True, text=True).stdout.split("\n")
    files = [line[3:] for line in git("status", "--porcelain") if line]
    return files or [name for name in git("diff", "--name-only", "HEAD~1", "HEAD") if name]

files = sys.argv[1:] or changed()
needed = [gate for prefix, gate in GATES if any(name.startswith(prefix) for name in files)]
if needed:
    print("Beyond `make check`, this change needs:")
    for gate in needed:
        print(f"  - {gate}")
else:
    print("No extra checks for these paths.")
