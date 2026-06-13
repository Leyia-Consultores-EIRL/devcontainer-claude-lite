#!/usr/bin/env bash
# test_install_jq_fatal.sh — B1: install.sh must exit non-zero when jq is absent
# and .claude/settings.json already exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Fixture: minimal Python project ─────────────────────────────────────────
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

cat > "$FIX/pyproject.toml" <<'EOF'
[project]
name = "myapp"
version = "0.1.0"
EOF
cat > "$FIX/main.py" <<'EOF'
def main():
    pass
EOF

# 2. First install — creates .claude/settings.json
set +e
bash "$GUARDRAILS_ROOT/install.sh" "$FIX" python >/dev/null 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
    echo "FAIL: initial install exit code $RC (expected 0)"
    exit 1
fi
if [ ! -f "$FIX/.claude/settings.json" ]; then
    echo "FAIL: .claude/settings.json was not created by initial install"
    exit 1
fi

# 3. Build a PATH that strips directories containing jq
NO_JQ_PATH=$(echo "$PATH" | tr ':' '\n' | while IFS= read -r d; do
    [ -n "$d" ] && [ -x "$d/jq" ] && continue
    echo "$d"
done | paste -sd ':' -)

# 4. Verify jq is actually gone from the stripped path
if PATH="$NO_JQ_PATH" command -v jq >/dev/null 2>&1; then
    echo "SKIP: cannot strip jq from PATH — jq still found after filtering"
    exit 0
fi

# 5. Re-run install with jq-less PATH
RC2=0
OUTPUT=$(export PATH="$NO_JQ_PATH"; bash "$GUARDRAILS_ROOT/install.sh" "$FIX" python 2>&1) || RC2=$?

# 6. Assert non-zero exit
if [ $RC2 -eq 0 ]; then
    echo "FAIL: install.sh exited 0 (expected non-zero) when jq is missing and settings.json exists"
    echo "Output was: $OUTPUT"
    exit 1
fi

# 7. Assert error message contains 'jq'
if ! echo "$OUTPUT" | grep -q "jq"; then
    echo "FAIL: install.sh output does not mention 'jq'"
    echo "Output was: $OUTPUT"
    exit 1
fi

echo "PASS: install.sh exited $RC2 with jq error message"
