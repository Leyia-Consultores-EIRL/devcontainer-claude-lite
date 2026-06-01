#!/usr/bin/env bash
# test_ghost_test_guard.sh — verify ghost-test-guard.sh hook behavior.
#
# Each test case spins up an isolated git repo, plants test files, and
# runs the hook — asserting it blocks (exit != 0) or passes (exit 0).
#
# These tests exercise the hook's runtime behavior, not its source text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDRAILS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$GUARDRAILS_ROOT/.claude/hooks/ghost-test-guard.sh"

if [ ! -x "$HOOK" ]; then
    echo "FAIL: hook not found or not executable at $HOOK" >&2
    exit 1
fi

# ─── Helper: init a minimal git repo ─────────────────────────────────────────
init_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit --allow-empty -m "init" -q
    mkdir -p "$dir/hooks"
    cp "$HOOK" "$dir/hooks/ghost-test-guard.sh"
}

# ─── Test case A — source-grep ghost test → must block ───────────────────────
WORK_A=$(mktemp -d)
trap 'rm -rf "$WORK_A"' EXIT

init_repo "$WORK_A"
mkdir -p "$WORK_A/tests"

cat > "$WORK_A/tests/test_ghost.py" <<'EOF'
def test_bad():
    content = open("src/module.py").read()
    assert "process_data" in content
EOF

# Leave untracked so git ls-files --others picks it up.

OUTPUT_A=$(cd "$WORK_A" && bash "$WORK_A/hooks/ghost-test-guard.sh" 2>&1) && RC_A=0 || RC_A=$?

if [ "$RC_A" -eq 0 ]; then
    echo "FAIL: source-grep ghost test was not blocked (expected exit != 0)" >&2
    echo "Hook output: $OUTPUT_A" >&2
    exit 1
fi

if ! echo "$OUTPUT_A" | grep -qiE 'source-grep|ghost'; then
    echo "FAIL: output missing 'source-grep' or 'ghost' keyword" >&2
    echo "Hook output: $OUTPUT_A" >&2
    exit 1
fi

echo "PASS: source-grep ghost test blocked (exit $RC_A, output mentions ghost pattern)"

# ─── Test case B — clean behavioral test → must pass ─────────────────────────
WORK_B=$(mktemp -d)
trap 'rm -rf "$WORK_A" "$WORK_B"' EXIT

init_repo "$WORK_B"
mkdir -p "$WORK_B/tests"

cat > "$WORK_B/tests/test_behavioral.py" <<'EOF'
from unittest.mock import patch

def test_good():
    with patch("subprocess.run") as mock_run:
        mock_run.return_value.returncode = 0
        result = my_function()
        assert result == "expected_output"
EOF

# Stage the file so git diff HEAD picks it up.
git -C "$WORK_B" add tests/test_behavioral.py

OUTPUT_B=$(cd "$WORK_B" && bash "$WORK_B/hooks/ghost-test-guard.sh" 2>&1) && RC_B=0 || RC_B=$?

if [ "$RC_B" -ne 0 ]; then
    echo "FAIL: clean behavioral test was incorrectly blocked (exit $RC_B)" >&2
    echo "Hook output: $OUTPUT_B" >&2
    exit 1
fi

echo "PASS: clean behavioral test passed hook (exit 0)"

# ─── Test case C — hardcoded absolute path → must block ──────────────────────
WORK_C=$(mktemp -d)
trap 'rm -rf "$WORK_A" "$WORK_B" "$WORK_C"' EXIT

init_repo "$WORK_C"
mkdir -p "$WORK_C/tests"

cat > "$WORK_C/tests/test_hardpath.py" <<'EOF'
def test_bad_path():
    import os
    path = "/workspace/.worktrees/issue-53/src/module.py"
    assert os.path.exists(path)
EOF

# Leave untracked.

OUTPUT_C=$(cd "$WORK_C" && bash "$WORK_C/hooks/ghost-test-guard.sh" 2>&1) && RC_C=0 || RC_C=$?

if [ "$RC_C" -eq 0 ]; then
    echo "FAIL: hardcoded-path ghost test was not blocked (expected exit != 0)" >&2
    echo "Hook output: $OUTPUT_C" >&2
    exit 1
fi

