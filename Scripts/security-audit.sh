#!/bin/bash
# Scan for credential exposure and data-safety risks.
#
# Kept as a script rather than ad-hoc commands so it can be re-run before each
# release — the risks it looks for are the kind that get reintroduced quietly.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

hdr() { printf '\n=== %s\n' "$1"; }

hdr "Config file tracked in git?"
git ls-files --error-unmatch "Contact SyncMate/GoogleOAuthConfig.json" 2>/dev/null \
    && echo "  TRACKED — real credentials would be public" \
    || echo "  not tracked (good)"

hdr ".gitignore coverage"
grep -n 'GoogleOAuthConfig' .gitignore || echo "  NOT IGNORED"

hdr "Config ever committed historically?"
COMMITS=$(git log --all --oneline -- '*GoogleOAuthConfig.json*' | head -5)
[ -n "$COMMITS" ] && echo "$COMMITS" || echo "  never committed (good)"

hdr "Live secrets anywhere in git history"
# GOCSPX- = Google client secret, AIza = Google API key, sk-ant- = Anthropic key
git grep -InE 'GOCSPX-[A-Za-z0-9_-]{20}|AIza[0-9A-Za-z_-]{35}|sk-ant-api[0-9A-Za-z_-]{20}' \
    $(git rev-list --all | head -60) -- '*.swift' '*.json' '*.plist' '*.md' 2>/dev/null \
    | head -10 || true
echo "  (empty above = clean)"

hdr "Keychain accessibility attribute"
grep -rn 'kSecAttrAccessible' "Contact SyncMate"/*.swift "Contact SyncMate/DesignSystem"/*.swift 2>/dev/null \
    || echo "  NONE SET — items default to kSecAttrAccessibleWhenUnlocked"

hdr "Insecure transport"
grep -rn 'http://' "Contact SyncMate"/*.swift 2>/dev/null | grep -v '://www.w3.org' | head -5 \
    || echo "  no http:// URLs"
grep -n 'NSAppTransportSecurity' -A6 "Contact SyncMate/Info.plist" 2>/dev/null \
    || echo "  no ATS exceptions (good)"

hdr "Process / shell execution"
grep -rn 'Process()\|NSTask\|/bin/sh\|system(' "Contact SyncMate"/*.swift "Contact SyncMate/DesignSystem"/*.swift 2>/dev/null | head -5 \
    || echo "  none"

hdr "OAuth CSRF: is a state parameter used?"
grep -n '"state"' "Contact SyncMate/GoogleOAuthManager.swift" \
    || echo "  NO state PARAMETER — authorization response is not bound to our request"

hdr "Token revocation on sign-out"
grep -n 'oauth2.googleapis.com/revoke\|/revoke' "Contact SyncMate/GoogleOAuthManager.swift" \
    || echo "  NO REVOKE CALL — sign-out only deletes the local copy"

hdr "Contact PII written to the exportable sync log"
grep -rn 'contactName\|displayName' "Contact SyncMate/SyncEngine.swift" \
    | grep -c 'SyncHistory\|details:' | sed 's/^/  call sites referencing names in log details: /'
