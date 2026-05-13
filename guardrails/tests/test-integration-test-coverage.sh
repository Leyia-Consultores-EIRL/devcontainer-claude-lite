#!/usr/bin/env bash
# test-integration-test-coverage.sh — regression tests para integration-test-coverage.sh
#
# Crea fixtures de git con distintos escenarios y verifica el exit code del hook.
# Todos los tests deben pasar (PASS) para que el script salga 0.
#
# Uso: bash guardrails/tests/test-integration-test-coverage.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$GUARDRAILS_ROOT/.claude/hooks/integration-test-coverage.sh"

if [ ! -x "$HOOK" ]; then
    echo "ERROR: hook not found or not executable: $HOOK" >&2
    exit 1
fi

PASS=0
FAIL=0
TOTAL=0

# ─── Helpers ──────────────────────────────────────────────────────────

# make_git_fixture <dir>
# Inicializa un repo git limpio con config mínima en <dir>.
make_git_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    cd "$dir"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
}

# run_hook_in <dir> [env_overrides...]
# Corre el hook en <dir> y retorna su exit code (sin propagar con set -e).
run_hook_in() {
    local dir="$1"; shift
    local env_prefix="${*:-}"
    (
        cd "$dir"
        if [ -n "$env_prefix" ]; then
            eval "env $env_prefix bash '$HOOK'" 2>/dev/null
        else
            bash "$HOOK" 2>/dev/null
        fi
    ) || true
    # Capturamos el exit code en la subshell y lo propagamos manualmente
    (
        cd "$dir"
        if [ -n "$env_prefix" ]; then
            eval "env $env_prefix bash '$HOOK'" 2>/dev/null
            echo $?
        else
            bash "$HOOK" 2>/dev/null
            echo $?
        fi
    ) 2>/dev/null | tail -1
}

# assert_exit <test_name> <expected_exit> <actual_exit>
assert_exit() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $name (exit $actual)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name — expected exit $expected, got $actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

# hook_exit_in <dir> [env=val ...]
# Retorna el exit code del hook corrido en <dir>.
# Usa una subshell aislada para no contaminar el directorio actual.
hook_exit_in() {
    local dir="$1"; shift
    local exit_code
    set +e
    (
        cd "$dir"
        # Aplicar variables de entorno adicionales si se pasan
        for kv in "$@"; do
            export "$kv"
        done
        bash "$HOOK" 2>/dev/null
    )
    exit_code=$?
    set -e
    echo $exit_code
}

# ─── Tests ────────────────────────────────────────────────────────────

echo "═══ test-integration-test-coverage.sh ═══"
echo ""

# ── Test 1: feat commit sin test → exit 2 ────────────────────────────
echo "Test 1: feat commit sin test → exit 2"
WORK1=$(mktemp -d)
trap 'rm -rf "$WORK1"' EXIT
(
    make_git_fixture "$WORK1"
    # Commit base para tener HEAD~1
    echo "# placeholder" > README.md
    git add README.md
    git commit -q -m "chore: init"
    # feat commit sin test
    echo "def new_feature(): pass" > feature.py
    git add feature.py
    git commit -q -m "feat(#1): add new_feature"
)
EXIT1=$(hook_exit_in "$WORK1")
assert_exit "feat sin test → exit 2" "2" "$EXIT1"
rm -rf "$WORK1"
trap - EXIT

# ── Test 2: feat commit CON test → exit 0 ────────────────────────────
echo ""
echo "Test 2: feat commit con tests/test_feature.py → exit 0"
WORK2=$(mktemp -d)
trap 'rm -rf "$WORK2"' EXIT
(
    make_git_fixture "$WORK2"
    echo "# placeholder" > README.md
    git add README.md
    git commit -q -m "chore: init"
    # feat commit con test
    echo "def new_feature(): pass" > feature.py
    mkdir -p tests
    echo "def test_new_feature(): assert True" > tests/test_feature.py
    git add feature.py tests/test_feature.py
    git commit -q -m "feat(#1): add new_feature"
)
EXIT2=$(hook_exit_in "$WORK2")
assert_exit "feat con test → exit 0" "0" "$EXIT2"
rm -rf "$WORK2"
trap - EXIT

# ── Test 3: fix commit sin test → exit 2 ─────────────────────────────
echo ""
echo "Test 3: fix commit sin test → exit 2"
WORK3=$(mktemp -d)
trap 'rm -rf "$WORK3"' EXIT
(
    make_git_fixture "$WORK3"
    echo "# placeholder" > README.md
    git add README.md
    git commit -q -m "chore: init"
    # fix commit sin test
    echo "def patched(): return True" > patch.py
    git add patch.py
    git commit -q -m "fix(#2): patch the thing"
)
EXIT3=$(hook_exit_in "$WORK3")
assert_exit "fix sin test → exit 2" "2" "$EXIT3"
rm -rf "$WORK3"
trap - EXIT

