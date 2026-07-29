#!/bin/sh
# SessionStart hook: warns once at session start if betterleaks-guard's
# required tools are missing, instead of only ever surfacing that as a
# failed/blocked file read later. Never blocks startup, and deliberately
# avoids depending on jq (that's one of the things it's checking for), so
# the JSON output is built by hand.
set -eu

missing=""

command -v betterleaks >/dev/null 2>&1 || missing="$missing betterleaks"
command -v jq >/dev/null 2>&1 || missing="$missing jq"

os=$(uname -s)
case "$os" in
  Darwin)
    command -v sandbox-exec >/dev/null 2>&1 || missing="$missing sandbox-exec"
    ;;
  Linux)
    command -v bwrap >/dev/null 2>&1 || missing="$missing bwrap(bubblewrap)"
    ;;
esac

[ -n "$missing" ] || exit 0

case "$os" in
  Darwin)
    hint="Install with: brew install betterleaks jq"
    ;;
  Linux)
    hint="Install jq and bubblewrap with your package manager (e.g. sudo apt install jq bubblewrap, or sudo dnf install jq bubblewrap). Install betterleaks via Homebrew (brew install betterleaks) or from https://github.com/betterleaks/betterleaks/releases"
    ;;
  *)
    hint="Install betterleaks, jq, and an OS-appropriate sandboxing tool."
    ;;
esac

msg="betterleaks-guard: missing required tool(s):$missing. Until installed, this plugin fails closed and blocks all file reads. $hint"
msg_escaped=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"systemMessage":"%s"}\n' "$msg_escaped"
