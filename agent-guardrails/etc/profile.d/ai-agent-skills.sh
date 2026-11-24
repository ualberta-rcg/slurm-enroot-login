# Central AI-agent skills & guardrails profile hook (/etc/profile.d/ai-agent-skills.sh)
#
# Skipped automatically inside robot.* automation sessions (Alliance policy
# prohibits AI coding agents on MFA automation nodes) and when guardrails are
# explicitly disabled by site configuration.
if [ "${LOGIN_SESSION_MODE:-}" = "robot" ] || [ "${LOGIN_GUARDRAILS_ENABLED:-1}" = "0" ]; then
  return 0 2>/dev/null || exit 0
fi

export AGY_CLI_DISABLE_AUTO_UPDATE=true

SKILLS_SRC=/etc/claude-code/.claude/skills
if [ -d "$SKILLS_SRC" ] && [ -n "${HOME:-}" ] && [ -w "$HOME" ]; then
  for d in \
    "$HOME/.agents/skills" \
    "$HOME/.codex/skills" \
    "$HOME/.cursor/skills" \
    "$HOME/.gemini/antigravity-cli/skills" \
    "$HOME/.pi/agent/skills"; do
    mkdir -p "$d" 2>/dev/null
    for s in "$SKILLS_SRC"/*/; do
      [ -d "$s" ] || continue
      n=$(basename "$s")
      [ -e "$d/$n" ] || ln -s "$s" "$d/$n" 2>/dev/null
    done
  done
fi
unset SKILLS_SRC

# Shared instructions file for Codex, Gemini/Antigravity, and Pi.
# Claude reads /etc/claude-code/CLAUDE.md; OpenCode reads /etc/agents/AGENTS.md.
if [ -f /etc/agents/AGENTS.md ] && [ -n "${HOME:-}" ] && [ -w "$HOME" ]; then
  for d in "$HOME/.codex" "$HOME/.gemini" "$HOME/.pi/agent"; do
    mkdir -p "$d" 2>/dev/null
    [ -e "$d/AGENTS.md" ] || ln -s /etc/agents/AGENTS.md "$d/AGENTS.md" 2>/dev/null
  done
fi

# Pi coding agent guardrails extension
if [ -f /etc/pi/extensions/hpc-guardrails.ts ] && [ -n "${HOME:-}" ] && [ -w "$HOME" ]; then
  mkdir -p "$HOME/.pi/agent/extensions" 2>/dev/null
  [ -e "$HOME/.pi/agent/extensions/hpc-guardrails.ts" ] || \
    ln -s /etc/pi/extensions/hpc-guardrails.ts "$HOME/.pi/agent/extensions/hpc-guardrails.ts" 2>/dev/null
fi