if ! echo "$OUTPUT_C" | grep -qiE 'hardcoded-path|ghost'; then
    echo "FAIL: output missing 'hardcoded-path' or 'ghost' keyword" >&2
    echo "Hook output: $OUTPUT_C" >&2
    exit 1
fi

echo "PASS: hardcoded-path ghost test blocked (exit $RC_C, output mentions hardcoded-path)"

# ─── Test case D — bats structural (no run invocation) → must block ──────────
WORK_D=$(mktemp -d)
trap 'rm -rf "$WORK_A" "$WORK_B" "$WORK_C" "$WORK_D"' EXIT

init_repo "$WORK_D"
mkdir -p "$WORK_D/tests"

cat > "$WORK_D/tests/test_structural.bats" <<'EOF'
#!/usr/bin/env bats

@test "myscript contains set -euo" {
    result=$(grep "set -euo" myscript.sh)
    [ -n "$result" ]
}

@test "myscript contains LANG check" {
    result=$(grep "LANG" myscript.sh)
    [ -n "$result" ]
}
EOF

# Leave untracked.

OUTPUT_D=$(cd "$WORK_D" && bash "$WORK_D/hooks/ghost-test-guard.sh" 2>&1) && RC_D=0 || RC_D=$?

if [ "$RC_D" -eq 0 ]; then
    echo "FAIL: bats-structural ghost test was not blocked (expected exit != 0)" >&2
    echo "Hook output: $OUTPUT_D" >&2
    exit 1
fi

if ! echo "$OUTPUT_D" | grep -qiE 'bats-structural|ghost'; then
    echo "FAIL: output missing 'bats-structural' or 'ghost' keyword" >&2
    echo "Hook output: $OUTPUT_D" >&2
    exit 1
fi

echo "PASS: bats-structural ghost test blocked (exit $RC_D, output mentions bats-structural)"

# ─── Test case E — bats behavioral (has run invocation) → must pass ──────────
WORK_E=$(mktemp -d)
trap 'rm -rf "$WORK_A" "$WORK_B" "$WORK_C" "$WORK_D" "$WORK_E"' EXIT

init_repo "$WORK_E"
mkdir -p "$WORK_E/tests"

cat > "$WORK_E/tests/test_behavioral.bats" <<'EOF'
#!/usr/bin/env bats

@test "myscript exits 0 on valid input" {
    run bash myscript.sh --help
    [ "$status" -eq 0 ]
}

@test "myscript rejects missing arg" {
    run bash myscript.sh
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}
EOF

git -C "$WORK_E" add tests/test_behavioral.bats

OUTPUT_E=$(cd "$WORK_E" && bash "$WORK_E/hooks/ghost-test-guard.sh" 2>&1) && RC_E=0 || RC_E=$?

if [ "$RC_E" -ne 0 ]; then
    echo "FAIL: clean behavioral bats test was incorrectly blocked (exit $RC_E)" >&2
    echo "Hook output: $OUTPUT_E" >&2
    exit 1
fi

echo "PASS: clean behavioral bats test passed hook (exit 0)"

# ─── Test case F — commented grep in bats → must NOT block ───────────────────
WORK_F=$(mktemp -d)
trap 'rm -rf "$WORK_A" "$WORK_B" "$WORK_C" "$WORK_D" "$WORK_E" "$WORK_F"' EXIT

init_repo "$WORK_F"
mkdir -p "$WORK_F/tests"

cat > "$WORK_F/tests/test_commented.bats" <<'EOF'
#!/usr/bin/env bats

# Example bad pattern (do not do this): grep "set -euo" myscript.sh
# The test below is behaviorally correct.

@test "myscript runs cleanly" {
    run bash myscript.sh --version
    [ "$status" -eq 0 ]
}
EOF

git -C "$WORK_F" add tests/test_commented.bats

OUTPUT_F=$(cd "$WORK_F" && bash "$WORK_F/hooks/ghost-test-guard.sh" 2>&1) && RC_F=0 || RC_F=$?

if [ "$RC_F" -ne 0 ]; then
    echo "FAIL: bats with commented grep was incorrectly blocked (exit $RC_F, false positive)" >&2
    echo "Hook output: $OUTPUT_F" >&2
    exit 1
fi

echo "PASS: bats with commented-out grep was not blocked (no false positive)"

echo ""
echo "ALL PASS: ghost-test-guard"