# ── Test 4: chore commit sin test → exit 0 ───────────────────────────
echo ""
echo "Test 4: chore commit sin test → exit 0 (chore no requiere test)"
WORK4=$(mktemp -d)
trap 'rm -rf "$WORK4"' EXIT
(
    make_git_fixture "$WORK4"
    echo "# placeholder" > README.md
    git add README.md
    git commit -q -m "chore: init"
    # chore commit sin test — debe pasar
    echo "2.0.0" > VERSION
    git add VERSION
    git commit -q -m "chore: bump deps to 2.0.0"
)
EXIT4=$(hook_exit_in "$WORK4")
assert_exit "chore sin test → exit 0" "0" "$EXIT4"
rm -rf "$WORK4"
trap - EXIT

# ── Test 5: SKIP_INTEGRATION_TEST_CHECK=1 en feat sin test → exit 0 ──
echo ""
echo "Test 5: SKIP_INTEGRATION_TEST_CHECK=1 en feat sin test → exit 0 + warning"
WORK5=$(mktemp -d)
trap 'rm -rf "$WORK5"' EXIT
(
    make_git_fixture "$WORK5"
    echo "# placeholder" > README.md
    git add README.md
    git commit -q -m "chore: init"
    echo "def hot_fix(): pass" > hotfix.py
    git add hotfix.py
    git commit -q -m "feat(#99): emergency hot-fix"
)
EXIT5=$(hook_exit_in "$WORK5" "SKIP_INTEGRATION_TEST_CHECK=1")
assert_exit "SKIP=1 en feat sin test → exit 0" "0" "$EXIT5"
rm -rf "$WORK5"
trap - EXIT

# ── Test 6: primer commit de la rama (sin HEAD~1) → no crash ─────────
echo ""
echo "Test 6: primer commit de rama (sin HEAD~1) → handled gracefully"
WORK6=$(mktemp -d)
trap 'rm -rf "$WORK6"' EXIT
(
    make_git_fixture "$WORK6"
    # Solo UN commit (no hay HEAD~1)
    echo "def feature(): pass" > feature.py
    git add feature.py
    git commit -q -m "feat(#5): initial feature, no predecessor"
)
# El hook no debe salir con código ≥ 128 (crash/signal).
# Puede salir 0 (graceful pass) o 2 (bloqueado, pero sin crash).
# El spec dice "handled gracefully, doesn't crash" — verificamos exit < 128.
set +e
(cd "$WORK6" && bash "$HOOK" 2>/dev/null)
EXIT6=$?
set -e
TOTAL=$((TOTAL + 1))
if [ "$EXIT6" -lt 128 ]; then
    echo "  PASS: primer commit manejado gracefully (exit $EXIT6, sin crash)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: primer commit causó crash (exit $EXIT6 ≥ 128)" >&2
    FAIL=$((FAIL + 1))
fi
rm -rf "$WORK6"
trap - EXIT

# ── Test 7 (bonus): docs commit sin test → exit 0 ────────────────────
echo ""
echo "Test 7 (bonus): docs commit sin test → exit 0"
WORK7=$(mktemp -d)
trap 'rm -rf "$WORK7"' EXIT
(
    make_git_fixture "$WORK7"
    echo "# placeholder" > README.md
    git add README.md
    git commit -q -m "chore: init"
    echo "# Docs" > DOCS.md
    git add DOCS.md
    git commit -q -m "docs: update changelog"
)
EXIT7=$(hook_exit_in "$WORK7")
assert_exit "docs sin test → exit 0" "0" "$EXIT7"
rm -rf "$WORK7"
trap - EXIT

# ── Test 8 (bonus): refactor commit sin test → exit 0 ────────────────
echo ""
echo "Test 8 (bonus): refactor commit sin test → exit 0"
WORK8=$(mktemp -d)
trap 'rm -rf "$WORK8"' EXIT
(
    make_git_fixture "$WORK8"
    echo "# placeholder" > README.md
    git add README.md
    git commit -q -m "chore: init"
    echo "def refactored(): pass" > module.py
    git add module.py
    git commit -q -m "refactor(core): extract helper"
)
EXIT8=$(hook_exit_in "$WORK8")
assert_exit "refactor sin test → exit 0" "0" "$EXIT8"
rm -rf "$WORK8"
trap - EXIT

# ─── Resumen ──────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "Tests: $TOTAL total, $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL test(s) FAILED"
    exit 1
fi
echo "✅ Todos los tests pasaron"
exit 0
