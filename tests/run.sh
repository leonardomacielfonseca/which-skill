#!/usr/bin/env bash
# Runs one which-skill scenario in a scratch project (the "lab").
#   tests/run.sh <scenario-id> "<prompt>" [claude args...]
#       run a scenario, output in tests/out/<id>.txt. Extra args go straight to
#       claude -p, e.g. --continue (second turn of the previous lab run) or
#       --disallowedTools WebSearch,WebFetch
#   tests/run.sh --jsonl <scenario-id> "<prompt>" [claude args...]
#       same, and also saves the full stream-json transcript (every tool call)
#       in tests/out/<id>.jsonl, for tests/audit-commands.py
#   tests/run.sh --setup                    only (re)create the lab and copy the skill
#   tests/run.sh --reset                    wipe the lab (index and dummy skills included)
#   tests/run.sh --path                     print the lab path
# The lab is a private per-user folder, ${TMPDIR:-/tmp}/which-skill-lab-<uid>,
# created with mode 700. Before anything is deleted or written, it must be a
# real directory (not a symlink, no symlink in its resolved path), owned by the
# current user, and must not overlap the real ~/.claude (or $CLAUDE_CONFIG_DIR)
# in either direction
# (~/.claude itself is resolved physically, so a symlinked ~/.claude counts);
# otherwise the script refuses. The overlap is checked again right before
# every rm -rf.
# The lab index is $LAB/index.md, set through WHICH_SKILL_INDEX. The real
# ~/.claude/which-skill/ (or $CLAUDE_CONFIG_DIR/which-skill/) is never written.
# tests/out holds transcripts with tool results, so it is private: the script
# runs under umask 077, keeps tests/out at 0700 (refusing a symlinked folder,
# one owned by someone else, or one with a symlink in its path), and refuses an
# output file that is a symlink, not a regular file or not the user's, before
# anything is written; outputs end 0600. tests/test-run-out.sh checks this.
set -euo pipefail
umask 077
refuse() { echo "refusing: $*" >&2; exit 3; }

# Every path that is later removed or written is derived from SKILL_DIR, BASE
# and UID_NOW, so each one is validated here: an empty or relative value would
# turn "$LAB" or "$OUT_DIR" into a path under /.
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd -P)" || refuse "cannot resolve the skill folder"
case "$SKILL_DIR" in /?*) ;; *) refuse "bad skill folder '$SKILL_DIR'";; esac
OUT_DIR="$SKILL_DIR/tests/out"
UID_NOW="$(id -u)" || refuse "id -u failed"
case "$UID_NOW" in ''|*[!0-9]*) refuse "bad uid '$UID_NOW'";; esac

