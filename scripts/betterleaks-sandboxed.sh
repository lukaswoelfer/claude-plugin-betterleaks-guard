#!/bin/sh
# Runs betterleaks confined to a network-free sandbox, restricted to reading
# only the given path. Uses Seatbelt (sandbox-exec) on macOS and Bubblewrap
# (bwrap) on Linux.
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

    # Resolve symlinks by hand: macOS's BSD readlink has no -f. We need both
    # the directory betterleaks was found in on PATH, and the directory its
    # symlink chain resolves to (e.g. Homebrew's bin/ symlink into its
    # Cellar keg), since the sandbox profile has to allow reading both.
    resolved="$BETTERLEAKS_BIN"
    while [ -L "$resolved" ]; do
      link=$(readlink "$resolved")
      case "$link" in
        /*) resolved="$link" ;;
        *) resolved="$(dirname "$resolved")/$link" ;;
      esac
    done
    BETTERLEAKS_LINK_DIR=$(cd "$(dirname "$BETTERLEAKS_BIN")" && pwd -P)
    BETTERLEAKS_REAL_DIR=$(cd "$(dirname "$resolved")" && pwd -P)

    exec sandbox-exec \
      -D SCAN_PATH="$SCAN_PATH" \
      -D HOME="$HOME" \
      -D BETTERLEAKS_LINK_DIR="$BETTERLEAKS_LINK_DIR" \
      -D BETTERLEAKS_REAL_DIR="$BETTERLEAKS_REAL_DIR" \
      -f "$PROFILE_DIR/betterleaks.sb" \
      "$BETTERLEAKS_BIN" dir --no-banner --redact -f json -r - "$SCAN_PATH" "$@"
    ;;

  Linux)
    if ! command -v bwrap >/dev/null 2>&1; then
      echo "betterleaks-sandboxed.sh: 'bwrap' (bubblewrap) not found; install it via your package manager (e.g. 'sudo apt install bubblewrap' or 'sudo dnf install bubblewrap')." >&2
      exit 127
    fi

    BETTERLEAKS_REAL_BIN=$(readlink -f "$BETTERLEAKS_BIN")
    BETTERLEAKS_LINK_DIR=$(cd "$(dirname "$BETTERLEAKS_BIN")" && pwd -P)
    BETTERLEAKS_REAL_DIR=$(cd "$(dirname "$BETTERLEAKS_REAL_BIN")" && pwd -P)

    CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/com.github.wasilibs"
    mkdir -p "$CACHE_DIR" 2>/dev/null || true

    # Deny-by-default via a fresh mount namespace: nothing but what's
    # explicitly bound below is visible inside the sandbox. --unshare-net
    # drops all network access, mirroring the Seatbelt profile's
    # (deny network*). *-try variants are skipped if the source doesn't
    # exist, so this works whether or not betterleaks is dynamically linked.
    exec bwrap \
      --unshare-net --unshare-pid --unshare-ipc --unshare-uts \
      --die-with-parent --new-session \
      --proc /proc --dev /dev --tmpfs /tmp \
      --setenv TMPDIR /tmp \
      --ro-bind-try /usr /usr \
      --ro-bind-try /lib /lib \
      --ro-bind-try /lib64 /lib64 \
      --ro-bind-try /bin /bin \
      --ro-bind-try /sbin /sbin \
      --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache \
      --ro-bind-try /etc/ld.so.conf /etc/ld.so.conf \
      --ro-bind-try /etc/ld.so.conf.d /etc/ld.so.conf.d \
      --ro-bind "$BETTERLEAKS_LINK_DIR" "$BETTERLEAKS_LINK_DIR" \
      --ro-bind-try "$BETTERLEAKS_REAL_DIR" "$BETTERLEAKS_REAL_DIR" \
      --bind "$CACHE_DIR" "$CACHE_DIR" \
      --ro-bind "$SCAN_PATH" "$SCAN_PATH" \
      -- "$BETTERLEAKS_BIN" dir --no-banner --redact -f json -r - "$SCAN_PATH" "$@"
    ;;

  *)
    echo "betterleaks-sandboxed.sh: unsupported OS '$OS' (only Darwin and Linux are supported); failing closed." >&2
    exit 1
    ;;
esac
