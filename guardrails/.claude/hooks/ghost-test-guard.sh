#!/usr/bin/env bash
# ghost-test-guard.sh — Stop hook. Blocks session end if new/modified test files
# contain ghost-test patterns: tests that verify source-code text instead of
# runtime behavior.
#
# Detected patterns:
#   A — source-grep: open()/read_text()/readFileSync() on a source file + substring assert
#   B — hardcoded absolute paths: /workspace/.worktrees/, /tmp/*-work-*, /home/rpach
#   C — bats structural: grep/cat on .sh source (non-comment lines) without invoking the script
#
# Exit codes:
#   0 — no ghost test patterns found, or no test files modified
#   2 — ghost test patterns detected — blocks Stop
#
# DO NOT modify this script to always `exit 0`. The `exit 2` is the point.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Require git; soft-fail in non-git contexts.
if ! command -v git >/dev/null 2>&1; then
    exit 0
fi

PROJECT_ROOT="$(git -C "$HOOKS_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$PROJECT_ROOT" ]; then
    exit 0
fi

cd "$PROJECT_ROOT"

# ─── Collect new/modified test files ──────────────────────────────────────────
# Staged + tracked changes vs HEAD.
TRACKED=$(git diff HEAD --name-only --diff-filter=ACM 2>/dev/null || true)
# Untracked files (new files not yet staged).
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)

ALL_CHANGED=$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED" | sort -u | grep -v '^$' || true)

if [ -z "$ALL_CHANGED" ]; then
    exit 0
fi

# Filter to test file globs (lang-aware).
TEST_FILES=$(echo "$ALL_CHANGED" | grep -E '(^|/)test_[^/]+\.py$|(^|/)[^/]+_test\.py$|(^|/)[^/]+\.test\.tsx?$|(^|/)[^/]+\.spec\.tsx?$|(^|/)[^/]+\.bats$' || true)

if [ -z "$TEST_FILES" ]; then
    exit 0
fi

# ─── Scan each test file for ghost patterns ────────────────────────────────────
FINDINGS=""

while IFS= read -r tf; do
    [ -z "$tf" ] && continue
    [ -f "$tf" ] || continue

    # Pattern A — source-grep: reads a source file and asserts substring.
    # Match non-comment lines that open/read a source-extension file for text inspection.
    while IFS= read -r match; do
        lineno=$(echo "$match" | cut -d: -f1)
        linetext=$(echo "$match" | cut -d: -f2-)
        FINDINGS="${FINDINGS}  ${tf}:${lineno} — source-grep: reads source file in test and asserts substring\n"
        FINDINGS="${FINDINGS}    Line: ${linetext}\n"
        FINDINGS="${FINDINGS}    Fix: mock the external system that fails and assert runtime signal, not source text.\n\n"
    done < <(grep -nE '^\s*[^#].*open\(["'"'"'][^"'"'"']*\.(py|ts|js|sh|go|rs|rb|java)\b|^\s*[^#].*read_text\(|^\s*[^#].*readFileSync\(["'"'"'][^"'"'"']*\.(ts|js)\b' "$tf" 2>/dev/null || true)

    # Pattern B — absolute hardcoded paths (case-insensitive for /tmp/ variants).
    while IFS= read -r match; do
        lineno=$(echo "$match" | cut -d: -f1)
        linetext=$(echo "$match" | cut -d: -f2-)
        FINDINGS="${FINDINGS}  ${tf}:${lineno} — hardcoded-path: ${linetext}\n"
        FINDINGS="${FINDINGS}    Fix: use relative paths or environment-relative fixture paths.\n\n"
    done < <(grep -nE '/workspace/\.worktrees/|/workspace/issue-|/tmp/[^[:space:]]+-work[-_]|/home/rpach' "$tf" 2>/dev/null || true)

    # Pattern C — bats structural: grep/cat on .sh (non-comment lines) without run invocation.
    if echo "$tf" | grep -qE '\.bats$'; then
        # Count non-comment lines that inspect script source.
        HAS_SOURCE_INSPECT=$(grep -cE '^\s*[^#].*(grep|cat) .*\.sh\b' "$tf" 2>/dev/null || true)
        HAS_RUN_INVOKE=$(grep -cE '^\s*[^#].*(run [^ ]*\.sh|bash [^ ]*\.sh|sh [^ ]*\.sh)' "$tf" 2>/dev/null || true)
        if [ "${HAS_SOURCE_INSPECT:-0}" -gt 0 ] && [ "${HAS_RUN_INVOKE:-0}" -eq 0 ]; then
            while IFS= read -r match; do
                lineno=$(echo "$match" | cut -d: -f1)
                linetext=$(echo "$match" | cut -d: -f2-)
                FINDINGS="${FINDINGS}  ${tf}:${lineno} — bats-structural: inspects script source with grep/cat but never invokes it\n"
                FINDINGS="${FINDINGS}    Line: ${linetext}\n"
                FINDINGS="${FINDINGS}    Fix: invoke the script with \`run bash <script>\` and assert on \$output/\$status.\n\n"
            done < <(grep -nE '^\s*[^#].*(grep|cat) .*\.sh\b' "$tf" 2>/dev/null || true)
        fi
    fi

done <<< "$TEST_FILES"

if [ -n "$FINDINGS" ]; then
    printf 'GHOST-TEST BLOCK: ghost test patterns detected in new/modified test files.\n\n' >&2
    printf '%b' "$FINDINGS" >&2
    printf 'These tests verify the source code'"'"'s text, not its behavior.\n' >&2
    printf 'See guardrails/docs/FAKE_WORK_AUDIT.md for context.\n' >&2
    exit 2
fi

exit 0
