#!/usr/bin/env bash
# Sandbox simulation of two sessions racing on the index (no claude run).
# Runs the command blocks copied verbatim from references/index.md (discovery,
# lock acquire, ownership check, release) inside a private temp HOME:
#   1. A runs discovery before the lock: CHANGED card v1 -> now v2.
#   2. B holds the lock; A starts waiting for it.
#   3. B rewrites the card to v2, then the skill file changes to v3; B releases.
#   4. A gets the lock and, as documented, re-runs discovery: it must report
#      CHANGED card v2 -> now v3 (the fresh state), not the stale v1 -> v2.
#   5. A builds the card from v3; the file changes to v4 before the write; the
#      documented pre-write cksum test must refuse the write.
# Exit 0 = every step as expected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; DOC="$HERE/../references/index.md"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"; trap 'rm -rf "$d"' EXIT
FAILS=0; ok() { echo "ok:   $1"; }; bad() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }

# Block n of the bash fences whose text contains a marker.
block() { awk -v m="$1" '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,m)) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC"; }
DISC="$(block 'DISCOVERY OK')"; ACQ="$(block 'until mkdir')"; CHK="$(block 'LOCK OK')"; REL="$(block 'LOCK RELEASED')"
for v in DISC ACQ CHK REL; do [ -n "${!v}" ] || { echo "ABORT: block $v not found in index.md"; exit 2; }; done

export HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$d/home/.claude/which-skill/index.md"
unset CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR
mkdir -p "$HOME/proj" "$CLAUDE_CONFIG_DIR/skills/s1" "$(dirname "$WHICH_SKILL_INDEX")"
F="$CLAUDE_CONFIG_DIR/skills/s1/SKILL.md"; I="$WHICH_SKILL_INDEX"
run() { (cd "$HOME/proj" && bash -c "$1"); }
fp() { cksum < "$F"; }
card() { printf '## user/s1\n\n```yaml\nname: s1\nsource: user\npath: ~/.claude/skills/s1/SKILL.md\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** %s\n**Use when:** x.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** a, b\n**Examples:**\n- "one"\n- "two"\n' "$1" "$2"; }

printf 'v1\n' > "$F"; V1="$(fp)"
{ printf '%s\n\n' '<!-- which-skill index v1 · updated 2026-11-16 -->'; card "$V1" v1; } > "$I"
printf 'v2\n' > "$F"; V2="$(fp)"

# 1. A, before the lock
PRE="$(run "$DISC")"
grep -qx "CHANGED user/s1 | card $V1 | now $V2" <<< "$PRE" && ok "A pre-lock: CHANGED v1 -> v2" || bad "A pre-lock output: $PRE"

# 2. B holds the lock; A waits in the background
BOUT="$(run "$ACQ")"; BT="${BOUT##*TOKEN=}"
grep -q 'LOCK ACQUIRED' <<< "$BOUT" && ok "B holds the lock" || bad "B acquire: $BOUT"
run "$ACQ" > "$d/a-acq.txt" 2>&1 & APID=$!
sleep 2
grep -q 'LOCK ACQUIRED' "$d/a-acq.txt" && bad "A got the lock while B held it" || ok "A waits for B"

# 3. B rewrites the card to v2 (after its own ownership check), the file moves to v3, B releases
run "${CHK//<your token>/$BT}" | grep -qx 'LOCK OK' || bad "B ownership check"
{ printf '%s\n\n' '<!-- which-skill index v1 · updated 2026-11-16 -->'; card "$V2" v2; } > "$I"
printf 'v3\n' > "$F"; V3="$(fp)"
run "${REL//<your token>/$BT}" | grep -qx 'LOCK RELEASED' && ok "B released" || bad "B release"
wait "$APID"; AOUT="$(cat "$d/a-acq.txt")"; AT="${AOUT##*TOKEN=}"
grep -q 'LOCK ACQUIRED' <<< "$AOUT" && ok "A acquired after B" || bad "A acquire: $AOUT"

# 4. A re-runs discovery under the lock
POST="$(run "$DISC")"
tail -1 <<< "$POST" | grep -q '^DISCOVERY OK' && ok "A post-lock: fresh DISCOVERY OK" || bad "A post-lock discovery did not end OK"
grep -qx "CHANGED user/s1 | card $V2 | now $V3" <<< "$POST" && ok "A post-lock: CHANGED v2 -> v3 (fresh state)" || bad "A post-lock output: $POST"
grep -q "card $V1" <<< "$POST" && bad "A post-lock still shows the stale v1 card" || ok "stale v1 -> v2 plan is gone"

# 5. A builds from v3; the file changes before the write; the pre-write test refuses
printf 'v4\n' > "$F"
CHKA="${CHK//<your token>/$AT}"
if run "$CHKA"' && [ "$(cksum < '"'$F'"')" = '"'$V3'"' ] && echo WRITE' | grep -q WRITE; then bad "pre-write cksum test let a stale card through"; else ok "pre-write cksum test refuses the stale v3 card"; fi
run "$CHKA"' && [ "$(cksum < '"'$F'"')" = '"'$(fp)'"' ] && echo WRITE' | grep -q WRITE && ok "rebuilt v4 card passes the test" || bad "fresh card refused"
run "${REL//<your token>/$AT}" | grep -qx 'LOCK RELEASED' && ok "A released" || bad "A release"

if [ "$FAILS" -eq 0 ]; then echo "SIM RELOCK OK"; exit 0; else echo "SIM RELOCK FAILED ($FAILS)"; exit 1; fi
