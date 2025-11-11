#!/bin/bash

# Strict pre-commit secret scanner for Contact SyncMate
# Install: cp check-secrets.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
# Override (not recommended): ALLOW_SECRET_COMMIT=1 git commit -m "..."

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

abort() {
  echo -e "${RED}❌ ERROR:${NC} $1"
  echo -e "${YELLOW}See SETUP_SECRETS.md for safe local configuration without committing secrets.${NC}"
  exit 1
}

if [[ "${ALLOW_SECRET_COMMIT:-}" == "1" ]]; then
  echo -e "${YELLOW}⚠️  Secret checks bypassed via ALLOW_SECRET_COMMIT=1${NC}"
  exit 0
fi

echo -e "${BLUE}🔍 Running secret scan on staged changes...${NC}"

# Gather staged files
STAGED=$(git diff --cached --name-only --diff-filter=ACMRT)
if [[ -z "$STAGED" ]]; then
  echo -e "${GREEN}✅ No files staged. Skipping secret scan.${NC}"
  exit 0
fi

# Block known secret-bearing files from being committed
if echo "$STAGED" | grep -qE '(^|/)GoogleOAuthConfig\.swift$'; then
  abort "GoogleOAuthConfig.swift must NOT be committed. Keep it local-only and ignored."
fi

if echo "$STAGED" | grep -qE '(^|/)GoogleOAuthConfig\.json$'; then
  abort "GoogleOAuthConfig.json must NOT be committed. Use GoogleOAuthConfig.example.json and keep the real file untracked."
fi

# Limit scan to relevant code files
FILES=$(echo "$STAGED" | grep -E '\.(swift|m|mm|h|sh|plist|json|yaml|yml)$' || true)
if [[ -z "$FILES" ]]; then
  echo -e "${GREEN}✅ No code/config files staged. Secret scan passed.${NC}"
  exit 0
fi

# Scan staged diffs only (prevents false positives from workspace)
DIFF=$(git diff --cached -U0 -- $FILES || true)

# High-confidence Google client secret pattern (starts with GOCSPX- often)
if echo "$DIFF" | grep -E "+.*GOCSPX-[A-Za-z0-9_-]{10,}" -q; then
  abort "Detected Google OAuth client secret in staged diff. Remove it before committing."
fi

# Common secret patterns
PATTERNS=(
  "+.*client_secret\s*[:=]\s*['\"][^'\"]+['\"]"
  "+.*api[_-]?key\s*[:=]\s*['\"][^'\"]+['\"]"
  "+.*access[_-]?token\s*[:=]\s*['\"][^'\"]+['\"]"
  "+.*auth[_-]?token\s*[:=]\s*['\"][^'\"]+['\"]"
  "+.*private[_-]?key\s*[:=]\s*['\"][^'\"]+['\"]"
  "+.*password\s*[:=]\s*['\"][^'\"]+['\"]"
)

for pattern in "${PATTERNS[@]}"; do
  if echo "$DIFF" | grep -E "$pattern" -q; then
    abort "Detected potential secret in staged diff matching pattern: $pattern"
  fi
done

# Google client ID pattern (informational)
if echo "$DIFF" | grep -E "+.*[0-9]{12}-[a-z0-9]{32}\.apps\.googleusercontent\.com" -q; then
  echo -e "${YELLOW}⚠️  Found a Google client ID in staged changes. Ensure it's intended and not secret.${NC}"
fi

# Warn if example file modified (allowed)
if echo "$STAGED" | grep -qE '(^|/)GoogleOAuthConfig\.example\.json$'; then
  echo -e "${BLUE}ℹ️  Modifying example config (allowed): GoogleOAuthConfig.example.json${NC}"
fi

echo -e "${GREEN}✅ Secret scan passed.${NC}"
exit 0
