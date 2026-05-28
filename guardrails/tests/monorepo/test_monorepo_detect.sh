#!/usr/bin/env bash
# test_monorepo_detect.sh — auto-detect (monorepo) install must classify a
# repo whose manifests live ONLY in subdirectories (no root manifest) as the
# UNION of its langs, instead of falling into the old lang=unknown skip.
# Also asserts explicit-lang install keeps the legacy single-lang format.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Fixture 1: py+node monorepo, NO root manifest ────────────────────
FIX=$(mktemp -d)
FIX2=$(mktemp -d)
trap 'rm -rf "$FIX" "$FIX2"' EXIT

mkdir -p "$FIX/backend" "$FIX/frontend"
cat > "$FIX/backend/pyproject.toml" <<'EOF'
[project]
name = "backend"
version = "0.1.0"
EOF
cat > "$FIX/backend/main.py" <<'EOF'
def main():
    pass
EOF
cat > "$FIX/frontend/package.json" <<'EOF'
{"name":"frontend","main":"index.js"}
EOF
cat > "$FIX/frontend/index.js" <<'EOF'
console.log("hi")
EOF

# Run auto-detect (no lang arg).
set +e
bash "$GUARDRAILS_ROOT/install.sh" "$FIX" >/dev/null 2>&1
RC=$?
set -e
if [ $RC -ne 0 ]; then
    echo "FAIL: auto-detect install exit code $RC (expected 0)" >&2
    exit 1
fi

# 2. Both hook sets installed.
if [ ! -f "$FIX/.claude/hooks/lang/python.sh" ]; then
    echo "FAIL: python.sh hook not installed" >&2
    exit 1
fi
if [ ! -f "$FIX/.claude/hooks/lang/node.sh" ]; then
    echo "FAIL: node.sh hook not installed" >&2
    exit 1
fi

CONF="$FIX/.claude/hooks/project.conf"

# 3. LANGS= line lists both python and node.
if ! grep -E '^LANGS=' "$CONF" | grep -q 'python' || ! grep -E '^LANGS=' "$CONF" | grep -q 'node'; then
    echo "FAIL: LANGS line does not list both python and node" >&2
    cat "$CONF" >&2
    exit 1
fi

# 4. No 'unknown' anywhere in project.conf.
if grep -q 'unknown' "$CONF"; then
    echo "FAIL: project.conf contains 'unknown'" >&2
    cat "$CONF" >&2
    exit 1
fi

# 5. Both ENTRY_POINTS_<lang> lines present (gate requires them in MULTI mode).
if ! grep -qE '^ENTRY_POINTS_python=' "$CONF"; then
    echo "FAIL: ENTRY_POINTS_python= missing" >&2
    cat "$CONF" >&2
    exit 1
fi
if ! grep -qE '^ENTRY_POINTS_node=' "$CONF"; then
    echo "FAIL: ENTRY_POINTS_node= missing" >&2
    cat "$CONF" >&2
    exit 1
fi

# ─── Fixture 2: explicit single-lang must keep legacy format ──────────
mkdir -p "$FIX2/src"
cat > "$FIX2/main.py" <<'EOF'
def main():
    pass
EOF

set +e
bash "$GUARDRAILS_ROOT/install.sh" "$FIX2" python >/dev/null 2>&1
RC2=$?
set -e
if [ $RC2 -ne 0 ]; then
    echo "FAIL: explicit-lang install exit code $RC2 (expected 0)" >&2
    exit 1
fi

CONF2="$FIX2/.claude/hooks/project.conf"
if ! grep -qE '^LANG="python"' "$CONF2"; then
    echo "FAIL: explicit-lang project.conf missing LANG=\"python\" line" >&2
    cat "$CONF2" >&2
    exit 1
fi
if grep -qE '^LANGS=' "$CONF2"; then
    echo "FAIL: explicit-lang project.conf unexpectedly has a LANGS= line" >&2
    cat "$CONF2" >&2
    exit 1
fi

echo "PASS: monorepo auto-detect installs union (python+node) and explicit single-lang keeps legacy format"
