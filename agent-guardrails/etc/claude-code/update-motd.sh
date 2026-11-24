#!/bin/bash
# Rewrites companyAnnouncements in /etc/claude-code/managed-settings.json
# with the cluster guardrail notice and a randomly chosen sci-fi quote.
# Site branding can be customized via /etc/claude-code/site-banner.env:
#   BANNER_TITLE="CLUSTER"
#   BANNER_SUBTITLE="Claude Code · Digital Research Alliance of Canada"
#   BANNER_FOOTER="Docs: docs.alliancecan.ca · Support: support@tech.alliancecan.ca"

set -euo pipefail

SETTINGS=/etc/claude-code/managed-settings.json
[ -f "$SETTINGS" ] || exit 0

BANNER_TITLE="ALLIANCE HPC"
BANNER_SUBTITLE="Claude Code · Login Pod Guardrails · Digital Research Alliance of Canada"
BANNER_FOOTER="Docs: docs.alliancecan.ca · Support: support@tech.alliancecan.ca"

if [ -f /etc/claude-code/site-banner.env ]; then
  # shellcheck disable=SC1091
  . /etc/claude-code/site-banner.env
fi

TMPFILE=$(mktemp)

messages=(
  "Greetings, Professor Falken. Would you like to play a game?"
  "Good morning, Dave. I am completely operational and all my circuits are functioning perfectly."
  "I'm sorry Dave, I'm afraid I can't do that."
  "All of this has happened before, and all of it will happen again."
  "By your command."
  "The Belt remembers."
  "Do or do not. There is no try."
  "I find your lack of faith disturbing."
  "These aren't the droids you're looking for."
  "Don't Panic."
  "A towel is about the most massively useful thing an interstellar hitchhiker can have."
  "In the beginning the Universe was created. This has made a lot of people very angry and been widely regarded as a bad move."
  "Your culture will adapt to service us."
  "Number 5 is alive."
  "Danger, Will Robinson!"
  "Please state the nature of the medical emergency."
  "The spice must flow."
  "There is no spoon."
  "Follow the white rabbit."
  "I'll be back."
  "Come with me if you want to live."
  "The truth is out there."
  "I fight for the users."
  "Good news, everyone!"
  "Might I suggest something less destructive?"
  "At your service, sir."
  "Great Scott!"
  "Never tell me the odds."
  "Can't stop the signal."
  "No power in the 'verse can stop me."
  "Ziggy says there's a 97.2 percent probability."
  "Sometimes you gotta run before you can walk."
)

quote="${messages[$RANDOM % ${#messages[@]}]}"

QUOTE="$quote" TMPFILE="$TMPFILE" \
BANNER_TITLE="$BANNER_TITLE" BANNER_SUBTITLE="$BANNER_SUBTITLE" BANNER_FOOTER="$BANNER_FOOTER" \
python3 - << 'PYEOF'
import json, os

settings_path = '/etc/claude-code/managed-settings.json'
tmp_path = os.environ['TMPFILE']
quote = os.environ['QUOTE']
title = os.environ['BANNER_TITLE']
subtitle = os.environ['BANNER_SUBTITLE']
footer = os.environ['BANNER_FOOTER']

R = "\x1b[0m"
B = "\x1b[1m"
D = "\x1b[2m"
I = "\x1b[3m"
CYAN = "\x1b[36m"
YELLOW = "\x1b[33m"
MAGENTA = "\x1b[35m"

banner = [
    f"{B}{CYAN}{title}{R}  {D}{subtitle}{R}",
    "",
    f"{B}{YELLOW}You are inside a shared cluster login pod, not a personal workstation.{R} Site-managed settings, skills, and guardrails are active here. Everything the agent runs executes under your account and remains your responsibility.",
    "",
    f"{B}{YELLOW}What we expect of you:{R}",
    f"{B}Review every command{R} the agent proposes before approving it.",
    f"{B}Keep compute out of the login pod.{R} Submit heavy work through Slurm (sbatch/salloc), never inside the login pod, and never run agents on robot.* automation nodes.",
    f"{B}Protect your data.{R} Prompts, files, and command output may leave the cluster to the AI provider. Keep credentials, PII, and restricted or unpublished research data out unless authorized.",
    f"{B}Respect other users.{R} Stay out of other users' /home, /scratch, and /project directories. Do not enumerate accounts.",
    f"{B}Mind your storage.{R} Job I/O belongs on $SCRATCH, not $HOME.",
    "",
    f"{D}{footer}{R}",
    "",
    f"{I}{MAGENTA}{quote}{R}",
]

with open(settings_path) as f:
    settings = json.load(f)

settings['companyAnnouncements'] = ["\n".join(banner)]

with open(tmp_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

mv "$TMPFILE" "$SETTINGS"
chmod 644 "$SETTINGS"
chown root:root "$SETTINGS"
