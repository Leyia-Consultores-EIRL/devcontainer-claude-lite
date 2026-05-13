#!/usr/bin/env bash
# integration-test-coverage.sh — Stop hook.
#
# Bloquea el fin de sesión (exit 2) si el último commit tiene prefijo feat(
# o fix( pero NO incluye ningún archivo de test en el mismo diff.
#
# Motivación: los commits feat/fix representan cambios funcionales; exigir un
# test en el mismo diff cierra la brecha entre "el código existe" y "el código
# está verificado". Complementa integration-gate.sh (que verifica call-sites)
# con una verificación de cobertura de prueba.
#
# Bypass: SKIP_INTEGRATION_TEST_CHECK=1 — solo para hot-fixes documentados.
#   El hook registra en stderr que el bypass fue usado para dejar rastro.
#
# Prefijos que NO requieren test (pasan sin verificar):
#   chore(  docs(  style(  refactor(  revert(  build(  ci(  perf(  test(
#
# Configuración del proyecto (.claude/hooks/project.conf):
#   TEST_GLOBS="tests/* test_* *_test.* *.test.* *.spec.* tests_e2e/*"
#   (El hook usa este valor si está definido; de lo contrario usa el default.)
#
# Exit codes:
#   0 — commit no requiere test, o test encontrado, o bypass activo
#   1 — error de setup (no hay git, no hay commits)
#   2 — commit feat/fix sin test → bloquea Stop

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOOKS_DIR/project.conf"

# ─── Cargar project.conf si existe (para TEST_GLOBS) ──────────────────
if [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    set -a
    source "$CONF"
    set +a
fi

# ─── Default TEST_GLOBS ───────────────────────────────────────────────
# Patrones que identifican archivos de test. Se pueden sobreescribir en
# project.conf con: TEST_GLOBS="tests/* test_* ..."
DEFAULT_TEST_GLOBS="tests/* test_* *_test.* *.test.* *.spec.* tests_e2e/*"
TEST_GLOBS="${TEST_GLOBS:-$DEFAULT_TEST_GLOBS}"

# ─── Bypass de emergencia ─────────────────────────────────────────────
# SKIP_INTEGRATION_TEST_CHECK=1 permite saltarse este hook en emergencias
# (hot-fixes que no pueden esperar un test). El bypass SIEMPRE deja rastro
# en stderr para que quede en los logs de Claude Code.
if [ "${SKIP_INTEGRATION_TEST_CHECK:-0}" = "1" ]; then
    echo "⚠️  integration-test-coverage.sh: BYPASS activo (SKIP_INTEGRATION_TEST_CHECK=1)." >&2
    echo "   Razón esperada: hot-fix de emergencia. Agregar test en follow-up commit." >&2
    exit 0
fi

# ─── Verificar que estamos en un repo git ─────────────────────────────
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "⚠️  integration-test-coverage.sh: no es un repo git. Saltando check." >&2
    exit 0
fi

# ─── Obtener el subject del último commit ─────────────────────────────
# Solo la primera línea del mensaje (subject) — ignoramos el body.
COMMIT_SUBJECT=$(git log -1 --format="%s" 2>/dev/null || true)

if [ -z "$COMMIT_SUBJECT" ]; then
    echo "⚠️  integration-test-coverage.sh: no hay commits en este repo." >&2
    exit 0
fi

# ─── ¿El commit requiere test? ────────────────────────────────────────
# Prefijos que SÍ requieren test: feat(  fix(
# Prefijos que NO requieren test: chore(  docs(  style(  refactor(  revert(
#   build(  ci(  perf(  test(  (y cualquier otro no-feat/non-fix)
#
# También aceptamos: feat!( fix!( (breaking changes con Conventional Commits)
# y variantes sin paréntesis: feat:  fix:  feat!:  fix!:
REQUIRES_TEST=0
if echo "$COMMIT_SUBJECT" | grep -qE '^(feat|fix)(\([^)]*\))?!?:'; then
    REQUIRES_TEST=1
fi

if [ "$REQUIRES_TEST" = "0" ]; then
    # Prefijo no requiere test — pasar sin ruido
    exit 0
fi

# ─── Obtener el diff del commit HEAD ──────────────────────────────────
# Si HEAD~1 no existe (primer commit de la rama), diff contra árbol vacío.
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

if git rev-parse HEAD~1 >/dev/null 2>&1; then
    DIFF_STAT=$(git diff HEAD~1 HEAD --name-only 2>/dev/null || true)
else
    # Primer commit: diff contra árbol vacío
    DIFF_STAT=$(git diff-tree --no-commit-id -r --name-only HEAD 2>/dev/null || true)
fi

if [ -z "$DIFF_STAT" ]; then
    # Commit vacío o diff ilegible — dejar pasar con advertencia
    echo "⚠️  integration-test-coverage.sh: no se pudo obtener el diff de HEAD. Saltando check." >&2
    exit 0
fi

# ─── Buscar archivos de test en el diff ───────────────────────────────
# Criterios (cualquier match es suficiente):
#   1. El path contiene un componente "tests/" o "test_" o "_test" o ".test." o ".spec."
#   2. Coincide con algún glob en TEST_GLOBS
#
# Construimos una expresión regex a partir de TEST_GLOBS para el grep.
# Cada glob "tests/*" → "tests/", "*_test.*" → "_test\.", etc.
# Para simplicidad usamos patrones directos sobre los nombres de archivo.

TEST_FOUND=0
TEST_FILE=""

while IFS= read -r changed_file; do
    [ -z "$changed_file" ] && continue

    # Criterio 1: patrones hardcoded comunes (más fiables que el glob parsing)
    if echo "$changed_file" | grep -qE \
        '(^|/)tests/|/tests_e2e/|(^|/)test_[^/]+$|_test\.[^/]+$|\.test\.[^/]+$|\.spec\.[^/]+$'; then
        TEST_FOUND=1
        TEST_FILE="$changed_file"
        break
    fi

    # Criterio 2: coincide con algún glob de TEST_GLOBS
    for glob in $TEST_GLOBS; do
        # Convertimos el glob a un patrón básico: sustituimos * por [^/]* y ? por .
        # Solo hacemos matching contra el basename del archivo para globs sin /,
        # o contra el path completo para globs con /.
        basename_file=$(basename "$changed_file")
        # Usamos case para matching de glob nativo de bash
        # (No podemos usar [[ ]] con variable en pattern en sh-portable,
        # pero bash soporta case patterns con variables entre comillas)
        if case "$changed_file" in $glob) true;; *) false;; esac || \
           case "$basename_file" in $glob) true;; *) false;; esac; then
            TEST_FOUND=1
            TEST_FILE="$changed_file"
            break 2
        fi
    done
