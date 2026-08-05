#!/bin/bash
#
# One command: build → test → sync translations → install → relaunch.
#
#   bash "Scripts/verify-contact-syncmate.sh"
#
# Runs from anywhere; resolves the project relative to this script.
#
# Exits non-zero on the first real failure so it is safe to chain in CI or a
# git hook. Each phase prints a single PASS/FAIL line — full logs land in
# build/verify-logs/ for anything that needs digging into.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$PROJECT_DIR/Contact SyncMate.xcodeproj"
SCHEME="Contact SyncMate"
LOG_DIR="$PROJECT_DIR/build/verify-logs"
CATALOG="$PROJECT_DIR/Contact SyncMate/Localizable.xcstrings"

mkdir -p "$LOG_DIR"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }

FAILED=0

bold "Contact SyncMate — verify"
echo

# ── 1. Debug build ──────────────────────────────────────────────────────
#
# Not redundant with the Release build above. Actor-isolation diagnostics
# differ between the two configurations, and Debug is what Xcode runs — so a
# Release-only check reported "all clear" on code that failed to compile the
# moment the project was opened. That happened with `String.nonBlank` being
# main-actor isolated under default MainActor isolation.
#
# `clean build`, not `build`. Incremental builds only recompile the files that
# changed, and a cross-file actor-isolation error — calling a main-actor member
# from a nonisolated context in another file — surfaces when the *caller* is
# recompiled. So an incremental run could pass on code that failed the moment
# Xcode did ⇧⌘K + ⌘B. That happened three times in a row, each time reported by
# the user rather than by this script, which is the opposite of the point.
bold "1. Build (Debug, clean)"
if xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
     -configuration Debug clean build > "$LOG_DIR/build-debug.log" 2>&1; then
    pass "BUILD SUCCEEDED"
else
    fail "debug build failed"
    grep -E ' error: ' "$LOG_DIR/build-debug.log" | sed 's|.*/Contact SyncMate/||' \
        | sort -u | head -15 | sed 's/^/    /'
    info "full log: $LOG_DIR/build-debug.log"
    exit 1
fi
echo

# ── 1b. Release build ───────────────────────────────────────────────────
bold "1b. Build (Release)"
if xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
     -configuration Release build > "$LOG_DIR/build.log" 2>&1; then
    pass "BUILD SUCCEEDED"
else
    fail "build failed"
    grep -E ' error: ' "$LOG_DIR/build.log" | sed 's|.*/Contact SyncMate/||' \
        | sort -u | head -15 | sed 's/^/    /'
    info "full log: $LOG_DIR/build.log"
    exit 1
fi

# Surface warnings from our own sources without failing the run.
OUR_WARNINGS=$(grep -E ' warning: ' "$LOG_DIR/build.log" \
    | grep -F "/Contact SyncMate/Contact SyncMate/" \
    | sed 's|.*/Contact SyncMate/||' | sort -u | wc -l | tr -d ' ')
[ "$OUR_WARNINGS" != "0" ] && info "$OUR_WARNINGS warning(s) in app sources — see build.log"
echo

