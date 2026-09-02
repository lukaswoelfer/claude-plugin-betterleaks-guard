#!/bin/sh
# Runs betterleaks with no network access, otherwise unsandboxed. Uses
# Seatbelt (sandbox-exec) on macOS and Bubblewrap (bwrap) on Linux, both
# configured to isolate network only - not the filesystem, not anything
# else. That keeps this wrapper agnostic to however `betterleaks` resolves
# on PATH (plain binary, Homebrew symlink, a version manager shim, ...):
# there is nothing here that needs to know or care.
#
# Usage: betterleaks-sandboxed.sh [--ignore-file <file>]... <path-to-scan>
#
# --ignore-file may be given multiple times (e.g. a project-level and a
# user-level list). Each is a plain text file, one glob pattern per line,
# '#' comments and blank lines allowed. A path matching any pattern (against
# either its absolute form or its basename) is treated as pre-cleared and
# never even gets opened, let alone sandboxed/scanned.
set -eu

ignore_files=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ignore-file)
      [ "$#" -ge 2 ] || { echo "--ignore-file requires a value" >&2; exit 64; }
      ignore_files="$ignore_files $2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -lt 1 ]; then
  echo "usage: $0 [--ignore-file <file>]... <path-to-scan> [extra betterleaks args...]" >&2
  exit 64
fi

SCAN_PATH=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
shift

is_ignored() {
  path="$1"
  base=$(basename "$path")
  for ignore_file in $ignore_files; do
    [ -f "$ignore_file" ] || continue
    while IFS= read -r pattern || [ -n "$pattern" ]; do
      case "$pattern" in
        ''|'#'*) continue ;;
      esac
      case "$path" in $pattern) return 0 ;; esac
      case "$base" in $pattern) return 0 ;; esac
    done < "$ignore_file"
  done
  return 1
}

if [ -n "$ignore_files" ] && is_ignored "$SCAN_PATH"; then
  # Pre-cleared by an ignore list: report the same shape betterleaks itself
  # uses for "no leaks found", without ever reading the file's contents.
  echo "null"
  exit 0
fi

PROFILE_DIR=$(cd "$(dirname "$0")" && pwd -P)

BETTERLEAKS_BIN=$(command -v betterleaks 2>/dev/null || true)
if [ -z "$BETTERLEAKS_BIN" ]; then
  echo "betterleaks-sandboxed.sh: 'betterleaks' not found on PATH. Install it (e.g. 'brew install betterleaks') and ensure it is on PATH." >&2
  exit 127
fi

OS=$(uname -s)

case "$OS" in
  Darwin)
    if ! command -v sandbox-exec >/dev/null 2>&1; then
      echo "betterleaks-sandboxed.sh: 'sandbox-exec' not found; this is a built-in macOS tool and should always be present." >&2
      exit 127
    fi

    exec sandbox-exec -f "$PROFILE_DIR/betterleaks.sb" \
      "$BETTERLEAKS_BIN" dir --no-banner --redact -f json -r - "$SCAN_PATH" "$@"
    ;;

  Linux)
    if ! command -v bwrap >/dev/null 2>&1; then
      echo "betterleaks-sandboxed.sh: 'bwrap' (bubblewrap) not found; install it via your package manager (e.g. 'sudo apt install bubblewrap' or 'sudo dnf install bubblewrap')." >&2
      exit 127
    fi

    # --dev-bind / / gives the sandboxed process the real filesystem,
    # unrestricted (this only isolates network, see betterleaks.sb's
    # comment for why). --unshare-net drops all network access.
    exec bwrap \
      --unshare-net \
      --die-with-parent --new-session \
      --dev-bind / / \
      -- "$BETTERLEAKS_BIN" dir --no-banner --redact -f json -r - "$SCAN_PATH" "$@"
    ;;

  *)
    echo "betterleaks-sandboxed.sh: unsupported OS '$OS' (only Darwin and Linux are supported); failing closed." >&2
    exit 1
    ;;
esac
