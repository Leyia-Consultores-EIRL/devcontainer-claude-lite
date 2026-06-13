#!/usr/bin/env bash
# test_install_shell_ghost.sh — G1: install.sh shell installs the checker;
# checker detects ghost function (no call-site); passes when call-site added.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FAIL=0

# ─── Build dummy bash repo ────────────────────────────────────────────────────
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

mkdir -p "$FIX/scripts"

cat > "$FIX/scripts/lib.sh" <<'LIBEOF'
#!/usr/bin/env bash

ghost_func() {
    echo "I have no callers outside this file"
}

wired_func() {
    echo "I am called from main.sh"
}
LIBEOF

cat > "$FIX/scripts/main.sh" <<'MAINEOF'
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
wired_func
MAINEOF

# ─── A1: install.sh exits 0 for lang=shell ────────────────────────────────────
set +e
INSTALL_OUT=$(bash "$GUARDRAILS_ROOT/install.sh" "$FIX" shell 2>&1)
RC=$?
set -e

if [ $RC -ne 0 ]; then
    echo "FAIL A1: install.sh exited $RC for lang=shell"
    echo "Output: $INSTALL_OUT"
    FAIL=$((FAIL + 1))
fi

# ─── A2: shell.sh checker was installed ──────────────────────────────────────
if [ ! -f "$FIX/.claude/hooks/lang/shell.sh" ]; then
    echo "FAIL A2: .claude/hooks/lang/shell.sh was not installed"
    FAIL=$((FAIL + 1))
fi

# ─── A3: project.conf created with LANG=shell ────────────────────────────────
if [ ! -f "$FIX/.claude/hooks/project.conf" ]; then
    echo "FAIL A3: .claude/hooks/project.conf was not created"
    FAIL=$((FAIL + 1))
fi

if ! grep -q 'LANG=.shell' "$FIX/.claude/hooks/project.conf" 2>/dev/null; then
    echo "FAIL A3: project.conf does not set LANG=shell"
    FAIL=$((FAIL + 1))
fi

# Bail early if install failed
[ $FAIL -gt 0 ] && { echo "❌ $FAIL install assertion(s) failed — aborting checker tests"; exit 1; }

# ─── B1: checker finds ghost_func when no call-site ──────────────────────────
set -a
# shellcheck source=/dev/null
source "$FIX/.claude/hooks/project.conf"
set +a

CHECKER_OUT=$(
    cd "$FIX"
    ENTRY_POINTS="${ENTRY_POINTS:-scripts/main.sh}" \
    SRC_GLOBS="${SRC_GLOBS:-scripts}" \
        bash .claude/hooks/lang/shell.sh 2>/dev/null
) || true

if ! echo "$CHECKER_OUT" | grep -qw "ghost_func"; then
    echo "FAIL B1: checker did not flag ghost_func (expected it in output)"
    echo "Checker output: $CHECKER_OUT"
    FAIL=$((FAIL + 1))
else
    echo "PASS B1: checker flagged ghost_func"
fi

# ─── B2: checker does NOT flag wired_func ────────────────────────────────────
if echo "$CHECKER_OUT" | grep -qw "wired_func"; then
    echo "FAIL B2: checker incorrectly flagged wired_func (has call-site in main.sh)"
    echo "Checker output: $CHECKER_OUT"
    FAIL=$((FAIL + 1))
else
    echo "PASS B2: checker did not flag wired_func (has call-site)"
fi

# ─── B3: add call-site for ghost_func → checker no longer flags it ────────────
# Add call to ghost_func in main.sh
printf '\nghost_func\n' >> "$FIX/scripts/main.sh"

CHECKER_OUT2=$(
    cd "$FIX"
    ENTRY_POINTS="${ENTRY_POINTS:-scripts/main.sh}" \
    SRC_GLOBS="${SRC_GLOBS:-scripts}" \
        bash .claude/hooks/lang/shell.sh 2>/dev/null
) || true

if echo "$CHECKER_OUT2" | grep -qw "ghost_func"; then
    echo "FAIL B3: checker still flagged ghost_func after call-site was added"
    echo "Checker output: $CHECKER_OUT2"
    FAIL=$((FAIL + 1))
else
    echo "PASS B3: checker cleared ghost_func after call-site added"
fi

# ─── B4: intra-file caller counts — func called within same file is NOT ghost ──
# ghost_b4 is defined AND called within lib.sh itself; ghost_b4_user is defined
# but never called anywhere → ghost_b4 must be cleared, ghost_b4_user flagged.
FIX_B4=$(mktemp -d)
trap 'rm -rf "$FIX" "$FIX_B4"' EXIT

mkdir -p "$FIX_B4/scripts"
cat > "$FIX_B4/scripts/lib.sh" <<'EOF_B4'
#!/usr/bin/env bash
ghost_b4() {
    echo "helper"
}
ghost_b4_user() {
    ghost_b4
}
EOF_B4
cat > "$FIX_B4/scripts/main.sh" <<'EOF_B4'
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
EOF_B4

B4_OUT=$(
    cd "$FIX_B4"
    ENTRY_POINTS="scripts/main.sh" \
    SRC_GLOBS="scripts" \
        bash "$GUARDRAILS_ROOT/.claude/hooks/lang/shell.sh" 2>/dev/null
) || true

if echo "$B4_OUT" | grep -qw "ghost_b4$"; then
    echo "FAIL B4: checker incorrectly flagged ghost_b4 (has intra-file call-site)"
    echo "Checker output: $B4_OUT"
    FAIL=$((FAIL + 1))
else
    echo "PASS B4: ghost_b4 cleared (intra-file call-site detected)"
fi

if ! echo "$B4_OUT" | grep -qw "ghost_b4_user"; then
    echo "FAIL B4: checker should flag ghost_b4_user (only defined, never called)"
    echo "Checker output: $B4_OUT"
    FAIL=$((FAIL + 1))
else
    echo "PASS B4: ghost_b4_user flagged (no external or intra-file call-site)"
fi

# ─── C1: auto-detect picks up shell when no other lang manifest present ───────
FIX2=$(mktemp -d)
trap 'rm -rf "$FIX" "$FIX2"' EXIT

mkdir -p "$FIX2/scripts"
cat > "$FIX2/scripts/main.sh" <<'MAINEOF2'
#!/usr/bin/env bash
echo "entry point"
MAINEOF2

set +e
AD_OUT=$(bash "$GUARDRAILS_ROOT/install.sh" "$FIX2" 2>&1)
AD_RC=$?
set -e

if [ $AD_RC -ne 0 ]; then
    echo "FAIL C1: auto-detect install exited $AD_RC (expected 0 for shell project)"
    echo "Output: $AD_OUT"
    FAIL=$((FAIL + 1))
elif ! grep -q 'LANG=.shell' "$FIX2/.claude/hooks/project.conf" 2>/dev/null; then
    echo "FAIL C1: auto-detect project.conf does not set LANG=shell"
    echo "project.conf: $(cat "$FIX2/.claude/hooks/project.conf" 2>/dev/null)"
    FAIL=$((FAIL + 1))
else
    echo "PASS C1: auto-detect identified lang=shell for scripts-only repo"
fi

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "❌ $FAIL test(s) failed"
    exit 1
fi

echo ""
echo "PASS: shell ghost-code checker — install, ghost detection, call-site clearance, and auto-detect all correct"
