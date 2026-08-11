#!/bin/bash
# Materialise the gitignored OAuth loader from its committed template.
#
# GoogleOAuthConfig.swift is kept out of git by the secret-scan hook (a
# guardrail from the era when it embedded credentials; today it only loads
# them from the gitignored JSON / Keychain). The template carries the same
# credential-free code under a name the hook allows, so a clean clone
# builds after this one command — CI runs it automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
target="Contact SyncMate/GoogleOAuthConfig.swift"
if [ -f "$target" ]; then
  echo "already present: $target"
else
  cp "Scripts/GoogleOAuthConfig.swift.template" "$target"
  echo "created: $target"
fi
if [ ! -f "Contact SyncMate/GoogleOAuthConfig.json" ]; then
  cp "Contact SyncMate/GoogleOAuthConfig.example.json" "Contact SyncMate/GoogleOAuthConfig.json"
  echo "created placeholder GoogleOAuthConfig.json (run Scripts/set-oauth-client.sh with your client ID for real sign-in)"
fi
