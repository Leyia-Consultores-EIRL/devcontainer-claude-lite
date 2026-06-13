#!/usr/bin/env bash
# install.sh — universal installer for the integration-gates guardrails.
#
# Usage: bash guardrails/install.sh <target-project-dir> <lang>
#
# Copies .claude/ contents into <target-project-dir>/.claude/, writes a
# project.conf with the specified lang, initializes ghost-baseline.txt,
# and appends the Definition of Done to <target>/CLAUDE.md.
#
# langs: rust | python | node | astro | nextjs | go | java | kotlin-android | shell
#
# `astro` is a specialization of `node` for Astro projects: it treats every
# file under src/pages/ plus src/middleware.ts and astro.config.{mjs,ts,js}
# as an implicit entry-point (file-based routing has no single `main`).
#
# `kotlin-android` is a specialization for Android Kotlin projects: it
# treats your Application class + MainActivity + top-level NavGraph as
# multi-entry-points, auto-discovers Koin module DSL files (`module {`)
# as additional reachability sources, and consults AndroidManifest.xml for
# manifest-declared Service / Receiver / Provider symbols. Use this for
# Android-specific projects; for server-side or KMP Kotlin without
# Android conventions, the `java` checker (which scans .kt + .java) or a
# new `kotlin` checker is more appropriate.
#
# Idempotent-ish: re-running overwrites hook scripts (so updates propagate)
# but preserves project.conf and ghost-baseline.txt if they exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
LANG="${2:-}"

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target-project-dir> [lang]" >&2
    echo "  langs: rust | python | node | astro | nextjs | go | java | kotlin-android | shell | python-rust" >&2
    echo "  (omit lang to auto-detect a monorepo at maxdepth 2)" >&2
    exit 1
fi

if [ ! -d "$TARGET" ]; then
    echo "Target directory does not exist: $TARGET" >&2
    exit 1
fi

# ─── Mode selection ───────────────────────────────────────────────────
# AUTO_DETECT=1 means <lang> was omitted → scan the target for manifests.
# Otherwise the explicit-lang (incl. python-rust) paths run unchanged.
AUTO_DETECT=0
if [ -z "$LANG" ]; then
    AUTO_DETECT=1
else
    case "$LANG" in
        rust|python|node|astro|nextjs|go|java|kotlin-android|shell) ;;
        python-rust) ;;  # meta-lang: installs both python.sh + rust.sh
        *)
            echo "Unsupported language: $LANG" >&2
            echo "Supported: rust | python | node | astro | nextjs | go | java | kotlin-android | shell | python-rust" >&2
            exit 1
            ;;
    esac
fi

cd "$TARGET"

