#!/bin/sh
# PreToolUse hook for the "Read" tool: before Claude reads a file, scan it
# with betterleaks inside a network-free sandbox (see betterleaks.sb) and
# deny the read if a secret is found.
#
# Reads the Claude Code PreToolUse JSON payload from stdin and writes a
# PreToolUse hookSpecificOutput decision to stdout.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
WRAPPER="$SCRIPT_DIR/betterleaks-sandboxed.sh"

input=$(cat)

# We can't use jq to report that jq itself is missing, so build this one
# deny decision by hand.
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"betterleaks-guard: jq is required but not installed; failing closed on all reads until it is installed (e.g. brew install jq, apt install jq, dnf install jq)."}}'
  exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

allow() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
}

deny() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

# Nothing to scan (e.g. a Read for a path that doesn't exist yet) - let
# Claude's own tool handling surface the real error.
[ -n "$file_path" ] || allow
[ -f "$file_path" ] || allow

ignore_args=""
if [ -n "$cwd" ] && [ -f "$cwd/.claude/betterleaks-ignore" ]; then
  ignore_args="$ignore_args --ignore-file $cwd/.claude/betterleaks-ignore"
fi
if [ -f "$HOME/.claude/betterleaks-ignore" ]; then
  ignore_args="$ignore_args --ignore-file $HOME/.claude/betterleaks-ignore"
fi

stderr_file=$(mktemp)
trap 'rm -f "$stderr_file"' EXIT

set +e
report=$("$WRAPPER" $ignore_args "$file_path" 2>"$stderr_file")
status=$?
set -e

stderr_output=$(cat "$stderr_file")

# betterleaks itself only ever emits `null` (no leaks, exit 0) or a JSON
# array of finding objects (leaks found, exit 1). Exit 1 can also come from
# the wrapper/sandbox/toolchain failing before betterleaks ever ran (e.g. a
# mise shim that can't resolve inside the sandbox) - that collides with
# betterleaks' own "leaks found" exit code, so exit status alone can't tell
# the two apart. Only trust "leaks found" when stdout is actually a
# non-empty JSON array of findings; anything else is an infra failure, not
# a confirmed secret.
has_findings() {
  printf '%s' "$1" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1
}

fail_reason() {
  reason="$1"
  if [ -n "$stderr_output" ]; then
    excerpt=$(printf '%s' "$stderr_output" | tr '\n' ' ' | cut -c1-500)
    reason="$reason Error output: $excerpt"
  fi
  printf '%s' "$reason"
}

case "$status" in
  0)
    allow
    ;;
  1)
    if has_findings "$report"; then
      findings=$(printf '%s' "$report" | jq -r '[.[] | "\(.RuleID) (line \(.StartLine))"] | join(", ")')
      deny "betterleaks found a likely secret in $file_path: $findings. Reading this file has been blocked; add it to .claude/betterleaks-ignore if this is a known-safe fixture."
    else
      deny "$(fail_reason "betterleaks-guard: the scan of $file_path did not complete (betterleaks-sandboxed.sh exited 1 without reporting findings), so this is NOT a confirmed secret. Failing closed as a precaution - reading is blocked only because the check itself could not run.")"
    fi
    ;;
  *)
    deny "$(fail_reason "betterleaks-guard: betterleaks-sandboxed.sh failed to run (exit $status) while checking $file_path, so this is NOT a confirmed secret. Failing closed as a precaution. Check that betterleaks and the sandboxing tool (sandbox-exec on macOS, bwrap on Linux) are installed and on PATH.")"
    ;;
esac