# ── 2. Tests ────────────────────────────────────────────────────────────
#
# The test host is the app itself, and the app is a menu bar accessory that
# does not quit when the last test finishes. xcodebuild then waits on it
# forever: the log reads "Executed 120 tests, with 0 failures" and the command
# never returns. Reaping the host afterwards is what makes this script exit.
#
# Matched on the Debug product path, never on the process name. `pkill -x
# "Contact SyncMate"` would also kill the copy the user is running from Xcode,
# which has happened before.
reap_test_host() {
    # Literal path fragment, no regex. `.*` between the DerivedData folder and
    # the product path did not reliably match under pkill.
    for pid in $(pgrep -f "Build/Products/Debug/Contact SyncMate" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null || true
    done
}
trap reap_test_host EXIT

bold "2. Tests"

# xcodebuild's exit status is not usable here.
#
# The test host is the app, and the app is a menu bar accessory that does not
# quit when the last test finishes — so xcodebuild sits waiting on it forever,
# long after the log says "Executed 120 tests, with 0 failures". Reaping the
# host from a watcher did not settle it either: a fresh host reappears.
#
# So the log is the source of truth, and the wait is bounded. This reports what
# the tests actually did instead of what xcodebuild's teardown is doing.
rm -f "$LOG_DIR/test.log"; : > "$LOG_DIR/test.log"

xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
     test > "$LOG_DIR/test.log" 2>&1 &
XCB=$!

TEST_TIMEOUT=300
for _ in $(seq 1 "$TEST_TIMEOUT"); do
    # Only two reasons to stop early: the run reported a result, or xcodebuild
    # died. An "error:" grep was also here and broke the loop immediately —
    # `xcodebuild test` compiles first, and ordinary compiler noise in that
    # phase matched, killing the run before a single test executed.
    # "Test Suite 'All tests'", not the first "Executed N tests" — that one is
    # a per-suite line, so breaking on it reported whichever suite happened to
    # finish first (4 tests) as the whole run.
    grep -q "Test Suite 'All tests' \(passed\|failed\)" "$LOG_DIR/test.log" 2>/dev/null && break
    kill -0 "$XCB" 2>/dev/null || break
    sleep 1
done

kill -9 "$XCB" 2>/dev/null || true
wait "$XCB" 2>/dev/null || true
reap_test_host

RESULT=$(grep -E 'Executed [0-9]+ test' "$LOG_DIR/test.log" | tail -1 | sed 's/^[[:space:]]*//')
if [ -n "$RESULT" ] && ! grep -q 'with [1-9][0-9]* failure' "$LOG_DIR/test.log"; then
    pass "$RESULT"
elif [ -n "$RESULT" ]; then
    fail "$RESULT"
    grep -E ' error: | failed \(' "$LOG_DIR/test.log" | head -15 | sed 's/^/    /'
    info "full log: $LOG_DIR/test.log"
    FAILED=1
else
    fail "tests did not report a result within ${TEST_TIMEOUT}s"
    grep -E 'error:' "$LOG_DIR/test.log" | sed 's|.*/Contact SyncMate/||' \
        | sort -u | head -15 | sed 's/^/    /'
    info "full log: $LOG_DIR/test.log"
    FAILED=1
fi
echo

# ── 3. Localization coverage ────────────────────────────────────────────
# Catches the specific regression that keeps recurring: a new UI string ships
# untranslated because nobody re-ran the injector. Reports, never blocks —
# an untranslated string falls back to English, which is degraded but valid.
bold "3. Localization"
if [ -f "$CATALOG" ]; then
    DD=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
         -configuration Release -showBuildSettings 2>/dev/null \
         | awk -F' = ' '/ BUILD_DIR =/{print $2; exit}')
    if [ -n "${DD:-}" ]; then
        find "$(dirname "$DD")" -name '*.stringsdata' > "$LOG_DIR/stringsdata.txt" 2>/dev/null
        python3 - "$CATALOG" "$LOG_DIR/stringsdata.txt" <<'PY' || FAILED=1
import json, subprocess, sys
catalog, listing = sys.argv[1], sys.argv[2]
try:
    files = [l.strip() for l in open(listing) if l.strip()]
except FileNotFoundError:
    files = []
if files:
    args = ["xcrun", "xcstringstool", "sync", catalog]
    for f in files:
        args += ["--stringsdata", f]
    subprocess.run(args, capture_output=True)
    # Immediately after the sync, not before it. `sync` re-adds strings from
    # stale `.stringsdata` sidecars — DerivedData keeps one per source file and
    # an incremental build only refreshes the ones it recompiled — so pruning
    # first is undone by the very next line. This step reported the same two
    # renamed strings as missing translations three runs running because of it.
    subprocess.run(["python3", "Scripts/prune-stale-keys.py"], capture_output=True)
data = json.load(open(catalog))["strings"]
total = len([k for k in data if k.strip()])
gaps = False
for language in ("zh-Hant", "zh-Hans"):
    missing = sorted(
        k for k, v in data.items()
        if k.strip() and k.strip() != "%lld"
        and language not in v.get("localizations", {})
    )
    if missing:
        gaps = True
        print(f"  \033[33m!\033[0m {len(missing)} of {total} strings lack {language}")
        for k in missing[:8]:
            print(f"    - {k!r}")
    else:
        print(f"  \033[32m✓\033[0m all {total} strings have {language}")
if gaps:
    print("    fix: python3 Scripts/inject-zh-hant.py")
PY
    else
        info "could not resolve BUILD_DIR — skipped"
    fi
else
    fail "$CATALOG not found"
    FAILED=1
fi
echo

# ── 4. Install & relaunch ───────────────────────────────────────────────
# Deliberately scoped to the Release bundle path: a bare
# `pkill -x 'Contact SyncMate'` also kills the copy running under Xcode's
# debugger, which surfaces as a confusing SIGTERM in the debug console.
bold "4. Install"
APP_PATH=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')
APP="$APP_PATH/$SCHEME.app"

if [ -d "$APP" ]; then
    pkill -f "$APP" 2>/dev/null && info "stopped running instance"
    sleep 2
    open "$APP"
    sleep 4
    if pgrep -f "$APP" > /dev/null; then
        pass "running: $APP"
    else
        fail "app did not stay running"
        FAILED=1
    fi
else
    fail "built app not found at $APP"
    FAILED=1
fi
echo

# ── Summary ─────────────────────────────────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
    bold "All checks passed."
else
    bold "Completed with failures — see $LOG_DIR"
fi
exit "$FAILED"
