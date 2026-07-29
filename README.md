# betterleaks-guard

A Claude Code plugin that scans every file Claude reads with
[`betterleaks`](https://github.com/betterleaks/betterleaks) before the read
happens, and blocks it if the file looks like it contains a secret
(API keys, tokens, private keys, etc).

The scan itself runs fully offline inside an OS sandbox (Seatbelt on macOS,
Bubblewrap on Linux) with no network access, restricted to reading only the
one file being scanned — so this cannot exfiltrate file contents anywhere,
even if `betterleaks`' own `--validation` flag would normally try to call out
to a live provider API.

## How it works

- A `PreToolUse` hook (`scripts/betterleaks-check.sh`) intercepts every
  `Read` tool call.
- It runs `betterleaks` against the target file inside a sandboxed wrapper
  (`scripts/betterleaks-sandboxed.sh`).
- If `betterleaks` finds a likely secret, the read is denied with an
  explanation. Otherwise, Claude reads the file as normal.
- A `SessionStart` hook (`scripts/check-dependencies.sh`) checks once per
  session that the required tools below are installed, and posts a warning
  if something's missing — reads still fail closed (are blocked) in the
  meantime.

## Requirements

| Tool | macOS | Linux |
| --- | --- | --- |
| [`betterleaks`](https://github.com/betterleaks/betterleaks) | `brew install betterleaks` | `brew install betterleaks`, or download a release from the [betterleaks releases page](https://github.com/betterleaks/betterleaks/releases) |
| `jq` | `brew install jq` | `sudo apt install jq` / `sudo dnf install jq` |
| sandboxing tool | `sandbox-exec` (built into macOS, nothing to install) | `bwrap` — `sudo apt install bubblewrap` / `sudo dnf install bubblewrap` |

All three must be resolvable on `PATH`. There is no automatic installer —
Claude Code plugins can't declare or install system package dependencies, so
this plugin checks for them at session start and before every scan, and
fails closed (blocks reads) with a clear message if any are missing.

Only macOS and Linux are supported.

## Ignoring known-safe files

Some files trip secret-detection rules but aren't actually secrets (test
fixtures, documentation examples, etc). To exempt a file, add a glob pattern
to an ignore file — one pattern per line, `#` comments and blank lines
allowed, matched against both the file's absolute path and its basename:

- `.claude/betterleaks-ignore` in the project — for patterns specific to
  that repo.
- `~/.claude/betterleaks-ignore` — for patterns you want applied everywhere.

Files matching an ignore pattern are never even opened for scanning.

## Security notes

- The sandbox denies network access outright and only grants read access to
  the specific file being scanned (plus whatever the `betterleaks` binary
  itself and the Go/wazero runtime need to start up) — nothing else on disk
  is exposed to the scan process.
- If the sandboxing tool, `betterleaks`, or `jq` can't be found or fails to
  run, the hook denies the read rather than allowing it through unscanned
  (fail closed).
