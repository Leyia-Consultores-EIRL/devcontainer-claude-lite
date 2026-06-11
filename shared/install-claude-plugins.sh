#!/usr/bin/env bash
# Canonical Claude Code plugin set for all devcontainer variants.
# Source this from post-start.sh — never copy this list elsewhere.
#
# Variant-specific extras (define EXTRA_PLUGINS before sourcing if needed):
#   kotlin-android: EXTRA_PLUGINS=(kotlin-lsp)  # add when that variant is created

CANONICAL_PLUGINS=(
  code-review
  code-simplifier
  security-guidance
  serena
  typescript-lsp
  playwright
  github
  commit-commands
  feature-dev
  superpowers
  context7
  frontend-design
  claude-md-management
  hookify
  ralph-loop
)

# Variants may append extras before sourcing this file:
#   EXTRA_PLUGINS=(kotlin-lsp)
# Default: empty.
EXTRA_PLUGINS=("${EXTRA_PLUGINS[@]+"${EXTRA_PLUGINS[@]}"}")

_all_plugins() {
  echo "${CANONICAL_PLUGINS[@]}" "${EXTRA_PLUGINS[@]+"${EXTRA_PLUGINS[@]}"}"
}

# Write enabledPlugins into ~/.claude/settings.json (idempotent).
# Uses jq when available; writes fresh file otherwise.
# Never clobbers existing keys other than enabledPlugins.
ensure_claude_plugins_settings() {
  local settings="${HOME}/.claude/settings.json"
  local plugins
  read -ra plugins <<< "$(_all_plugins)"

  # Build JSON array
  local arr='['
  local first=1
  for p in "${plugins[@]}"; do
    [ $first -eq 0 ] && arr+=','
    arr+="\"${p}@claude-plugins-official\""
    first=0
  done
  arr+=']'

  mkdir -p "$(dirname "$settings")"

  if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp)
    if jq --argjson ep "$arr" '. + {enabledPlugins: $ep}' "$settings" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$settings"
    else
      rm -f "$tmp"
      echo "[plugins] WARN: jq merge failed — enabledPlugins not written"
    fi
  elif [ ! -f "$settings" ]; then
    printf '{\n  "enabledPlugins": %s\n}\n' "$arr" > "$settings"
  fi
  # If file exists without jq: plugins install via install_claude_plugins(), settings left as-is
}

# Idempotent: installs only missing plugins (checks ~/.claude/plugins/cache/<name>).
# Warns and continues on failure — never blocks container start.
install_claude_plugins() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "[plugins] claude CLI not found — skipping plugin install"
    return
  fi

  local cache_dir="${HOME}/.claude/plugins/cache"
  local plugins
  read -ra plugins <<< "$(_all_plugins)"

  for plugin in "${plugins[@]}"; do
    if [ ! -d "${cache_dir}/${plugin}" ]; then
      echo "[plugins] Installing ${plugin}@claude-plugins-official..."
      claude plugin install "${plugin}@claude-plugins-official" 2>&1 || \
        echo "[plugins] WARN: failed to install ${plugin} — continuing"
    fi
  done
}