# ─── Auto-detect helpers (monorepo mode only) ─────────────────────────
# Print, one per line, the relative subdirectories (relative to target,
# EXCLUDING the repo root) that contain a manifest matching $1 (a find
# -name pattern, possibly multiple via "-o"). Root manifests contribute
# nothing here so a root-only manifest yields empty SRC_GLOBS.
_detect_subdirs() {
    # $@ = find name predicates already assembled, e.g. -name pyproject.toml
    find . -maxdepth 2 \
        \( -name .git -o -name node_modules -o -name .venv -o -name target \
           -o -name dist -o -name build \) -prune -o \
        -type f \( "$@" \) -print 2>/dev/null \
        | sed -e 's#^\./##' \
        | while IFS= read -r m; do
            d=$(dirname "$m")
            [ "$d" = "." ] && continue
            echo "$d"
          done \
        | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# Return 0 if a manifest matching the given find predicates exists at
# maxdepth 2 (root OR one subdir level).
_lang_present() {
    local hit
    hit=$(find . -maxdepth 2 \
        \( -name .git -o -name node_modules -o -name .venv -o -name target \
           -o -name dist -o -name build \) -prune -o \
        -type f \( "$@" \) -print 2>/dev/null | head -1)
    [ -n "$hit" ]
}

# First subdir (relative, EXCLUDING root suppression) that holds the
# manifest; emits "." when only a root manifest exists. Used to pick the
# representative entry-point search root S.
_first_src_root() {
    local first
    first=$(find . -maxdepth 2 \
        \( -name .git -o -name node_modules -o -name .venv -o -name target \
           -o -name dist -o -name build \) -prune -o \
        -type f \( "$@" \) -print 2>/dev/null \
        | sed -e 's#^\./##' | head -1)
    if [ -z "$first" ]; then echo "."; return; fi
    local d
    d=$(dirname "$first")
    echo "$d"
}

# Normalize "./x" → "x" and "./" → "" ; "." stays ".".
_norm_path() {
    case "$1" in
        ./*) echo "${1#./}" ;;
        *)   echo "$1" ;;
    esac
}

# Best-effort representative entry-point for a lang given search root S.
_entry_point_python() {
    local S="$1" c
    for c in "$S/main.py" "$S/__main__.py" "$S/src/__main__.py"; do
        [ -f "$c" ] && { _norm_path "$c"; return; }
    done
    c=$(ls "$S"/*/__main__.py 2>/dev/null | head -1)
    [ -n "$c" ] && { _norm_path "$c"; return; }
    c=$(ls "$S"/*/cli.py 2>/dev/null | head -1)
    [ -n "$c" ] && { _norm_path "$c"; return; }
    _norm_path "$S/main.py"
}
_entry_point_node() {
    local S="$1" main
    if [ -f "$S/package.json" ] && command -v node >/dev/null 2>&1; then
        main=$(node -e "try { console.log(require('./$S/package.json').main || '') } catch(e) { console.log('') }" 2>/dev/null)
        if [ -n "$main" ]; then _norm_path "$S/$main"; return; fi
    fi
    _norm_path "$S/src/index.ts"
}
_entry_point_rust() {
    local S="$1" c
    [ -f "$S/src/main.rs" ] && { _norm_path "$S/src/main.rs"; return; }
    c=$(ls "$S"/crates/*/src/main.rs 2>/dev/null | head -1)
    [ -n "$c" ] && { _norm_path "$c"; return; }
    _norm_path "$S/src/main.rs"
}
_entry_point_go() {
    local S="$1" c
    [ -f "$S/main.go" ] && { _norm_path "$S/main.go"; return; }
    c=$(ls "$S"/cmd/*/main.go 2>/dev/null | head -1)
    [ -n "$c" ] && { _norm_path "$c"; return; }
    _norm_path "$S/main.go"
}
_entry_point_shell() {
    local S="$1" c
    [ -f "$S/main.sh" ] && { _norm_path "$S/main.sh"; return; }
    [ -f "$S/scripts/main.sh" ] && { _norm_path "$S/scripts/main.sh"; return; }
    c=$(find "$S" -maxdepth 2 -name 'main.sh' -type f 2>/dev/null | head -1)
    [ -n "$c" ] && { _norm_path "$c"; return; }
    c=$(find "$S" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | grep -v test | head -1)
    [ -n "$c" ] && { _norm_path "$c"; return; }
    _norm_path "$S/main.sh"
}

# ─── Determine LANGS_TO_INSTALL + MULTI ───────────────────────────────
if [ "$AUTO_DETECT" = "1" ]; then
    DETECTED=""
    _lang_present -name pyproject.toml -o -name requirements.txt && DETECTED="$DETECTED python"
    _lang_present -name package.json                             && DETECTED="$DETECTED node"
    _lang_present -name Cargo.toml                               && DETECTED="$DETECTED rust"
    _lang_present -name go.mod                                   && DETECTED="$DETECTED go"

    # Shell: fallback only when no managed-lang manifest found
    if [ -z "$DETECTED" ]; then
        { _lang_present -name '*.bats' || \
          { [ -d scripts ] && find scripts -maxdepth 2 -name '*.sh' -type f 2>/dev/null | grep -q .; }; } \
          && DETECTED="shell"
    fi

    # Stable de-dup in canonical order: python node rust go shell.
    LANGS_TO_INSTALL=""
    for L in python node rust go shell; do
        case " $DETECTED " in *" $L "*) LANGS_TO_INSTALL="$LANGS_TO_INSTALL $L" ;; esac
    done
    LANGS_TO_INSTALL=$(echo "$LANGS_TO_INSTALL" | sed 's/^ *//;s/ *$//')

    if [ -z "$LANGS_TO_INSTALL" ]; then
        echo "no language manifests found under $TARGET at maxdepth 2; pass an explicit <lang> (rust|python|node|...)" >&2
        exit 1
    fi

    N_LANGS=$(echo "$LANGS_TO_INSTALL" | wc -w | tr -d ' ')
    MULTI=0
    [ "$N_LANGS" -gt 1 ] && MULTI=1
    echo "→ Installing integration-gates guardrails into $TARGET (auto-detect)"
    echo "→ Auto-detected langs: $LANGS_TO_INSTALL"
    echo ""
elif [ "$LANG" = "python-rust" ]; then
    LANGS_TO_INSTALL="python rust"
    MULTI=1
    echo "→ Installing integration-gates guardrails into $TARGET (lang=$LANG)"
    echo ""
else
    LANGS_TO_INSTALL="$LANG"
    MULTI=0
    echo "→ Installing integration-gates guardrails into $TARGET (lang=$LANG)"
    echo ""
fi

# 1. Copy .claude/ structure. Core three hooks are lang-agnostic; the
#    per-lang checker(s) are copied for EVERY lang in LANGS_TO_INSTALL.
mkdir -p .claude/hooks/lang
cp -f "$SCRIPT_DIR/.claude/hooks/integration-gate.sh" .claude/hooks/
cp -f "$SCRIPT_DIR/.claude/hooks/ghost-report.sh" .claude/hooks/
cp -f "$SCRIPT_DIR/.claude/hooks/new-symbol-guard.sh" .claude/hooks/
cp -f "$SCRIPT_DIR/.claude/hooks/ghost-test-guard.sh" .claude/hooks/
for L in $LANGS_TO_INSTALL; do
    cp -f "$SCRIPT_DIR/.claude/hooks/lang/$L.sh" .claude/hooks/lang/
done
chmod +x .claude/hooks/*.sh .claude/hooks/lang/*.sh

echo "  ✓ Copied hook scripts to .claude/hooks/"

# 2. Merge or create settings.json
# fix(#44): merge programmatically when settings.json already exists; never silently skip.
if [ -f ".claude/settings.json" ]; then
    if command -v jq >/dev/null 2>&1; then
        if ! MERGED=$(jq -s '
            .[0] as $existing | .[1] as $template |
            $existing * { "hooks": (
                ($existing.hooks // {}) as $eh |
                ($template.hooks // {}) as $th |
                reduce ($th | keys[]) as $event (
                    $eh;
                    . + { ($event): (
                        ((.[$event] // []) + $th[$event]) | unique_by(.hooks[0].command // .)
                    )}
                )
            )}
        ' ".claude/settings.json" "$SCRIPT_DIR/.claude/settings.json"); then
            echo "  ⚠️  jq failed to merge settings.json — NOT overwriting." >&2
            echo "     Merge manually from $SCRIPT_DIR/.claude/settings.json" >&2
            exit 1
        fi
        if [ -z "$MERGED" ]; then
            echo "  ⚠️  jq produced empty output — NOT overwriting settings.json." >&2
            exit 1
        fi
        echo "$MERGED" > .claude/settings.json
        echo "  ✓ Merged hooks into existing .claude/settings.json (jq)"
    else
        echo "ERROR: .claude/settings.json already exists but jq is not installed." >&2
        echo "  jq is required to merge hooks into an existing settings.json." >&2
        echo "  Install jq (e.g. apt-get install jq / brew install jq) and re-run." >&2
        exit 1
    fi
else
    cp -f "$SCRIPT_DIR/.claude/settings.json" .claude/settings.json
    echo "  ✓ Created .claude/settings.json with hooks registered"
fi

# 3. Create project.conf if missing
if [ ! -f ".claude/hooks/project.conf" ] && [ "$AUTO_DETECT" = "1" ]; then
    # ─── Auto-detect (monorepo) project.conf ──────────────────────────
    # Compute, per detected lang, its SRC_GLOBS (subdirs holding the
    # manifest, empty if root-level) and a best-effort ENTRY_POINTS.
    declare -A AD_EP AD_SG
    for L in $LANGS_TO_INSTALL; do
        case "$L" in
            python) PRED='-name pyproject.toml -o -name requirements.txt' ;;
            node)   PRED='-name package.json' ;;
            rust)   PRED='-name Cargo.toml' ;;
            go)     PRED='-name go.mod' ;;
            shell)
                # Shell has no package manifest; detect scripts/ or root
                if [ -d scripts ] && find scripts -maxdepth 2 -name '*.sh' -type f 2>/dev/null | grep -q .; then
                    SG="scripts"
                    S="scripts"
                else
                    SG=""
                    S="."
                fi
                AD_EP["$L"]=$(_entry_point_shell "$S")
                AD_SG["$L"]="$SG"
                continue
                ;;
        esac
        # shellcheck disable=SC2086
        SG=$(_detect_subdirs $PRED)
        # shellcheck disable=SC2086
        S=$(_first_src_root $PRED)
        case "$L" in
            python) EP=$(_entry_point_python "$S") ;;
            node)   EP=$(_entry_point_node "$S") ;;
            rust)   EP=$(_entry_point_rust "$S") ;;
            go)     EP=$(_entry_point_go "$S") ;;
        esac
        AD_EP["$L"]="$EP"
        AD_SG["$L"]="$SG"
    done

    if [ "$MULTI" = "1" ]; then
        {
            echo "# Auto-generated by guardrails/install.sh (monorepo auto-detect) on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "# See guardrails/docs/LANG_MATRIX.md §Multi-lang projects for full reference."
            echo ""
            echo "LANGS=\"$LANGS_TO_INSTALL\""
            for L in $LANGS_TO_INSTALL; do
                echo "ENTRY_POINTS_${L}=\"${AD_EP[$L]}\""
            done
            echo ""
            echo "# SRC_GLOBS auto-derived from layout (empty = root-level, lets the"
            echo "# checker auto-detect). Override here if your sources live elsewhere."
            for L in $LANGS_TO_INSTALL; do
                echo "SRC_GLOBS_${L}=\"${AD_SG[$L]}\""
            done
        } > .claude/hooks/project.conf
        echo "  ✓ Created .claude/hooks/project.conf (LANGS=$LANGS_TO_INSTALL)"
    else
        # Exactly one lang detected → legacy single-lang format.
        ONLY_LANG="$LANGS_TO_INSTALL"
        {
            echo "# Auto-generated by guardrails/install.sh (monorepo auto-detect) on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "# See guardrails/docs/LANG_MATRIX.md for full reference."
            echo ""
            echo "LANG=\"$ONLY_LANG\""
            echo "ENTRY_POINTS=\"${AD_EP[$ONLY_LANG]}\""
            # SRC_GLOBS only when the manifest lives in a subdir (not root).
            if [ -n "${AD_SG[$ONLY_LANG]}" ]; then
                echo "SRC_GLOBS=\"${AD_SG[$ONLY_LANG]}\""
            fi
        } > .claude/hooks/project.conf
        echo "  ✓ Created .claude/hooks/project.conf (LANG=$ONLY_LANG, ENTRY_POINTS=${AD_EP[$ONLY_LANG]})"
    fi
    echo "     Verify the entry-point is correct. Edit if needed:"
    echo "       \$EDITOR .claude/hooks/project.conf"
elif [ ! -f ".claude/hooks/project.conf" ]; then
    # Detect entry-point heuristically by language
    case "$LANG" in
        rust)
            if [ -f "src/main.rs" ]; then EP="src/main.rs"
            elif ls crates/*/src/main.rs 2>/dev/null | head -1; then EP=$(ls crates/*/src/main.rs 2>/dev/null | head -1)
            else EP="src/main.rs"
            fi
            ;;
        python)
            if [ -f "src/__main__.py" ]; then EP="src/__main__.py"
            elif ls src/*/__main__.py 2>/dev/null | head -1; then EP=$(ls src/*/__main__.py 2>/dev/null | head -1)
            elif [ -f "main.py" ]; then EP="main.py"
            else EP="src/__main__.py"
            fi
            ;;
        node)
            # Read "main" from package.json if present
            if [ -f "package.json" ] && command -v node >/dev/null 2>&1; then
                EP=$(node -e "try { console.log(require('./package.json').main || 'src/index.ts') } catch(e) { console.log('src/index.ts') }" 2>/dev/null)
            else
                EP="src/index.ts"
            fi
            ;;
        astro)
            # Astro has no single entry-point. We record a representative
            # root that the gate messages can refer to; the checker itself
            # auto-discovers src/pages/** + middleware + astro.config.
            if [ -d "src/pages" ]; then EP="src/pages/"
            else EP="src/pages/"
            fi
            ;;
        nextjs)
            # Next.js App Router has no single entry-point. We record a
            # representative root for messages; the checker auto-discovers
            # src/app/** (and src/pages/** if present) + middleware +
            # next.config.* + instrumentation.
            if [ -d "src/app" ]; then EP="src/app/"
            elif [ -d "app" ]; then EP="app/"
            elif [ -d "src/pages" ]; then EP="src/pages/"
            elif [ -d "pages" ]; then EP="pages/"
            else EP="src/app/"
            fi
            ;;
        go)
            if ls cmd/*/main.go 2>/dev/null | head -1; then EP=$(ls cmd/*/main.go 2>/dev/null | head -1)
            elif [ -f "main.go" ]; then EP="main.go"
            else EP="cmd/app/main.go"
            fi
            ;;
        java)
            EP=$(find src/main/java -name '*.java' -exec grep -l 'public static void main' {} \; 2>/dev/null | head -1)
            EP="${EP:-src/main/java/App.java}"
            ;;
        kotlin-android)
            # Android entry-points: MainActivity + Application class + top-level
            # Compose graph composable. Auto-discover MainActivity; the user
            # should review and add their Application class + nav graph file.
            MAIN_ACTIVITY=$(find app/src/main/java -name 'MainActivity.kt' 2>/dev/null | head -1)
            APP_CLASS=$(find app/src/main/java -name '*Application.kt' 2>/dev/null | head -1)
            APP_GRAPH=$(find app/src/main/java -name '*App.kt' -not -name '*Application.kt' 2>/dev/null | head -1)
            EP="${MAIN_ACTIVITY:-app/src/main/java/MainActivity.kt}"
            [ -n "$APP_CLASS" ] && EP="$EP $APP_CLASS"
            [ -n "$APP_GRAPH" ] && EP="$EP $APP_GRAPH"
            ;;
        python-rust)
            # Heuristic: prefer python/<pkg>/cli.py, then python/main.py, then main.py.
            EP_PY=""
            for cand in $(ls python/*/cli.py 2>/dev/null) python/main.py main.py src/__main__.py; do
                if [ -f "$cand" ]; then EP_PY="$cand"; break; fi
            done
            EP_PY="${EP_PY:-python/main.py}"

            # Heuristic: prefer rust/crates/*/src/main.rs, then rust/src/main.rs, then src/main.rs.
            EP_RS=""
            for cand in $(ls rust/crates/*/src/main.rs 2>/dev/null) rust/src/main.rs src/main.rs; do
                if [ -f "$cand" ]; then EP_RS="$cand"; break; fi
            done
            EP_RS="${EP_RS:-rust/src/main.rs}"

            # SRC_GLOBS: derive from entry-point's top-level directory.
            # python: "python" if EP_PY starts with python/; else "src" if it starts with src/; else empty (lets checker auto-detect).
            case "$EP_PY" in
                python/*) SG_PY="python" ;;
                src/*)    SG_PY="src" ;;
                *)        SG_PY="" ;;
            esac
            # rust: "rust/crates" if EP_RS in rust/crates/; "rust" if rust/; "crates" if crates/; else empty.
            case "$EP_RS" in
                rust/crates/*) SG_RS="rust/crates" ;;
                rust/*)        SG_RS="rust" ;;
                crates/*)      SG_RS="crates" ;;
                *)             SG_RS="" ;;
            esac

            EP="$EP_PY (python) + $EP_RS (rust)"  # display only; written below as separate vars
            ;;
        shell)
            if [ -f "scripts/main.sh" ]; then EP="scripts/main.sh"
            elif [ -f "main.sh" ]; then EP="main.sh"
            else
                EP=$(find . -maxdepth 3 -name '*.sh' -type f 2>/dev/null \
                    | grep -v 'test\|spec\|bats' | head -1)
                EP="${EP:-main.sh}"
            fi
            ;;
    esac

    if [ "$LANG" = "python-rust" ]; then
        cat > .claude/hooks/project.conf <<EOF
# Auto-generated by guardrails/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# See guardrails/docs/LANG_MATRIX.md §Multi-lang projects for full reference.

LANGS="python rust"
ENTRY_POINTS_python="$EP_PY"
ENTRY_POINTS_rust="$EP_RS"

# SRC_GLOBS auto-derived from layout. Override here if your sources live
# elsewhere. The hooks fall back to global SRC_GLOBS / TEST_EXCLUDES /
# GHOST_SKIP_NAMES if the per-lang variant is unset.
SRC_GLOBS_python="$SG_PY"
SRC_GLOBS_rust="$SG_RS"
EOF
    else
        cat > .claude/hooks/project.conf <<EOF
# Auto-generated by guardrails/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# See guardrails/docs/LANG_MATRIX.md for full reference.

LANG="$LANG"
ENTRY_POINTS="$EP"
EOF
    fi
    echo "  ✓ Created .claude/hooks/project.conf (LANG=$LANG, ENTRY_POINTS=$EP)"
    echo "     Verify the entry-point is correct. Edit if needed:"
    echo "       \$EDITOR .claude/hooks/project.conf"
else
    echo "  ⚠️  .claude/hooks/project.conf already exists — NOT overwriting."
fi

# 4. Initialize ghost baseline
if [ ! -f ".claude/ghost-baseline.txt" ]; then
    # The lang checker reads ENTRY_POINTS / SRC_GLOBS / TEST_EXCLUDES from
    # the process environment. `source` alone sets shell-locals; the child
    # `bash` invocation below is a separate shell and does NOT inherit
    # locals. Without `set -a` the checker exits early with "ENTRY_POINTS
    # env var required" and the redirect captures an empty file — the
    # baseline silently lands at 0 ghosts regardless of project state.
    set -a
    # shellcheck source=/dev/null
    source .claude/hooks/project.conf
    set +a
    if [ "$LANG" = "python-rust" ]; then
        # Run each lang's checker with its ENTRY_POINTS_<lang> + SRC_GLOBS_<lang>;
        # prefix output with lang:. Also normalize file:line:symbol → file:symbol.
        TMP_BASE=$(mktemp)
        ENTRY_POINTS="${ENTRY_POINTS_python:-}" \
        SRC_GLOBS="${SRC_GLOBS_python:-${SRC_GLOBS:-}}" \
        TEST_EXCLUDES="${TEST_EXCLUDES_python:-${TEST_EXCLUDES:-}}" \
            bash .claude/hooks/lang/python.sh 2>/dev/null \
            | awk -F: -v OFS=: '{ sym=$3; for(i=4;i<=NF;i++) sym=sym":"$i; print "python:" $1 ":" sym }' \
            >> "$TMP_BASE" || true
        ENTRY_POINTS="${ENTRY_POINTS_rust:-}" \
        SRC_GLOBS="${SRC_GLOBS_rust:-${SRC_GLOBS:-}}" \
        TEST_EXCLUDES="${TEST_EXCLUDES_rust:-${TEST_EXCLUDES:-}}" \
            bash .claude/hooks/lang/rust.sh 2>/dev/null \
            | awk -F: -v OFS=: '{ sym=$3; for(i=4;i<=NF;i++) sym=sym":"$i; print "rust:" $1 ":" sym }' \
            >> "$TMP_BASE" || true
        sort -u "$TMP_BASE" > .claude/ghost-baseline.txt
        rm -f "$TMP_BASE"
    elif [ "$MULTI" = "1" ]; then
        # Auto-detect multi-lang: loop over LANGS_TO_INSTALL, run each
        # checker with its ENTRY_POINTS_<lang> + SRC_GLOBS_<lang>, prefix
        # output with lang: and normalize file:line:symbol → file:symbol.
        # `|| true` so a missing entry-point/toolchain never aborts install.
        TMP_BASE=$(mktemp)
        for L in $LANGS_TO_INSTALL; do
            EP_VAR="ENTRY_POINTS_${L}"
            SG_VAR="SRC_GLOBS_${L}"
            TE_VAR="TEST_EXCLUDES_${L}"
            ENTRY_POINTS="${!EP_VAR:-}" \
            SRC_GLOBS="${!SG_VAR:-${SRC_GLOBS:-}}" \
            TEST_EXCLUDES="${!TE_VAR:-${TEST_EXCLUDES:-}}" \
                bash ".claude/hooks/lang/$L.sh" 2>/dev/null \
                | awk -F: -v OFS=: -v lang="$L" '{ sym=$3; for(i=4;i<=NF;i++) sym=sym":"$i; print lang ":" $1 ":" sym }' \
                >> "$TMP_BASE" || true
        done
        sort -u "$TMP_BASE" > .claude/ghost-baseline.txt
        rm -f "$TMP_BASE"
    else
        # Single-lang: also normalize to file:symbol (matches integration-gate.sh format).
        # In auto-detect single mode LANG is empty, so derive the checker
        # name from LANGS_TO_INSTALL (which holds exactly one lang).
        SINGLE_LANG="${LANG:-$LANGS_TO_INSTALL}"
        bash ".claude/hooks/lang/$SINGLE_LANG.sh" 2>/dev/null \
            | awk -F: -v OFS=: '{ sym=$3; for(i=4;i<=NF;i++) sym=sym":"$i; print $1 ":" sym }' \
            > .claude/ghost-baseline.txt || true
    fi
    GHOST_COUNT=$(wc -l < .claude/ghost-baseline.txt | tr -d ' ')
    echo "  ✓ Captured ghost baseline ($GHOST_COUNT inherited symbols) at .claude/ghost-baseline.txt"
    if [ "$GHOST_COUNT" -gt 0 ]; then
        echo "     These symbols are accepted as-is. Review in PR to wire or delete over time."
    fi
else
    echo "  ⚠️  .claude/ghost-baseline.txt already exists — NOT overwriting."
fi

# 5. Append Definition of Done to CLAUDE.md
DOD_MARKER="## Definition of Done (no negociable)"
if [ -f "CLAUDE.md" ] && grep -q "$DOD_MARKER" CLAUDE.md; then
    echo "  ⚠️  CLAUDE.md already has Definition of Done — NOT appending."
else
    if [ ! -f "CLAUDE.md" ]; then
        echo "# CLAUDE.md" > CLAUDE.md
        echo "" >> CLAUDE.md
        echo "  ✓ Created CLAUDE.md"
    fi
    # Extract the block between begin/end markers from DoD source
    sed -n '/<!-- begin/,/<!-- end/p' "$SCRIPT_DIR/docs/DEFINITION_OF_DONE.md" | \
        sed '1d;$d' >> CLAUDE.md
    echo "  ✓ Appended Definition of Done to CLAUDE.md"
fi

# 5b. Provision AGENTS.md (guardrails for Codex/GPT agents, parallel to CLAUDE.md DoD).
AGENTS_MARKER="## Regla #-1"
if [ -f "AGENTS.md" ] && grep -q "$AGENTS_MARKER" AGENTS.md; then
    echo "  ⚠️  AGENTS.md already has guardrails content — NOT overwriting."
else
    if [ -f "AGENTS.md" ]; then
        echo "" >> AGENTS.md
        cat "$SCRIPT_DIR/AGENTS.md" >> AGENTS.md
        echo "  ✓ Appended guardrails content to existing AGENTS.md"
    else
        cp -f "$SCRIPT_DIR/AGENTS.md" AGENTS.md
        echo "  ✓ Created AGENTS.md from guardrails template"
    fi
fi

# 6. Install the verify-* skill family (declarative-with-evidence layer).
#    Complements the mechanical hooks by letting the agent self-audit with
#    real command output before claiming completion in five orthogonal
#    domains: contract drift, completion claims, error paths, identity keys,
#    and storage integrity. See guardrails/skills/*.md.
if [ -d "$SCRIPT_DIR/skills" ]; then
    mkdir -p .claude/skills
    for skill_path in "$SCRIPT_DIR"/skills/*.md; do
        [ -f "$skill_path" ] || continue
        skill_name=$(basename "$skill_path")
        if [ -f ".claude/skills/$skill_name" ]; then
            echo "  ⚠️  .claude/skills/$skill_name already exists — NOT overwriting."
        else
            cp -f "$skill_path" ".claude/skills/$skill_name"
            echo "  ✓ Installed skill .claude/skills/$skill_name"
        fi
    done
fi

echo ""
echo "✅ Installation complete."
echo ""
echo "Next steps:"
echo "  1. Verify .claude/hooks/project.conf (especially ENTRY_POINTS)"
echo "  2. git add .claude/ CLAUDE.md && git commit -m 'chore: integration gates'"
echo "  3. Restart Claude Code — SessionStart hook will report current ghost count"
echo ""
echo "Docs:"
echo "  - Problem + approach: guardrails/README.md"
echo "  - Real case study:    guardrails/docs/FAKE_WORK_AUDIT.md"
echo "  - Per-lang mechanism: guardrails/docs/LANG_MATRIX.md"
echo "  - Self-check skill:   guardrails/skills/verify-done.md (installed at .claude/skills/)"
