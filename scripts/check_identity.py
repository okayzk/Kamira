#!/usr/bin/env python3
"""Holds the repository to app.env, the one file that names the app.

What ships reads app.env when it is built, so a name written anywhere else is a second
source that a rename would miss. The code and the text tables must not spell the name
(they take it from the bundle), the Info.plist template must not hold what the build
adds, and Markdown, which cannot read a file, must match: the README titles and
taglines, the release notes header, links to the repository, the bundle identifier,
and the names of the built files and the recording log."""
import re, subprocess, sys
from app_env import ROOT, load

env = load()
NAME, REPOSITORY = env["NAME"], env["REPOSITORY"]
OWNER, REPO = REPOSITORY.split("/")
ID_PREFIX, ID_LAST = env["BUNDLE_ID"].rsplit(".", 1)
problems = []

def text(path):
    return (ROOT / path).read_text(encoding="utf-8")

def require(path, snippet, what):
    if snippet not in text(path):
        problems.append(f"{path}: {what} should read: {snippet}")

if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", NAME):
    problems.append(f"app.env: NAME is also a file name, letters and digits only: {NAME}")
if not re.fullmatch(r"[a-z0-9-]+(\.[A-Za-z0-9-]+)+", env["BUNDLE_ID"]):
    problems.append(f"app.env: BUNDLE_ID is not reverse-DNS: {env['BUNDLE_ID']}")
if not re.fullmatch(r"\d+\.\d+\.\d+", env["VERSION"]):
    problems.append(f"app.env: VERSION is not three numbers: {env['VERSION']}")
if not env["BUILD"].isdigit():
    problems.append(f"app.env: BUILD is not a whole number: {env['BUILD']}")

# Written by scripts/build.sh; a copy in the template would be a second source.
plist = text("Bundle/Info.plist")
for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable", "CFBundleIdentifier",
            "CFBundleShortVersionString", "CFBundleVersion", "AppRepositoryURL"):
    if f"<key>{key}</key>" in plist:
        problems.append(f"Bundle/Info.plist: {key} comes from app.env; remove it from the template")

files = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT, capture_output=True, text=True,
                       check=True).stdout.split()
# The private documents, when this clone has them (internal/ is its own repository).
if (ROOT / "internal" / ".git").exists():
    files += ["internal/" + f for f in subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT / "internal",
        capture_output=True, text=True, check=True).stdout.split()]
for path in files:
    if path.startswith("Sources/") and path.endswith(".swift") or path.endswith(".strings"):
        for number, line in enumerate(text(path).splitlines(), 1):
            code = line.split("//")[0] if path.endswith(".swift") else line
            if re.search(rf'"[^"]*\b{NAME}\b[^"]*"', code):
                problems.append(f"{path}:{number}: the name is spelled out; use AppInfo.name (or %@ in a table)")

require("README.md", f"<h1>{NAME}</h1>", "the title")
require("README.md", f"<p>{env['TAGLINE_EN']}</p>", "the tagline (TAGLINE_EN)")
require("README_CN.md", f"<h1>{NAME}</h1>", "the title")
require("README_CN.md", f"<p>{env['TAGLINE_ZH']}</p>", "the tagline (TAGLINE_ZH)")
notes = ".github/RELEASE_NOTES.md"
require(notes, f">{NAME} V{env['VERSION']}</h1>", "the header")
require(notes, f"<p><em>{env['TAGLINE_EN']}</em></p>", "the tagline (TAGLINE_EN)")
require(notes, f"> https://github.com/{REPOSITORY}", "the repository link")

# Prose may name the app freely; these are the places a rename must not leave behind.
for path in files:
    if not path.endswith((".md", ".yml", ".sh", ".py", ".swift", ".env")) or path == "docs/incidents.md":
        continue
    for number, line in enumerate(text(path).splitlines(), 1):
        for repo in re.findall(rf"\b{re.escape(OWNER)}/([A-Za-z0-9_.-]+)", line):
            # The private repository is the public one's name with -private.
            if repo.removesuffix(".git") not in (REPO, REPO + "-private"):
                problems.append(f"{path}:{number}: links to {OWNER}/{repo}, not {REPOSITORY}")
        for built in re.findall(r"\b(?:build|dist)/([A-Za-z0-9]+)\.(?:app|dmg|zip)\b", line):
            if built != NAME:
                problems.append(f"{path}:{number}: names {built}.app/.dmg/.zip, not {NAME}")
        for last in re.findall(rf"\b{re.escape(ID_PREFIX)}\.([A-Za-z0-9-]+)", line):
            if last != ID_LAST:
                problems.append(f"{path}:{number}: names {ID_PREFIX}.{last}, not {env['BUNDLE_ID']}")
        for log in re.findall(r"\b([A-Za-z0-9]+)-recording\.log\b", line):
            if log != NAME:
                problems.append(f"{path}:{number}: names {log}-recording.log, not {NAME}-recording.log")

print("\n".join(problems) if problems
      else f"The app is named {NAME} ({env['BUNDLE_ID']}, {REPOSITORY}) in app.env alone.")
sys.exit(1 if problems else 0)
