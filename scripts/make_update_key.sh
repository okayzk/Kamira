#!/bin/bash
# Creates the key that signs every update, once, on the release machine:
#
#   scripts/make_update_key.sh <backup.dmg>
#
# Sparkle installs an update only if it is signed with this key; the app carries the
# public half (UPDATE_PUBLIC_KEY in app.env). The private half goes into the login
# keychain and into <backup.dmg>, an AES-256 encrypted disk image whose passphrase is
# asked for in a dialog. Keep it beside the certificate's backup: a lost key means users
# never receive another update.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

BACKUP="${1:-}"
case "$BACKUP" in *.dmg) ;; *) die "usage: scripts/make_update_key.sh <backup.dmg>" ;; esac
[ ! -e "$BACKUP" ] || die "$BACKUP already exists"
[ -d "$(dirname "$BACKUP")" ] || die "the folder for $BACKUP does not exist"
[ -z "$UPDATE_PUBLIC_KEY" ] || die "app.env already has UPDATE_PUBLIC_KEY. Restore the key from its backup: generate_keys -f <file>"
TOOLS="$(./scripts/sparkle.sh)/bin"

ask() { # <prompt>: a hidden dialog, so the passphrase never passes through a terminal or a file
  /usr/bin/osascript -e "text returned of (display dialog \"$1\" default answer \"\" with hidden answer with title \"$NAME update key\")"
}
PASSPHRASE="$(ask "A passphrase for the backup of the update key. Save it in the Passwords app: without it the backup cannot be opened.")"
[ "$PASSPHRASE" = "$(ask "The same passphrase again:")" ] || die "the passphrases differ"
[ "${#PASSPHRASE}" -ge 12 ] || die "use a passphrase of at least 12 characters"

umask 077
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
# Makes the key in the login keychain, or keeps the one already there.
"$TOOLS/generate_keys" >/dev/null
KEY="$("$TOOLS/generate_keys" -p)"
[ -n "$KEY" ] || die "generate_keys printed no public key"
mkdir "$SCRATCH/backup"
"$TOOLS/generate_keys" -x "$SCRATCH/backup/update-private-key"
cat > "$SCRATCH/backup/README.txt" <<END
$NAME update key (public key $KEY)
Created $(date +%Y-%m-%d). Signs every update of $NAME.

To restore it on a Mac, for example a new one:
  .tmp/sparkle-<version>/bin/generate_keys -f update-private-key
Never make a new key in its place: users would stop receiving updates.
END
printf '%s' "$PASSPHRASE" | /usr/bin/hdiutil create -quiet -encryption AES-256 -stdinpass \
  -volname "$NAME update key" -srcfolder "$SCRATCH/backup" -format UDZO "$BACKUP"

sed -i '' "s|^UPDATE_PUBLIC_KEY=\"\"|UPDATE_PUBLIC_KEY=\"$KEY\"|" app.env
grep -q "^UPDATE_PUBLIC_KEY=\"$KEY\"" app.env || die "could not write the public key to app.env: $KEY"
echo "Created the update key; app.env names its public half (commit that). Backup: $BACKUP"
