#!/usr/bin/env bash
# shell.sh — POSIX shell (bash/sh) ghost-function checker.
# Finds public functions (no leading _) that have no call-site outside their
# own defining file or in ENTRY_POINTS.
# POSIX-only, no ripgrep. Loud failure on missing tools.

set -u

SRC_GLOBS="${SRC_GLOBS:-}"
TEST_EXCLUDES="${TEST_EXCLUDES:-}"
GHOST_SKIP_NAMES="${GHOST_SKIP_NAMES:-}"

if [ -z "${ENTRY_POINTS:-}" ]; then
    echo "shell.sh: ENTRY_POINTS env var required (source project.conf first)" >&2
    exit 1
fi

for bin in grep find awk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "shell.sh: required tool '$bin' not found in PATH" >&2
        exit 1
    fi
done

# Default SRC_GLOBS: scripts/ if it has .sh files, else .
if [ -z "$SRC_GLOBS" ]; then
    if [ -d scripts ] && find scripts -maxdepth 2 -name '*.sh' -type f 2>/dev/null | grep -q .; then
        SCAN_ROOT="scripts"
    else
        SCAN_ROOT="."
    fi
else
    SCAN_ROOT="$SRC_GLOBS"
fi

TMP_FILES=$(mktemp)
TMP_SYMS=$(mktemp)
trap 'rm -f "$TMP_FILES" "$TMP_SYMS"' EXIT

# Collect production .sh files (exclude test patterns)
# SCAN_ROOT may be space-separated; iterate to handle multiple dirs.
for _dir in $SCAN_ROOT; do
    find "$_dir" -type f -name '*.sh' 2>/dev/null
done | grep -vE '(/tests?/|_test\.sh$|\.bats$|/spec/)' | sort -u > "$TMP_FILES"

# Apply additional TEST_EXCLUDES
if [ -n "$TEST_EXCLUDES" ]; then
    for pat in $TEST_EXCLUDES; do
        grep -v -- "$pat" "$TMP_FILES" > "${TMP_FILES}.new" 2>/dev/null || cp "$TMP_FILES" "${TMP_FILES}.new"
        mv "${TMP_FILES}.new" "$TMP_FILES"
    done
fi

[ ! -s "$TMP_FILES" ] && exit 0

# Detect functions: only at start of line (no leading whitespace)
# Patterns matched:
#   name()         → bare name with parens
#   name ()        → name with space before parens
#   function name  → keyword with no parens (followed by { or newline)
while IFS= read -r file; do
    awk -v file="$file" '
        /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\(\))?[[:space:]]*\{/ {
            # "function name {" or "function name() {"
            match($0, /function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)
            s = substr($0, RSTART, RLENGTH)
            sub(/^function[[:space:]]+/, "", s)
            if (length(s) > 0) print file ":" NR ":" s
            next
        }
        /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/ {
            # "name()" or "name ()"
            match($0, /^[A-Za-z_][A-Za-z0-9_]*/)
            s = substr($0, RSTART, RLENGTH)
            if (length(s) > 0) print file ":" NR ":" s
            next
        }
    ' "$file"
done < "$TMP_FILES" > "$TMP_SYMS"

[ ! -s "$TMP_SYMS" ] && exit 0

# Build skip-name set (builtin + user-supplied)
BUILTIN_SKIP="main usage help setup teardown cleanup error die log"
ALL_SKIP="$BUILTIN_SKIP $GHOST_SKIP_NAMES"

while IFS= read -r line; do
    [ -z "$line" ] && continue
    definer=$(echo "$line" | awk -F: '{print $1}')
    symbol=$(echo "$line"  | awk -F: '{print $NF}')

    # Skip private functions (leading underscore)
    case "$symbol" in
        _*) continue ;;
    esac

    # Skip built-in / user skip-list names
    skip=0
    for skname in $ALL_SKIP; do
        if [ "$symbol" = "$skname" ]; then skip=1; break; fi
    done
    [ "$skip" = "1" ] && continue

    found=0

    # 1. Intra-file check: appears ≥2 times in non-comment lines (definition=1, call=2+)
    cnt=$(grep -v '^[[:space:]]*#' "$definer" 2>/dev/null | grep -cw "$symbol" || true)
    if [ "${cnt:-0}" -ge 2 ]; then
        found=1
    fi

    # 2. Search every other production .sh file in the corpus
    if [ "$found" = "0" ]; then
        while IFS= read -r f; do
            [ "$f" = "$definer" ] && continue
            if grep -qw "$symbol" "$f" 2>/dev/null; then
                found=1; break
            fi
        done < "$TMP_FILES"
    fi

    # 3. Search ENTRY_POINTS files (if not already scanned or same as definer)
    if [ "$found" = "0" ]; then
        for ep in $ENTRY_POINTS; do
            [ ! -f "$ep" ] && continue
            [ "$ep" = "$definer" ] && continue
            if grep -qw "$symbol" "$ep" 2>/dev/null; then
                found=1; break
            fi
        done
    fi

    [ "$found" = "0" ] && echo "$line"
done < "$TMP_SYMS"
