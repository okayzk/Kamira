"""Reads app.env, the one file that names the app, for the Python checks."""
import pathlib, re

KEYS = ("NAME", "BUNDLE_ID", "REPOSITORY", "VERSION", "BUILD", "TAGLINE_EN", "TAGLINE_ZH",
        "NOTARY_KEYCHAIN_PROFILE", "RELEASE_CERTIFICATE", "RELEASE_CERTIFICATE_SHA1",
        "UPDATE_PUBLIC_KEY")
ROOT = pathlib.Path(__file__).resolve().parent.parent


def load():
    values = {}
    for line in (ROOT / "app.env").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r'([A-Z][A-Z0-9_]*)="([^"\\$`]*)"', line.strip())
        if match:
            values[match[1]] = match[2]
        elif line.strip() and not line.lstrip().startswith("#"):
            raise SystemExit(f'app.env: not a KEY="value" line: {line}')
    missing = [key for key in KEYS if key not in values]
    if missing:
        raise SystemExit(f"app.env: missing {', '.join(missing)}")
    return values
