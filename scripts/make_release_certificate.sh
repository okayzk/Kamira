#!/bin/bash
# Creates the self-signed code-signing certificate that releases are signed with while
# there is no Developer ID, once, on the release machine:
#
#   scripts/make_release_certificate.sh <backup.dmg>
#
# macOS remembers the screen-recording permission by the app's designated requirement.
# Signed ad hoc, that is the hash of one build, so every update is a new app to the
# system; signed with this certificate it is "this bundle identifier and this
# certificate", the same for every build, so users allow it once. Their Macs need not
# trust the certificate. Gatekeeper still asks on the first launch: only notarization
# removes that.
#
# One certificate serves all of the maintainer's apps, as a Developer ID would: each
# app's requirement also names its own bundle identifier, so their permissions stay
# apart. Another app signs with it by putting its SHA-1 in that app's configuration;
# this script refuses to make a second one.
#
# The private key goes into the login keychain and into <backup.dmg>, an AES-256
# encrypted disk image holding the key as a .p12 and a note on restoring it. The disk
# image and the .p12 share one passphrase, asked for in a dialog and never written
# down. Keep the disk image in iCloud Drive and the passphrase in the Passwords app: a
# lost key means a new certificate, and every user allows screen recording once more.
# The certificate's SHA-1 is written to app.env, where the release preflight checks it.
#
# Environment, for trying the script without touching the login keychain:
#   SIGNING_KEYCHAIN    keychain to import into (default: the login keychain)
#   BACKUP_PASSPHRASE   the passphrase instead of the dialog
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

BACKUP="${1:-}"
case "$BACKUP" in *.dmg) ;; *) die "usage: scripts/make_release_certificate.sh <backup.dmg>" ;; esac
[ ! -e "$BACKUP" ] || die "$BACKUP already exists"
[ -d "$(dirname "$BACKUP")" ] || die "the folder for $BACKUP does not exist"
[ -z "$RELEASE_CERTIFICATE_SHA1" ] \
  || die "app.env already names a release certificate ($RELEASE_CERTIFICATE_SHA1). Restore it from its backup: open the disk image, then security import <the .p12> -T /usr/bin/codesign"
KEYCHAIN="${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
if /usr/bin/security find-certificate -c "$RELEASE_CERTIFICATE" "$KEYCHAIN" >/dev/null 2>&1; then
  die "a certificate named '$RELEASE_CERTIFICATE' is already in $KEYCHAIN; put its SHA-1 in app.env instead of making another"
fi

PASSPHRASE="${BACKUP_PASSPHRASE:-}"
ask() { # <prompt>: a hidden dialog, so the passphrase never passes through a terminal or a file
  /usr/bin/osascript -e "text returned of (display dialog \"$1\" default answer \"\" with hidden answer with title \"$RELEASE_CERTIFICATE\")"
}
if [ -z "$PASSPHRASE" ]; then
  PASSPHRASE="$(ask "A passphrase for the backup of the signing key. Save it in the Passwords app: without it the backup cannot be opened.")"
  [ "$PASSPHRASE" = "$(ask "The same passphrase again:")" ] || die "the passphrases differ"
fi
[ "${#PASSPHRASE}" -ge 12 ] || die "use a passphrase of at least 12 characters"

umask 077
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cat > "$SCRATCH/certificate.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $RELEASE_CERTIFICATE
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
# Twenty years: the requirement names this exact certificate, so it must outlive the apps.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$SCRATCH/certificate.cnf" \
  -keyout "$SCRATCH/key.pem" -out "$SCRATCH/certificate.pem" 2>/dev/null
SHA1="$(/usr/bin/openssl x509 -in "$SCRATCH/certificate.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
export PASSPHRASE
mkdir "$SCRATCH/backup"
P12="$SCRATCH/backup/$RELEASE_CERTIFICATE.p12"
/usr/bin/openssl pkcs12 -export -inkey "$SCRATCH/key.pem" -in "$SCRATCH/certificate.pem" \
  -name "$RELEASE_CERTIFICATE" -out "$P12" -passout env:PASSPHRASE
cat > "$SCRATCH/backup/README.txt" <<EOF
$RELEASE_CERTIFICATE (SHA-1 $SHA1)
Created $(date +%Y-%m-%d). Signs the releases of every app that names this SHA-1.

To restore it on a Mac, for example a new one:
  security import "$RELEASE_CERTIFICATE.p12" -T /usr/bin/codesign
The .p12 has the same passphrase as this disk image.

Never make a new certificate in its place: every user of every app would have to
allow screen recording again.
EOF
/usr/bin/security import "$P12" -k "$KEYCHAIN" -P "$PASSPHRASE" -T /usr/bin/codesign >/dev/null
printf '%s' "$PASSPHRASE" | /usr/bin/hdiutil create -quiet -encryption AES-256 -stdinpass \
  -volname "$RELEASE_CERTIFICATE" -srcfolder "$SCRATCH/backup" -format UDZO "$BACKUP"

sed -i '' "s/^RELEASE_CERTIFICATE_SHA1=\"\"/RELEASE_CERTIFICATE_SHA1=\"$SHA1\"/" app.env
grep -q "^RELEASE_CERTIFICATE_SHA1=\"$SHA1\"" app.env || die "could not write the SHA-1 to app.env: $SHA1"

cat <<EOF
Created '$RELEASE_CERTIFICATE' ($SHA1) in $KEYCHAIN.
  - app.env now names it; commit that change.
  - The backup is $BACKUP, encrypted with the passphrase. Keep the passphrase in the
    Passwords app; without it the backup cannot be opened.
  - The first signing asks for the login keychain password: choose Always Allow.
EOF
