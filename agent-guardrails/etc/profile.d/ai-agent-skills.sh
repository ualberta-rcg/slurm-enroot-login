# Central AI-agent skills & guardrails profile hook (/etc/profile.d/ai-agent-skills.sh)
#
# Skipped automatically inside robot.* automation sessions (Alliance policy
# prohibits AI coding agents on MFA automation nodes).
if [ "${LOGIN_SESSION_MODE:-}" = "robot" ]; then
  return 0 2>/dev/null || exit 0
fi

export DISABLE_AUTOUPDATER=1
export AGY_CLI_DISABLE_AUTO_UPDATE=true

if [ -x /usr/local/bin/agent-guardrails ]; then
  if [ "${LOGIN_SESSION_MODE:-}" = "admin" ] && [ "${LOGIN_GUARDRAILS_ENABLED:-0}" = "0" ]; then
    /usr/local/bin/agent-guardrails link --admin >/dev/null 2>&1 || true
  elif [ "${LOGIN_GUARDRAILS_ENABLED:-1}" != "0" ]; then
    /usr/local/bin/agent-guardrails link >/dev/null 2>&1 || true
  fi
fi