# Resolve the temp base physically (on macOS /var is a symlink to /private/var),
# so the only path component left to check is the lab folder itself.
BASE="${TMPDIR:-/tmp}"
BASE="$(cd -P "$BASE" 2>/dev/null && pwd -P)" || refuse "temp folder ${TMPDIR:-/tmp} not found"
case "$BASE" in /*) ;; *) refuse "temp folder resolved to a non-absolute path '$BASE'";; esac
LAB="${BASE%/}/which-skill-lab-$UID_NOW"
INDEX="$LAB/index.md"
# The real ~/.claude, resolved physically: if ~/.claude exists (or is a
# symlink, even a dangling one) it must resolve, and its target is what counts.
real_claude() {
  if [ -e "$HOME/.claude" ] || [ -L "$HOME/.claude" ]; then
    (cd -P "$HOME/.claude" 2>/dev/null && pwd -P) || refuse "cannot resolve $HOME/.claude"
  else
    h="$(cd -P "$HOME" 2>/dev/null && pwd -P)" || refuse "cannot resolve HOME $HOME"
    echo "${h%/}/.claude"
  fi
}

# Never the real ~/.claude, in either direction: the lab may not sit inside
# it, and it may not sit inside the lab. Run before setup and before every rm.
# A CLAUDE_CONFIG_DIR, if set, is a real config folder too (the skill's
# default index lives under it), resolved physically when it exists.
real_config() {
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] || return 0
  if [ -e "$CLAUDE_CONFIG_DIR" ] || [ -L "$CLAUDE_CONFIG_DIR" ]; then
    (cd -P "$CLAUDE_CONFIG_DIR" 2>/dev/null && pwd -P) || refuse "cannot resolve CLAUDE_CONFIG_DIR $CLAUDE_CONFIG_DIR"
  else
    echo "$CLAUDE_CONFIG_DIR"
  fi
}

check_overlap() {
  rc="$(real_claude)" || exit 3
  [ -n "$rc" ] || refuse "empty ~/.claude path"
  cc="$(real_config)" || exit 3
  for c in "$HOME/.claude" "$rc" ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR"} ${cc:+"$cc"}; do
    case "$LAB/" in "${c%/}/"*) refuse "lab inside a config folder ($c): $LAB";; esac
    case "${c%/}/" in "$LAB/"*) refuse "config folder ($c) inside the lab: $LAB";; esac
  done
  if [ -e "$LAB" ]; then
    lr="$(cd -P "$LAB" 2>/dev/null && pwd -P)" || refuse "cannot resolve $LAB"
    for c in "$rc" ${cc:+"$cc"}; do
      case "$lr/" in "${c%/}/"*) refuse "lab resolves inside a config folder ($c): $lr";; esac
      case "${c%/}/" in "$lr/"*) refuse "config folder ($c) resolves inside the lab: $lr";; esac
    done
  fi
}
check_overlap

owner_of() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }

# Validates an existing lab. Exits on any doubt.
check_lab() {
  [ -L "$LAB" ] && refuse "$LAB is a symlink"
  [ -d "$LAB" ] || refuse "$LAB is not a directory"
  [ "$(owner_of "$LAB")" = "$UID_NOW" ] || refuse "$LAB is not owned by uid $UID_NOW"
  real="$(cd -P "$LAB" && pwd -P)"
  [ "$real" = "$LAB" ] || refuse "$LAB resolves to $real (symlink in the path)"
  check_overlap
  for sub in "$LAB/.claude" "$LAB/.claude/skills" "$LAB/.claude/skills/which-skill" "$INDEX"; do
    [ -L "$sub" ] && refuse "$sub is a symlink"
  done
  chmod 700 "$LAB"
}

# Creates the lab privately if missing (mkdir is atomic and never follows a
# symlink planted at the final component), then validates it.
ensure_lab() {
  if [ ! -e "$LAB" ] && [ ! -L "$LAB" ]; then
    (umask 077 && mkdir -m 700 "$LAB") || refuse "could not create $LAB"
  fi
  check_lab
}

if [ "${1:-}" = "--path" ]; then echo "$LAB"; exit 0; fi

if [ "${1:-}" = "--reset" ]; then
  if [ -e "$LAB" ] || [ -L "$LAB" ]; then check_lab; check_overlap; rm -rf "$LAB"; fi
  echo "lab wiped: $LAB"; exit 0
fi

setup_lab() {
  ensure_lab
  mkdir -p "$LAB/.claude/skills"
  check_lab
  # Always re-copy the skill source so edits are picked up; keep index and dummies.
  check_overlap
  rm -rf "$LAB/.claude/skills/which-skill"
  mkdir -p "$LAB/.claude/skills/which-skill"
  (cd "$SKILL_DIR" && tar --exclude='./tests' -cf - .) | (cd "$LAB/.claude/skills/which-skill" && tar -xf -)
}

if [ "${1:-}" = "--setup" ]; then setup_lab; echo "lab ready: $LAB"; exit 0; fi

JSONL=0
if [ "${1:-}" = "--jsonl" ]; then JSONL=1; shift; fi
if [ $# -lt 2 ]; then echo "usage: $0 [--jsonl] <scenario-id> \"<prompt>\" [claude args...] | --setup | --reset | --path" >&2; exit 2; fi
ID="$1"; PROMPT="$2"; shift 2
case "$ID" in ''|-*|*[!A-Za-z0-9._-]*) refuse "scenario id must match [A-Za-z0-9._-]+ and not start with '-': $ID";; esac
# tests/out and the output files: checked before anything is written.
ensure_out() {
  [ -L "$OUT_DIR" ] && refuse "$OUT_DIR is a symlink"
  if [ ! -e "$OUT_DIR" ]; then mkdir -m 700 "$OUT_DIR" || refuse "could not create $OUT_DIR"; fi
  [ -d "$OUT_DIR" ] || refuse "$OUT_DIR is not a directory"
  [ "$(owner_of "$OUT_DIR")" = "$UID_NOW" ] || refuse "$OUT_DIR is not owned by uid $UID_NOW"
  [ "$(cd -P "$OUT_DIR" && pwd -P)" = "$OUT_DIR" ] || refuse "$OUT_DIR has a symlink in its path"
  chmod 700 "$OUT_DIR"
}
safe_out() {
  for f in "$@"; do
    if [ -L "$f" ]; then refuse "$f is a symlink"; fi
    if [ -e "$f" ]; then
      [ -f "$f" ] || refuse "$f is not a regular file"
      [ "$(owner_of "$f")" = "$UID_NOW" ] || refuse "$f is not owned by uid $UID_NOW"
      chmod 600 "$f"
    fi
  done
}
ensure_out
if [ "$JSONL" = 1 ]; then safe_out "$OUT_DIR/$ID.txt" "$OUT_DIR/$ID.jsonl"; else safe_out "$OUT_DIR/$ID.txt"; fi
setup_lab
cd "$LAB"
echo "== $ID @ $(date '+%Y-%m-%d %H:%M:%S') lab=$LAB" > "$OUT_DIR/$ID.txt"
if [ "$JSONL" = 1 ]; then
  # Full transcript (every tool call) in <id>.jsonl; the final answer text is
  # still appended to <id>.txt. Audit it with tests/audit-commands.py.
  : > "$OUT_DIR/$ID.jsonl"
  WHICH_SKILL_INDEX="$INDEX" claude -p "$PROMPT" --permission-mode acceptEdits \
    --allowedTools "Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch" \
    --output-format stream-json --verbose "$@" < /dev/null > "$OUT_DIR/$ID.jsonl" 2>> "$OUT_DIR/$ID.txt" || echo "(claude exited $?)" >> "$OUT_DIR/$ID.txt"
  python3 -I -c 'import json,sys
r=""
for line in open(sys.argv[1], encoding="utf-8"):
    try: d=json.loads(line)
    except ValueError: continue
    if isinstance(d,dict) and d.get("type")=="result": r=d.get("result") or ""
print(r)' "$OUT_DIR/$ID.jsonl" >> "$OUT_DIR/$ID.txt"
  echo "transcript: $OUT_DIR/$ID.jsonl"
else
  WHICH_SKILL_INDEX="$INDEX" claude -p "$PROMPT" --permission-mode acceptEdits \
    --allowedTools "Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch" "$@" < /dev/null >> "$OUT_DIR/$ID.txt" 2>&1 || echo "(claude exited $?)" >> "$OUT_DIR/$ID.txt"
fi
echo "output: $OUT_DIR/$ID.txt"
