#!/usr/bin/env bash
# test_install_agents_md.sh — A3: install.sh must provision AGENTS.md into target.
# Tests: fresh install creates AGENTS.md, idempotency, and append-to-existing case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FAIL=0

# ─── Fixture 1: fresh install — AGENTS.md should be created ──────────────────
FIX=$(mktemp -d)
FIX2=$(mktemp -d)
trap 'rm -rf "$FIX" "$FIX2"' EXIT

cat > "$FIX/pyproject.toml" <<'EOF'
[project]
name = "myapp"
version = "0.1.0"
EOF
cat > "$FIX/main.py" <<'EOF'
def main():
    pass
EOF

# 2. Run install — expect exit 0
set +e
bash "$GUARDRAILS_ROOT/install.sh" "$FIX" python >/dev/null 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
    echo "FAIL: fresh install exit code $RC (expected 0)"
    FAIL=$((FAIL + 1))
fi

# 3. Assert AGENTS.md exists
if [ ! -f "$FIX/AGENTS.md" ]; then
    echo "FAIL: AGENTS.md was not created by install.sh"
    FAIL=$((FAIL + 1))
fi

# 4. Assert AGENTS.md contains the marker
if ! grep -q "## Regla #-1" "$FIX/AGENTS.md" 2>/dev/null; then
    echo "FAIL: AGENTS.md does not contain '## Regla #-1'"
    FAIL=$((FAIL + 1))
fi

# 5. Idempotency: run install again — should still exit 0 and marker appears exactly once
set +e
bash "$GUARDRAILS_ROOT/install.sh" "$FIX" python >/dev/null 2>&1
RC2=$?
set -e
if [ $RC2 -ne 0 ]; then
    echo "FAIL: second install exit code $RC2 (expected 0)"
    FAIL=$((FAIL + 1))
fi

COUNT=$(grep -c "## Regla #-1" "$FIX/AGENTS.md" 2>/dev/null || echo 0)
if [ "$COUNT" -ne 1 ]; then
    echo "FAIL: idempotency — '## Regla #-1' appears $COUNT times in AGENTS.md (expected 1)"
    FAIL=$((FAIL + 1))
fi

# 6. Append case: pre-existing AGENTS.md with custom content
cat > "$FIX2/pyproject.toml" <<'EOF'
[project]
name = "otherapp"
version = "0.1.0"
EOF
cat > "$FIX2/main.py" <<'EOF'
def main():
    pass
EOF
echo "# My project agents" > "$FIX2/AGENTS.md"

set +e
bash "$GUARDRAILS_ROOT/install.sh" "$FIX2" python >/dev/null 2>&1
RC3=$?
set -e
if [ $RC3 -ne 0 ]; then
    echo "FAIL: append-case install exit code $RC3 (expected 0)"
    FAIL=$((FAIL + 1))
fi

if ! grep -q "# My project agents" "$FIX2/AGENTS.md" 2>/dev/null; then
    echo "FAIL: append case — original content '# My project agents' missing from AGENTS.md"
    FAIL=$((FAIL + 1))
fi

if ! grep -q "## Regla #-1" "$FIX2/AGENTS.md" 2>/dev/null; then
    echo "FAIL: append case — '## Regla #-1' not found in AGENTS.md after append"
    FAIL=$((FAIL + 1))
fi

if [ $FAIL -gt 0 ]; then
    exit 1
fi

echo "PASS: AGENTS.md provisioning — fresh create, idempotency, and append-to-existing all correct"