done <<< "$DIFF_STAT"

# ─── Resultado ────────────────────────────────────────────────────────
if [ "$TEST_FOUND" = "1" ]; then
    echo "integration-test-coverage.sh: ✓ commit '$COMMIT_SUBJECT' incluye test ($TEST_FILE)." >&2
    exit 0
fi

# No se encontró test — bloquear el Stop
echo "" >&2
echo "INTEGRATION TEST COVERAGE BLOCK: el commit con prefijo feat/fix no incluye ningún archivo de test." >&2
echo "" >&2
echo "  Commit: $COMMIT_SUBJECT" >&2
echo "" >&2
echo "  Archivos en el diff (ninguno reconocido como test):" >&2
echo "$DIFF_STAT" | head -20 | sed 's/^/    /' >&2
echo "" >&2
echo "  Patrones de test esperados (TEST_GLOBS): $TEST_GLOBS" >&2
echo "" >&2
echo "Acción por defecto (sin consultar al usuario): agregar al mismo commit un archivo" >&2
echo "  de test bajo tests/, test_*.py, *.test.ts, *.spec.ts, etc., que ejercite el cambio." >&2
echo "" >&2
echo "Bypass de emergencia (solo hot-fixes documentados):" >&2
echo "  SKIP_INTEGRATION_TEST_CHECK=1 <claude_stop_command>" >&2
echo "  El bypass deja registro en stderr. Se espera un follow-up con el test." >&2
echo "" >&2
echo "Contexto DoD: guardrails/docs/DEFINITION_OF_DONE.md §7" >&2
exit 2
