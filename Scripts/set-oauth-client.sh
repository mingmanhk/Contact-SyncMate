#!/bin/bash
# Point the app at a Google OAuth client, from the client ID alone.
#
# Everything else is derivable. The redirect URI is the *reversed* client ID
# plus a path, and Info.plist must register that same scheme — two values that
# have to agree exactly, in two files, in a format that is easy to get subtly
# wrong. Getting it wrong produces `redirect_uri_mismatch`, which names neither
# file.
#
# Accepts either the bare client ID or the .plist Google Cloud Console offers
# for download on an iOS client.
#
# Usage:
#   Scripts/set-oauth-client.sh 714060347503-abc123.apps.googleusercontent.com
#   Scripts/set-oauth-client.sh ~/Downloads/GoogleService-Info.plist
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONFIG="Contact SyncMate/GoogleOAuthConfig.json"
PLIST="Contact SyncMate/Info.plist"

if [ $# -ne 1 ]; then
    echo "usage: $0 <client-id | downloaded .plist>" >&2
    exit 1
fi

INPUT="$1"

# Accept the Console's downloaded plist as well as a pasted ID.
if [ -f "$INPUT" ]; then
    CLIENT_ID=$(/usr/libexec/PlistBuddy -c "Print :CLIENT_ID" "$INPUT" 2>/dev/null || true)
    if [ -z "$CLIENT_ID" ]; then
        echo "ABORT: no CLIENT_ID key in $INPUT" >&2
        exit 1
    fi
    echo "Read client ID from $INPUT"
else
    CLIENT_ID="$INPUT"
fi

# Validate before writing anything. A typo here is the difference between a
# working sign-in and an error that points at the wrong thing.
case "$CLIENT_ID" in
    *.apps.googleusercontent.com) ;;
    *)
        echo "ABORT: '$CLIENT_ID' does not end in .apps.googleusercontent.com" >&2
        echo "       Copy the full Client ID from Google Cloud Console." >&2
        exit 1
        ;;
esac

# A real client ID is <digits>-<lowercase alphanumerics>. Checking the suffix
# alone is not enough: the first version of this script accepted the literal
# placeholder from its own usage message, wrote it into both files, and the
# only symptom was a failed sign-in later.
PREFIX_CHECK="${CLIENT_ID%.apps.googleusercontent.com}"
if ! printf '%s' "$PREFIX_CHECK" | grep -Eq '^[0-9]+-[a-z0-9]+$'; then
    echo "ABORT: '$PREFIX_CHECK' is not a client ID." >&2
    echo "       Expected <digits>-<letters/digits>, e.g. 714060347503-a1b2c3d4e5f6." >&2
    echo "       Copy the real value from Google Cloud Console → Clients." >&2
    exit 1
fi

# "714060347503-abc.apps.googleusercontent.com"
#   → "com.googleusercontent.apps.714060347503-abc"
PREFIX="${CLIENT_ID%.apps.googleusercontent.com}"
SCHEME="com.googleusercontent.apps.${PREFIX}"
REDIRECT="${SCHEME}:/oauth2redirect"

echo
echo "  client ID : $CLIENT_ID"
echo "  scheme    : $SCHEME"
echo "  redirect  : $REDIRECT"
echo

# clientSecret is deliberately empty. An OAuth client of type "iOS" — the type
# Google requires for macOS apps — is a public client and is issued no secret.
# PKCE is what protects the exchange, and the app omits the parameter entirely
# when this is blank (sending it empty earns `invalid_client`).
cat > "$CONFIG" <<JSON
{
  "clientId": "$CLIENT_ID",
  "clientSecret": "",
  "redirectURI": "$REDIRECT"
}
JSON
echo "wrote $CONFIG"

# Targeted text edit, not PlistBuddy.
#
# PlistBuddy rewrites the whole file: it drops every XML comment and reorders
# the keys alphabetically. Info.plist here carries comments explaining the
# export-compliance declaration and the Contacts usage string, and losing them
# to a one-line change is not an acceptable trade.
python3 - "$PLIST" "$SCHEME" <<'PY'
import re, sys
path, scheme = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

# The one <string> inside CFBundleURLSchemes.
pattern = re.compile(
    r"(<key>CFBundleURLSchemes</key>\s*<array>\s*<string>)([^<]*)(</string>)")
if not pattern.search(text):
    sys.exit("ABORT: could not find CFBundleURLSchemes in " + path)

updated = pattern.sub(lambda m: m.group(1) + scheme + m.group(3), text, count=1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(updated)
PY
echo "wrote $PLIST"

echo
echo "Verifying the two agree…"
FROM_JSON=$(python3 -c "import json;print(json.load(open('$CONFIG'))['redirectURI'].split(':')[0])")
FROM_PLIST=$(/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "$PLIST")
if [ "$FROM_JSON" = "$FROM_PLIST" ]; then
    echo "  ✓ $FROM_JSON"
else
    echo "  ✗ MISMATCH: json=$FROM_JSON plist=$FROM_PLIST" >&2
    exit 1
fi

echo
echo "Next: clean build (⇧⌘K then ⌘B) — Info.plist changes need a rebuild."
echo "Then Settings → Accounts → Connect."
