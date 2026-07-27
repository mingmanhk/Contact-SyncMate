#!/bin/bash
# Remove the leaked Google API key from every commit in this repository.
#
# The key lived in Contact SyncMate/GoogleAPIConfig.swift from 2025-11-11 until
# it was deleted on 2026-07-26. Deleting the file only removed it from HEAD —
# every historical commit still carried it, and the repository is public.
#
# This replaces the literal with a placeholder across all history rather than
# dropping the file, so the commits that legitimately touched it stay coherent.
#
# IMPORTANT: rewriting history changes every commit hash after the first
# affected one. A force-push is required, and anyone else with a clone must
# re-clone. A bundle backup is taken first.
#
# Rewriting history does NOT retract a key that has already been scraped. The
# key must be deleted in Google Cloud Console — that is the only real remedy;
# this is cleanup.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

LEAKED_KEY="REDACTED_ROTATED_KEY"
BACKUP="/tmp/csm-backup-before-rewrite-$(date +%Y%m%d-%H%M%S).bundle"

echo "1. Backing up to $BACKUP"
git bundle create "$BACKUP" --all >/dev/null 2>&1
echo "   $(du -h "$BACKUP" | cut -f1)"

echo "2. Confirming working tree is clean"
if [ -n "$(git status --porcelain)" ]; then
    echo "   ABORT: commit or stash your changes first"
    exit 1
fi

echo "3. Rewriting history"
# filter-repo refuses to run on a repo with a remote unless --force, because the
# rewrite invalidates it. That is exactly what we intend here.
REPLACEMENTS=$(mktemp)
printf '%s==>REDACTED_ROTATED_KEY\n' "$LEAKED_KEY" > "$REPLACEMENTS"
git filter-repo --replace-text "$REPLACEMENTS" --force
rm -f "$REPLACEMENTS"

echo "4. Verifying the key is gone from all history"
if git grep -q "$LEAKED_KEY" $(git rev-list --all) 2>/dev/null; then
    echo "   STILL PRESENT — do not force-push; restore from $BACKUP"
    exit 1
fi
echo "   clean"

echo
echo "filter-repo removes 'origin' as a safety measure. To publish:"
echo "  git remote add origin https://github.com/mingmanhk/Contact-SyncMate.git"
echo "  git push --force origin main"
echo
echo "Backup: $BACKUP"
