#!/usr/bin/env bash
# Sandbox simulation of which file a session opens at shortlist time (no
# claude run), under bash and zsh, with the discovery block extracted verbatim
# from index.md. Plugin `pl` (marketplace `mkt`) has two cached copies with
# different content: project A installed 1.0.0, project B installed 2.0.0
# (project records in installed_plugins.json). The shared index holds the card
# plugin:pl/rep as session B last wrote it: path and fingerprint of 2.0.0.
# Session A runs discovery again before opening its candidates, and the rule of
# search-and-answer.md ("Which file to open"), encoded below in OPEN_PY,
# must pick A's copy (1.0.0) and add the note line; session B picks 2.0.0 with
# no note. Limitation: OPEN_PY is this test's reading of the documented rule,
# not the model's behavior; the text checks at the end only show that the
# skill states the rule.
# Exit 0 = every check as expected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; DOC="$HERE/../references/index.md"
SAA="$HERE/../references/search-and-answer.md"; SK="$HERE/../SKILL.md"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"
PIDS=""; trap 'for p in $PIDS; do kill -9 -- -"$p" 2>/dev/null; done; rm -rf "$d"' EXIT
BAD=0; ok() { echo "ok     $1"; }; bad() { BAD=$((BAD+1)); echo "NOT OK $1"; }
DISC="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"DISCOVERY OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$DISC" ] || { echo "ABORT: discovery block not found"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ABORT: python3 not found"; exit 2; }
unset CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR
NOTE='card was refreshed by another project; judged from this session'"'"'s copy'

H="$d/home"; CA="$H/.claude/plugins/cache/mkt/pl"; I="$d/idx/index.md"; mkdir -p "$d/A" "$d/B" "$d/idx"
for v in 1.0.0 2.0.0; do
  mkdir -p "$CA/$v/.claude-plugin" "$CA/$v/skills/rep"
  printf '{"name": "pl"}\n' > "$CA/$v/.claude-plugin/plugin.json"
  printf -- '---\nname: rep\ndescription: Reports.\n---\nbody of %s\n' "$v" > "$CA/$v/skills/rep/SKILL.md"
done
printf '{"version": 2, "plugins": {"pl@mkt": [{"scope": "project", "installPath": "%s", "projectPath": "%s"}, {"scope": "project", "installPath": "%s", "projectPath": "%s"}]}}\n' \
  "$CA/1.0.0" "$d/A" "$CA/2.0.0" "$d/B" > "$H/.claude/plugins/installed_plugins.json"
printf '%s\n\n## plugin:pl/rep\n\n```yaml\nname: rep\nsource: plugin:pl\npath: ~/.claude/plugins/cache/mkt/pl/2.0.0/skills/rep/SKILL.md\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Reports.\n**Use when:** Reports.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** report\n**Examples:**\n- "a"\n- "b"\n' \
  '<!-- which-skill index v1 · updated 2026-11-16 -->' "$(cksum < "$CA/2.0.0/skills/rep/SKILL.md" | cut -d' ' -f1-2)" > "$I"

# The rule as this test reads it (round 43): the located files of this run
# are exactly the paths printed on its LOCATED and NOCARD lines; the index is
# read only for the card's stored path and fingerprint, to decide the note,
# never as a source of a path to open. Count the located files that map to the
# candidate's key (plugin name from the longest PLUGIN prefix, skill name from
# its folder). Exactly one: open it. Zero or more than one: the skill is
# unverified ("could not tell which copy this session loads"); never the
# card's stored path, never the first NOCARD. A path or fingerprint that
# differs from the card adds the refresh note.
OPEN_PY='
import os, re, sys
idx, disc = open(sys.argv[1]).read(), open(sys.argv[2]).read().splitlines(); key = sys.argv[3]; home = os.environ["HOME"]
cp, cf = None, None
for b in idx.split("\n## ")[1:]:
    if b.split("\n", 1)[0] != key: continue
    mp = re.search(r"(?m)^path: (.*)$", b); mf = re.search(r"(?m)^fingerprint: (.*)$", b)
    cp = mp.group(1) if mp else "none"; cf = mf.group(1) if mf else ""
    if cp.startswith("~/"): cp = home + cp[1:]
plugins = [l.split(" ", 2)[1:] for l in disc if l.startswith("PLUGIN ")]
def keyof(p):
    best = max((f for n, f in plugins if p.startswith(f + "/")), key=len, default=None)
    if best is None: return None
    name = [n for n, f in plugins if f == best][0]; m = re.search(r"/skills/([^/]+)/SKILL\.md$", p)
    return "plugin:%s/%s" % (name, m.group(1)) if m else None
loc = []
for l in disc:
    if l.startswith("LOCATED "):
        k, f, p = l[len("LOCATED "):].split(" | ", 2); loc.append((p, f))
    elif l.startswith("NOCARD "):
        h = l.split(" ", 3); loc.append((h[3], h[1] + " " + h[2]))
hits = [x for x in loc if keyof(x[0]) == key]
if len(hits) != 1: print("UNVERIFIED"); print("could not tell which copy this session loads"); sys.exit(0)
path, fp = hits[0]
print("OPEN " + path); print("NOTE" if (path != cp or fp != cf) else "NONOTE")
'
# Every OPEN must name a path printed on a LOCATED or NOCARD line of the run.
from_disc() { # from_disc <shortlist output> <transcript>
  local o; o="$(sed -n 's/^OPEN //p' <<< "$1")"; [ -z "$o" ] && return 0
  WS_P="$o" awk 'BEGIN { p = ENVIRON["WS_P"] }
    index($0, "LOCATED ") == 1 { n = split($0, a, " [|] "); if (n == 3 && a[3] == p) f = 1 }
    index($0, "NOCARD ") == 1 { split($0, a, " "); if (substr($0, length(a[1] a[2] a[3]) + 4) == p) f = 1 }
    END { exit !f }' "$2"
}


disc() { # disc <shell> <cwd> <out> [VAR=value...]: discovery with this fixture's HOME and index
  local sh="$1" cwd="$2" out="$3"; shift 3
  set -m; (cd "$cwd" && exec env HOME="$H" WHICH_SKILL_INDEX="$I" ${1+"$@"} "$sh" -c "$DISC") > "$out" 2>&1 & local pid=$!; set +m
  PIDS="$PIDS $pid"; local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "rc=TIMEOUT"; return; fi
  wait "$pid"; echo "rc=$?"
}
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP   $sh not found"; continue; }
  for s in A B; do
    case "$s" in A) want="$CA/1.0.0/skills/rep/SKILL.md"; wn=NOTE;; B) want="$CA/2.0.0/skills/rep/SKILL.md"; wn=NONOTE;; esac
    L="$sh session $s"; r="$(disc "$sh" "$d/$s" "$d/out")"
    [ "$r" = rc=0 ] && tail -1 "$d/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r"; continue; }
    got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$d/out" plugin:pl/rep)"
    [ "$(sed -n 1p <<< "$got")" = "OPEN $want" ] && ok "$L: opens its own active copy (${want#$CA/})" || bad "$L: opens '$(sed -n 1p <<< "$got")', expected ${want#$CA/}"
    [ "$(sed -n 2p <<< "$got")" = "$wn" ] && ok "$L: $wn" || bad "$L: note '$(sed -n 2p <<< "$got")', expected $wn"
    from_disc "$got" "$d/out" && ok "$L: the opened path is on a LOCATED or NOCARD line" || bad "$L: opened a path discovery did not print"
    [ "$s" = A ] && { grep -q '^path: ~/.claude/plugins/cache/mkt/pl/2.0.0/' "$I" && ok "$L: the card's own path is B's copy (opening it would be the bug)" || bad "$L: card path not B's copy"; }
  done
done
# Round 28 scenarios, each in its own fake home under $d/<shell>-<id>:
#   x-cache-card: plugin `pl` was uninstalled (installed_plugins.json lists only
#     zz@mkt) but its clean copy 1.0.0 stays in the cache; a new copy is loaded
#     through CLAUDE_CODE_PLUGIN_DIRS. The card points at the cache copy, with
#     its fingerprint (before round 28 no GONE line named it). The session must
#     open the plugin dir copy, with the note.
#   seeds-two-nocard: two CLAUDE_CODE_PLUGIN_SEED_DIR entries both hold `pl`
#     and the card's old path is gone: two NOCARD files map to the key, so the
#     skill is unverified (not the first NOCARD).
#   seeds-card-plus-nocard: the card points at the first seed copy (located)
#     and the second is a NOCARD of the same key: two located files, unverified.
#   x-two: two CLAUDE_CODE_PLUGIN_DIRS entries give `pl`; the card points at
#     the first: AMBIGUOUS-ACTIVE, both copies are stale, unverified.
mkpl() { # mkpl <plugin folder> <label>
  mkdir -p "$1/.claude-plugin" "$1/skills/rep"; printf '{"name": "pl"}\n' > "$1/.claude-plugin/plugin.json"
  printf -- '---\nname: rep\ndescription: Reports.\n---\nbody of %s\n' "$2" > "$1/skills/rep/SKILL.md"
}
mkcard() { # mkcard <SKILL.md path> <fingerprint>
  printf '%s\n\n## plugin:pl/rep\n\n```yaml\nname: rep\nsource: plugin:pl\npath: %s\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Reports.\n**Use when:** Reports.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** report\n**Examples:**\n- "a"\n- "b"\n' \
    '<!-- which-skill index v1 · updated 2026-11-16 -->' "$1" "$2" > "$I"
}
fp() { cksum < "$1" | cut -d' ' -f1-2; }
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in x-cache-card seeds-two-nocard seeds-card-plus-nocard x-two; do
    X="$d/$sh-$id"; H="$X/home"; I="$X/idx/index.md"; PL="$H/.claude/plugins"; mkdir -p "$X/A" "$X/idx" "$PL"
    printf '{"version": 2, "plugins": {"zz@mkt": [{"scope": "user", "installPath": "/nowhere/zz"}]}}\n' > "$PL/installed_plugins.json"
    case "$id" in
      x-cache-card) mkpl "$PL/cache/mkt/pl/1.0.0" cache; mkpl "$X/ext/e1" ext
        f="$PL/cache/mkt/pl/1.0.0/skills/rep/SKILL.md"; mkcard "$f" "$(fp "$f")"
        set -- CLAUDE_CODE_PLUGIN_DIRS="$X/ext/e1"; want="OPEN $X/ext/e1/skills/rep/SKILL.md"; wn=NOTE;;
      seeds-two-nocard) mkpl "$X/s1/pl" s1; mkpl "$X/s2/pl" s2
        mkcard "$PL/cache/mkt/pl/0.9.0/skills/rep/SKILL.md" "1 1"
        set -- CLAUDE_CODE_PLUGIN_SEED_DIR="$X/s1:$X/s2"; want=UNVERIFIED; wn="could not tell which copy this session loads";;
      seeds-card-plus-nocard) mkpl "$X/s1/pl" s1; mkpl "$X/s2/pl" s2
        f="$X/s1/pl/skills/rep/SKILL.md"; mkcard "$f" "$(fp "$f")"
        set -- CLAUDE_CODE_PLUGIN_SEED_DIR="$X/s1:$X/s2"; want=UNVERIFIED; wn="could not tell which copy this session loads";;
      x-two) mkpl "$X/ext/e1" e1; mkpl "$X/ext/e2" e2
        f="$X/ext/e1/skills/rep/SKILL.md"; mkcard "$f" "$(fp "$f")"
        set -- CLAUDE_CODE_PLUGIN_DIRS="$X/ext/e1:$X/ext/e2"; want=UNVERIFIED; wn="could not tell which copy this session loads";;
    esac
    L="$sh $id"; r="$(disc "$sh" "$X/A" "$X/out" "$@")"
    [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r"; continue; }
    got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/out" plugin:pl/rep)"
    [ "$(sed -n 1p <<< "$got")" = "$want" ] && ok "$L: ${want#$X/}" || bad "$L: got '$(sed -n 1p <<< "$got" | sed "s|$X/||")', expected '${want#$X/}'"
    [ "$(sed -n 2p <<< "$got")" = "$wn" ] && ok "$L: $wn" || bad "$L: second line '$(sed -n 2p <<< "$got")', expected '$wn'"
    from_disc "$got" "$X/out" && ok "$L: nothing opened outside LOCATED/NOCARD" || bad "$L: opened a path discovery did not print"
    case "$id" in x-cache-card) grep -q '^GONE plugin:pl/rep ' "$X/out" && ok "$L: the card's cache path is GONE (stale copy)" || bad "$L: no GONE line for the card's cache path";; esac
  done
done
# Round 29: a manifest name held by an ambiguous key stays reserved. Every case
# has a leftover unlisted cache copy pl@mkt/1.0.0 (manifest `pl`) and the card
# points at it, with its fingerprint; the session must not open it.
#   listed-amb: pl2@mk2 (manifest pl) has two user records -> AMBIGUOUS-ACTIVE
#     pl2@mk2, and pl@mkt is SUPERSEDED by it;
#   synced-amb: synced plugin sb (manifest pl) has ~g2 and ~g02 -> AMBIGUOUS-ACTIVE
#     synced/ID/sb, and pl@mkt is SUPERSEDED by it;
#   unlisted-amb: unlisted pl@mk2 has two copies with equal mtimes (already
#     AMBIGUOUS-ACTIVE) and pl@mkt one copy -> both AMBIGUOUS-ACTIVE.
# In all: no ACTIVE line and no NOCARD for name pl, the card is GONE, unverified.
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in listed-amb synced-amb unlisted-amb; do
    X="$d/$sh-r29-$id"; H="$X/home"; I="$X/idx/index.md"; PL="$H/.claude/plugins"; mkdir -p "$X/A" "$X/idx" "$PL"
    mkpl "$PL/cache/mkt/pl/1.0.0" leftover; f="$PL/cache/mkt/pl/1.0.0/skills/rep/SKILL.md"; mkcard "$f" "$(fp "$f")"
    J='"zz@mkt": [{"scope": "user", "installPath": "/nowhere/zz"}]'
    case "$id" in
      listed-amb) mkpl "$PL/cache/mk2/pl2/a" a; mkpl "$PL/cache/mk2/pl2/b" b
        J="\"pl2@mk2\": [{\"scope\": \"user\", \"installPath\": \"$PL/cache/mk2/pl2/a\"}, {\"scope\": \"user\", \"installPath\": \"$PL/cache/mk2/pl2/b\"}]"
        wl="AMBIGUOUS-ACTIVE pl2@mk2;SUPERSEDED pl@mkt by pl2@mk2;";;
      synced-amb) mkpl "$PL/synced/ID/sb~g2" g2; mkpl "$PL/synced/ID/sb~g02" g02
        wl="AMBIGUOUS-ACTIVE synced/ID/sb;SUPERSEDED pl@mkt by synced/ID/sb;";;
      unlisted-amb) mkpl "$PL/cache/mk2/pl/x" x; mkpl "$PL/cache/mk2/pl/y" y; touch -t 202601010000 "$PL/cache/mk2/pl/x" "$PL/cache/mk2/pl/y"
        wl="AMBIGUOUS-ACTIVE pl@mk2;AMBIGUOUS-ACTIVE pl@mkt;";;
    esac
    printf '{"version": 2, "plugins": {%s}}\n' "$J" > "$PL/installed_plugins.json"
    L="$sh r29 $id"; r="$(disc "$sh" "$X/A" "$X/out")"
    [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r"; continue; }
    gl="$(grep -E '^(ACTIVE|AMBIGUOUS-ACTIVE|SUPERSEDED) ' "$X/out" | grep -v ' zz@mkt' | LC_ALL=C sort | tr '\n' ';')"
    [ "$gl" = "$wl" ] && ok "$L: $wl" || bad "$L: got '$gl', expected '$wl'"
    ! grep -q '^NOCARD ' "$X/out" && grep -q '^GONE plugin:pl/rep ' "$X/out" && ok "$L: no NOCARD, the card is GONE" || bad "$L: residual NOCARD or no GONE"
    got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/out" plugin:pl/rep)"
    [ "$(sed -n 1p <<< "$got")" = UNVERIFIED ] && ok "$L: unverified" || bad "$L: shortlist got '$(sed -n 1p <<< "$got" | sed "s|$X/||")'"
  done
done
# Round 30: the same table as test-active-copy.sh (tests/r30-fixture.sh); the
# shortlist must rank the skill unverified, never open the leftover.
. "$HERE/r30-fixture.sh"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in $R30_CASES; do
    X="$d/$sh-r30-$id"; r30fix "$id" "$X"; H="$X/home"; I="$X/idx/index.md"; L="$sh r30 $id"
    r="$(disc "$sh" "$X/A" "$X/out")"
    [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r"; continue; }
    e="$(r30check "$X/out")"; [ -z "$e" ] && ok "$L: no ACTIVE or NOCARD for pl" || bad "$L: $(tr '\n' ';' <<< "$e")"
    got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/out" plugin:pl/rep)"
    [ "$(sed -n 1p <<< "$got")" = UNVERIFIED ] && ok "$L: unverified" || bad "$L: shortlist got '$(sed -n 1p <<< "$got" | sed "s|$X/||")'"
  done
done
# Round 31 (tests/r31-fixture.sh): a refused plugin dir entry never lets the
# leftover be opened; a safe entry opens the plugin dir copy as before.
. "$HERE/r31-fixture.sh"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in $R31_CASES; do
    X="$d/$sh-r31-$id"; r31fix "$id" "$X"; H="$X/home"; I="$X/idx/index.md"; L="$sh r31 $id"
    r="$(disc "$sh" "$X/A" "$X/out" CLAUDE_CODE_PLUGIN_DIRS="$R31_DIRS")"
    [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r"; continue; }
    e="$(r31check "$id" "$X/out")"; [ -z "$e" ] && ok "$L: discovery as expected" || bad "$L: $(tr '\n' ';' <<< "$e")"
    if [ "$id" = safe ]; then want="OPEN $R31_DIRS/skills/rep/SKILL.md"; else want=UNVERIFIED; fi
    got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/out" plugin:pl/rep)"
    [ "$(sed -n 1p <<< "$got")" = "$want" ] && ok "$L: ${want#$X/}" || bad "$L: shortlist got '$(sed -n 1p <<< "$got" | sed "s|$X/||")'"
  done
done
# Round 32 (tests/r32-fixture.sh): the leftover is never opened.
. "$HERE/r32-fixture.sh"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in $R32_CASES; do
    X="$d/$sh-r32-$id"; r32fix "$id" "$X"; L="$sh r32 $id"; r="$(r32disc "$sh" "$X" "$X/out")"
    [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r"; continue; }
    e="$(r32check "$id" "$X" "$X/out")"; [ -z "$e" ] && ok "$L: discovery as expected" || bad "$L: $(tr '\n' ';' <<< "$e")"
    got="$(HOME="$R32_HOME" python3 -I -c "$OPEN_PY" "$X/idx/index.md" "$X/out" plugin:qq/rq)"
    [ "$(sed -n 1p <<< "$got")" = UNVERIFIED ] && ok "$L: unverified" || bad "$L: shortlist got '$(sed -n 1p <<< "$got" | sed "s|$X/||")'"
  done
done
# Round 33 (tests/r33-fixture.sh): symlinked cache levels and the unkeyed
# invariant never let the leftover be opened.
. "$HERE/r33-fixture.sh"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in $R33_LINK skip-cache; do
    X="$d/$sh-r33-$id"; r33fix "$id" "$X"; L="$sh r33 $id"; r="$(r33disc "$id" "$sh" "$X" "$X/out")"
    [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r"; continue; }
    if [ "$id" = skip-cache ]; then e="$(r33inv "$id" "$X" "$X/out")"; else e="$(r32check noname "$X" "$X/out")"; fi
    [ -z "$e" ] && ok "$L: discovery as expected" || bad "$L: $(tr '\n' ';' <<< "$e")"
    got="$(HOME="$R32_HOME" python3 -I -c "$OPEN_PY" "$X/idx/index.md" "$X/out" plugin:qq/rq)"
    [ "$(sed -n 1p <<< "$got")" = UNVERIFIED ] && ok "$L: unverified" || bad "$L: shortlist got '$(sed -n 1p <<< "$got" | sed "s|$X/||")'"
  done
done
# Round 42: a ROOTS-INCOMPLETE run. The card's file exists, but the cache is
# configured as <cfg>/x/../plugins (refused), so the card is UNKNOWN: the
# shortlist must rank it unverified and never open the card's path.
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  X="$d/$sh-r42"; H="$X/home"; I="$X/idx/index.md"; PL="$H/.claude/plugins"; mkdir -p "$X/A" "$X/idx" "$H/.claude/x"
  mkpl "$PL/cache/mkt/pl/1.0.0" one; f="$PL/cache/mkt/pl/1.0.0/skills/rep/SKILL.md"; mkcard "$f" "$(fp "$f")"
  printf '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' "$PL/cache/mkt/pl/1.0.0" > "$PL/installed_plugins.json"
  L="$sh r42 unknown"; r="$(disc "$sh" "$X/A" "$X/out" CLAUDE_CODE_PLUGIN_CACHE_DIR="$H/.claude/x/../plugins")"
  [ "$r" = rc=0 ] && grep -qx ROOTS-INCOMPLETE "$X/out" && grep -q '^UNKNOWN plugin:pl/rep ' "$X/out" && ok "$L: ROOTS-INCOMPLETE, the card is UNKNOWN" || { bad "$L: $r $(grep -E '^(ROOTS|UNKNOWN|GONE|DISCOVERY)' "$X/out" | tr '\n' ' ')"; continue; }
  got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/out" plugin:pl/rep)"
  [ "$(sed -n 1p <<< "$got")" = UNVERIFIED ] && ok "$L: unverified, the card's path is not opened" || bad "$L: shortlist got '$(sed -n 1p <<< "$got" | sed "s|$X/||")'"
done
# Round 43: the path to open comes only from LOCATED and NOCARD lines.
#   1. second run: the card written after a first run (NOCARD) is UNCHANGED;
#      discovery prints LOCATED <key> | <fingerprint> | <path> and the session
#      opens that path, with no note; after an edit the card is CHANGED and its
#      LOCATED line carries the new fingerprint (note).
#   2. negative: another session rewrites the card to another existing copy
#      after this run's discovery; that card path was never printed by this
#      run, so it is never opened (this session's LOCATED copy is).
#   3. negative: the same transcript without its LOCATED lines (the comparator
#      before round 43): the card's path is never a fallback, unverified.
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  X="$d/$sh-r43"; H="$X/home"; I="$X/idx/index.md"; PL="$H/.claude/plugins"; mkdir -p "$X/A" "$X/idx"
  mkpl "$PL/cache/mkt/pl/1.0.0" one; mkpl "$PL/cache/mkt/pl/2.0.0" two
  f="$PL/cache/mkt/pl/1.0.0/skills/rep/SKILL.md"; f2="$PL/cache/mkt/pl/2.0.0/skills/rep/SKILL.md"
  printf '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' "$PL/cache/mkt/pl/1.0.0" > "$PL/installed_plugins.json"
  printf '%s\n' '<!-- which-skill index v1 · updated 2026-11-16 -->' > "$I"
  L="$sh r43 first run"; r="$(disc "$sh" "$X/A" "$X/o1")"
  [ "$r" = rc=0 ] && grep -qx "NOCARD $(cksum "$f")" "$X/o1" && ! grep -q '^LOCATED ' "$X/o1" && ok "$L: NOCARD, no LOCATED" || bad "$L: $r $(grep -E '^(NOCARD|LOCATED|DISCOVERY)' "$X/o1" | tr '\n' ' ')"
  got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/o1" plugin:pl/rep)"
  [ "$(sed -n 1p <<< "$got")" = "OPEN $f" ] && from_disc "$got" "$X/o1" && ok "$L: opens the NOCARD file" || bad "$L: got '$got'"
  mkcard "$f" "$(fp "$f")"; L="$sh r43 second run"; r="$(disc "$sh" "$X/A" "$X/o2")"
  [ "$r" = rc=0 ] && grep -qx 'UNCHANGED 1' "$X/o2" && ! grep -q '^NOCARD ' "$X/o2" && ok "$L: UNCHANGED 1, no NOCARD" || bad "$L: $r $(grep -E '^(NOCARD|UNCHANGED|DISCOVERY)' "$X/o2" | tr '\n' ' ')"
  [ "$(grep -c '^LOCATED ' "$X/o2")" = 1 ] && grep -qxF "LOCATED plugin:pl/rep | $(fp "$f") | $f" "$X/o2" && ok "$L: one LOCATED line with key, fingerprint and path" || bad "$L: LOCATED lines: $(grep '^LOCATED' "$X/o2" | tr '\n' ';')"
  got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/o2" plugin:pl/rep)"
  [ "$got" = "OPEN $f
NONOTE" ] && from_disc "$got" "$X/o2" && ok "$L: opens the file from its LOCATED line, no note" || bad "$L: got '$(tr '\n' ' ' <<< "$got")'"
  L="$sh r43 race"; mkcard "$f2" "$(fp "$f2")"
  got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/o2" plugin:pl/rep)"
  [ "$got" = "OPEN $f
NOTE" ] && ok "$L: the card's new path (never printed by this run) is not opened; this run's LOCATED copy is, with the note" || bad "$L: got '$(tr '\n' ' ' <<< "$got")'"
  ! grep -qF "$f2" <<< "$(grep -E '^(LOCATED|NOCARD) ' "$X/o2")" && ok "$L: the card's new path is on no LOCATED or NOCARD line" || bad "$L: transcript names the card's new path"
  L="$sh r43 no LOCATED"; grep -v '^LOCATED ' "$X/o2" > "$X/o2n"; mkcard "$f" "$(fp "$f")"
  got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/o2n" plugin:pl/rep)"
  [ "$(sed -n 1p <<< "$got")" = UNVERIFIED ] && ok "$L: unverified, the card's path is no fallback" || bad "$L: got '$(tr '\n' ' ' <<< "$got")'"
  printf 'edited\n' >> "$f"; L="$sh r43 changed"; r="$(disc "$sh" "$X/A" "$X/o3")"
  [ "$r" = rc=0 ] && grep -q '^CHANGED plugin:pl/rep | ' "$X/o3" && grep -qxF "LOCATED plugin:pl/rep | $(fp "$f") | $f" "$X/o3" && ok "$L: CHANGED, LOCATED with the new fingerprint" || bad "$L: $r $(grep -E '^(CHANGED|LOCATED)' "$X/o3" | tr '\n' ';')"
  got="$(HOME="$H" python3 -I -c "$OPEN_PY" "$I" "$X/o3" plugin:pl/rep)"
  [ "$got" = "OPEN $f
NOTE" ] && from_disc "$got" "$X/o3" && ok "$L: opens it from LOCATED, with the note" || bad "$L: got '$(tr '\n' ' ' <<< "$got")'"
done
# Round 42 text consistency: "located" is defined once in index.md, and no
# rule in index.md, search-and-answer.md or SKILL.md decides what is located
# or what to open from the absence of a GONE line without also excluding
# UNKNOWN.
LD="$(grep '^- \*\*Located\*\*' "$DOC")"
[ "$(grep -c '^- \*\*Located\*\*' "$DOC")" = 1 ] && grep -qF 'a path on a `LOCATED` or `NOCARD` line of this run' <<< "$LD" && ok "index.md defines Located once: a path on a LOCATED or NOCARD line" || bad "index.md: no single Located definition by LOCATED/NOCARD lines"
grep -q '^- `LOCATED <key> | <fingerprint> | <path>`' "$DOC" && grep -q 'print "LOCATED "' "$DOC" && ok "index.md documents and prints LOCATED" || bad "index.md lacks the LOCATED line"
for fl in "$SAA" "$SK"; do grep -qF '`LOCATED` or `NOCARD` line' "$fl" && ok "${fl##*/}: opens only paths on LOCATED or NOCARD lines" || bad "${fl##*/}: no LOCATED/NOCARD provenance rule"; done
for fl in "$DOC" "$SAA" "$SK"; do h="$(grep -nE '(path of every card|card.s path that is on neither)' "$fl")"; [ -z "$h" ] && ok "${fl##*/}: no rule takes a card's path as located" || bad "${fl##*/}: card path as located: $(cut -c1-120 <<< "$h" | tr '\n' ';')"; done
for fl in "$DOC" "$SAA" "$SK"; do
  h="$(grep -nE '(no|not on a|without( a)?|that no|neither a) `GONE`' "$fl" | grep -v 'UNKNOWN')"
  [ -z "$h" ] && ok "${fl##*/}: every absent-GONE rule also excludes UNKNOWN" || bad "${fl##*/}: absent-GONE rule without UNKNOWN: $(cut -c1-120 <<< "$h" | tr '\n' ';')"
done
U='could not tell which copy this session loads'
for fl in "$SAA" "$SK" "$DOC"; do grep -qF "$U" "$fl" && ok "${fl##*/} has '$U'" || bad "${fl##*/} lacks '$U'"; done
grep -qi 'exactly one' "$SAA" && grep -qi 'first .NOCARD' "$SAA" && ok "search-and-answer.md: exactly one located file, never the first NOCARD" || bad "search-and-answer.md lacks the unique-match rule"
grep -qF "$NOTE" "$SAA" && ok "search-and-answer.md has the note line" || bad "search-and-answer.md lacks the note line"
grep -q 'Which file to open' "$SAA" && ok "search-and-answer.md states which file to open" || bad "search-and-answer.md lacks 'Which file to open'"
grep -qF "$NOTE" "$SK" && grep -q "never the path stored in the card" "$SK" && ok "SKILL.md states the rule" || bad "SKILL.md lacks the rule"
grep -q "never the path stored in the card" "$DOC" && ok "index.md states the rule" || bad "index.md lacks the rule"
# Round 46: same-name skills across sources. Claude Code resolves a bare
# `/name` by precedence, enterprise over personal, personal over project
# (code.claude.com/docs/en/skills, "Resolve skills that share a name"); plugin
# skills are namespaced (`/plugin:name`) and never collide. A user or project
# card shadowed by a higher-precedence card with the same effective name is
# never shortlisted. SHADOW_PY is this test's reading of that rule: it keys
# every located file (LOCATED and NOCARD lines of the run) by the path table,
# with the effective name (the frontmatter `name` of the first block, else the
# folder name), keeps the keys the session lists, and marks each bare name's
# lower-precedence user/project keys SHADOWED.
#   both:      ~/.claude/skills/deploy and <project>/.claude/skills/deploy, plus
#              plugin pl with a `deploy` skill: user and plugin eligible, the
#              project card shadowed;
#   fm:        ~/.claude/skills/ship/SKILL.md with `name: deploy` shadows the
#              project deploy just the same (the effective name decides);
#   proj-only: no personal deploy: the project card is eligible.
SHADOW_PY='
import os, re, sys
disc = open(sys.argv[1]).read().splitlines(); listed = set(sys.argv[2].split()); home = os.environ["HOME"]
root, cwd = sys.argv[3], sys.argv[3]; cfg = home + "/.claude"
plugins = [l.split(" ", 2)[1:] for l in disc if l.startswith("PLUGIN ")]
def keyof(p):
    for r in (root, cwd):
        m = re.fullmatch(re.escape(r) + r"/\.claude/skills/([^/]+)/SKILL\.md", p)
        if m: return ("project:" + r, ename(p, m.group(1)))
    m = re.fullmatch(re.escape(cfg) + r"/skills/([^/]+)/SKILL\.md", p)
    if m: return ("user", ename(p, m.group(1)))
    best = max((f for n, f in plugins if p.startswith(f + "/")), key=len, default=None)
    m = re.search(r"/skills/([^/]+)/SKILL\.md$", p)
    if best and m: pn = [n for n, f in plugins if f == best][0]; return ("plugin:" + pn, ename(p, m.group(1), pn))
    return None
keys = set()
for l in disc:
    if l.startswith("LOCATED "): p = l[len("LOCATED "):].split(" | ", 2)[2]
    elif l.startswith("NOCARD "): p = l.split(" ", 3)[3]
    else: continue
    k = keyof(p)
    if k: keys.add(k + (p.split("/")[-2], p))
# Round 47: a personal or project skill answers to its effective name AND its
# folder name; a bare name reaches a card only when no higher-precedence card
# answers to it (and no other card of the same rank does).
rank = lambda s: 1 if s == "user" else 2   # enterprise (0) is never on disk here
# Round 49: `sure` names may be offered; `possible` names (adding the would-be
# name of an uncertain frontmatter block) still shadow lower-precedence cards.
inv = lambda k: aliases(k[3], k[2])[0]
pos = lambda k: aliases(k[3], k[2])[1]
bare = [k for k in keys if not k[0].startswith("plugin:")]
out = []
for k in sorted(keys):
    s, n = k[0], k[1]
    if s.startswith("plugin:"):
        if s[7:] + ":" + n in listed: out.append("ELIGIBLE %s/%s CALL /%s:%s" % (s, n, s[7:], n))
        continue
    if not (inv(k) & listed): continue
    calls = sorted(x for x in inv(k) if all(rank(o[0]) > rank(s) for o in bare if o != k and x in pos(o)))
    out.append(("ELIGIBLE %s/%s CALL " % (s, n) + " ".join("/" + x for x in calls)) if calls else "SHADOWED %s/%s" % (s, n))
print("\n".join(sorted(out)))
'
gcard() { # gcard <source> <name> <SKILL.md>: one card, appended to $I
  printf '\n## %s/%s\n\n```yaml\nname: %s\nsource: %s\npath: %s\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Deploys.\n**Use when:** Deploying.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** deploy\n**Examples:**\n- "a"\n- "b"\n' \
    "$1" "$2" "$2" "$1" "$3" "$(fp "$3")" >> "$I"; }
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in both fm proj-only r47 r47-alt r48-space r48-angle r48-quoted r49-broken r49-clean r49-flow r49-dup r50-nested r52-dedent r51-true r51-int r51-quoted-int r51-indicator; do
    X="$d/$sh-r46-$id"; H="$X/home"; I="$X/idx/index.md"; P="$X/proj"; mkdir -p "$P/.claude/skills/deploy" "$X/idx" "$H/.claude/skills"
    printf '%s\n' '<!-- which-skill index v1 · updated 2026-11-16 -->' > "$I"
    pf=deploy; [ "$id" = r47-alt ] && { pf=ship; rm -rf "$P/.claude/skills/deploy"; mkdir -p "$P/.claude/skills/ship"; }
    printf -- '---\nname: deploy\ndescription: Project deploy.\n---\nproject body\n' > "$P/.claude/skills/$pf/SKILL.md"
    gcard "project:$P" deploy "$P/.claude/skills/$pf/SKILL.md"; LIST="deploy"
    want="ELIGIBLE project:$P/deploy CALL /deploy"
    case "$id" in
      r51-*) mkdir -p "$H/.claude/skills/release"; LIST="deploy release 123"
        case "$id" in r51-true) fm='name: true';; r51-int) fm='name: 123';; r51-quoted-int) fm='name: "123"';; *) fm='name: deploy\nallowed-tools: - Read';; esac
        printf -- '---\n%b\n---\npersonal body\n' "$fm" > "$H/.claude/skills/release/SKILL.md"
        case "$id" in
          r51-quoted-int) gcard user 123 "$H/.claude/skills/release/SKILL.md"; want="ELIGIBLE project:$P/deploy CALL /deploy
ELIGIBLE user/123 CALL /123 /release";;
          r51-indicator) gcard user release "$H/.claude/skills/release/SKILL.md"; want="ELIGIBLE user/release CALL /release
SHADOWED project:$P/deploy";;
          *) gcard user release "$H/.claude/skills/release/SKILL.md"; want="ELIGIBLE project:$P/deploy CALL /deploy
ELIGIBLE user/release CALL /release";;
        esac;;
      r49-*|r50-*|r52-*) mkdir -p "$H/.claude/skills/release"; LIST="deploy release"
        if [ "$id" != r49-clean ]; then
          case "$id" in r49-broken) fm='description: [unclosed';; r49-flow) fm='allowed-tools: [Read}';; r50-nested) fm='metadata:\n  x: y\n  - bad';; r52-dedent) fm='description: |\n  first\n second';; *) fm='"name": other';; esac
          printf -- '---\nname: deploy\n%b\n---\npersonal body\n' "$fm" > "$H/.claude/skills/release/SKILL.md"
          gcard user release "$H/.claude/skills/release/SKILL.md"; want="ELIGIBLE user/release CALL /release
SHADOWED project:$P/deploy"
        else
          printf -- '---\n# clean\nname: "deploy"\ndescription: >-\n  Deploys: the app [a]\n  - not: nested\nallowed-tools: Read, Grep\n---\npersonal body\n' > "$H/.claude/skills/release/SKILL.md"
          gcard user deploy "$H/.claude/skills/release/SKILL.md"; want="ELIGIBLE user/deploy CALL /deploy /release
SHADOWED project:$P/deploy"
        fi;;
      r48-*) mkdir -p "$H/.claude/skills/release"; LIST="deploy release"
        case "$id" in r48-space) nm='" deploy"';; r48-angle) nm='bad<name';; *) nm='"deploy"';; esac
        printf -- '---\nname: %s\ndescription: Personal release.\n---\npersonal body\n' "$nm" > "$H/.claude/skills/release/SKILL.md"
        if [ "$id" = r48-quoted ]; then gcard user deploy "$H/.claude/skills/release/SKILL.md"; want="ELIGIBLE user/deploy CALL /deploy /release
SHADOWED project:$P/deploy"
        else gcard user release "$H/.claude/skills/release/SKILL.md"; want="ELIGIBLE project:$P/deploy CALL /deploy
ELIGIBLE user/release CALL /release"; fi;;
      r47|r47-alt) mkdir -p "$H/.claude/skills/deploy"; LIST="deploy personal-release"
        printf -- '---\nname: personal-release\ndescription: Personal release.\n---\npersonal body\n' > "$H/.claude/skills/deploy/SKILL.md"
        gcard user personal-release "$H/.claude/skills/deploy/SKILL.md"
        if [ "$id" = r47 ]; then want="ELIGIBLE user/personal-release CALL /deploy /personal-release
SHADOWED project:$P/deploy"
        else want="ELIGIBLE project:$P/deploy CALL /ship
ELIGIBLE user/personal-release CALL /deploy /personal-release"; fi;;
      both|fm) uf=deploy; [ "$id" = fm ] && uf=ship; mkdir -p "$H/.claude/skills/$uf"
        printf -- '---\ndescription: Personal deploy.\nname: deploy\n---\npersonal body\n' > "$H/.claude/skills/$uf/SKILL.md"
        gcard user deploy "$H/.claude/skills/$uf/SKILL.md"
        want="ELIGIBLE user/deploy CALL /deploy"; [ "$id" = fm ] && want="ELIGIBLE user/deploy CALL /deploy /ship"
        want="$want
SHADOWED project:$P/deploy";;
    esac
    if [ "$id" = both ]; then
      c="$H/.claude/plugins/cache/mkt/pl/1.0.0"; mkdir -p "$c/.claude-plugin" "$c/skills/deploy"; printf '{"name": "pl"}\n' > "$c/.claude-plugin/plugin.json"
      printf -- '---\nname: deploy\ndescription: Plugin deploy.\n---\n' > "$c/skills/deploy/SKILL.md"
      printf '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' "$c" > "$H/.claude/plugins/installed_plugins.json"
      gcard plugin:pl deploy "$c/skills/deploy/SKILL.md"; LIST="deploy pl:deploy"
      want="ELIGIBLE plugin:pl/deploy CALL /pl:deploy
$want"
    fi
    L="$sh r46 $id"; r="$(disc "$sh" "$P" "$X/out")"
    [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r"; continue; }
    n="$(grep -c '^LOCATED ' "$X/out")"; [ "$n" = "$(grep -c '^## ' "$I")" ] && ok "$L: every card LOCATED ($n)" || bad "$L: $n LOCATED lines"
    got="$(HOME="$H" python3 -I -c "$(cat "$HERE/frontmatter-name.py")
$SHADOW_PY" "$X/out" "$LIST" "$P")"
    [ "$got" = "$want" ] && ok "$L: $(tr '\n' ';' <<< "$got" | sed "s|$P|<proj>|g")" || bad "$L: got '$(tr '\n' ';' <<< "$got")', expected '$(tr '\n' ';' <<< "$want")'"
    CHECK_SH="$sh" HOME="$H" bash "$HERE/check-index.sh" --located "$I" "$P" > "$X/ci" 2>&1 && ok "$L: check-index --located: INDEX OK" || bad "$L: check-index: $(grep FAIL "$X/ci" | head -2 | tr '\n' ' ')"
  done
done
# Round 46 text consistency: the precedence and the shadow rule are stated in
# SKILL.md, index.md and search-and-answer.md, with the same words.
PREC='enterprise over personal, personal over project'
for fl in "$SK" "$DOC" "$SAA"; do
  grep -qF "$PREC" "$fl" && ok "${fl##*/} states the precedence ($PREC)" || bad "${fl##*/} lacks '$PREC'"
  grep -qi 'shadowed' "$fl" && ok "${fl##*/} names shadowed cards" || bad "${fl##*/} lacks the shadow rule"
  grep -qiF 'plugin skills are namespaced' "$fl" && ok "${fl##*/}: plugin skills are namespaced" || bad "${fl##*/} lacks 'plugin skills are namespaced'"
done
grep -qF 'shadowed card is never shortlisted' "$SK" && grep -qF 'shadowed card is never shortlisted' "$SAA" && ok "SKILL.md and search-and-answer.md: a shadowed card is never shortlisted" || bad "the never-shortlisted rule is missing"
grep -qF 'does not reach it' "$SAA" && ok "search-and-answer.md has the one-line shadow mention" || bad "search-and-answer.md lacks the shadow line"
[ "$(grep -c '^- \*\*Effective name\*\*' "$DOC")" = 1 ] && grep '^- \*\*Effective name\*\*' "$DOC" | grep -qF 'first frontmatter block' && grep '^- \*\*Effective name\*\*' "$DOC" | grep -qF 'folder name' && ok "index.md defines the effective name once (frontmatter name, else folder name)" || bad "index.md lacks a single Effective name definition"
grep -qF 'effective name' "$SK" && grep -qF 'effective name' "$SAA" && ok "SKILL.md and search-and-answer.md use the effective name" || bad "effective name missing in SKILL.md or search-and-answer.md"
grep -q 'def ename' "$HERE/frontmatter-name.py" && grep -q 'frontmatter-name.py' "$HERE/check-index.sh" && ok "check-index.sh keys by the effective name" || bad "check-index.sh keyof ignores the frontmatter name"
# Round 49 text consistency: an uncertain frontmatter block is stated once in
# index.md and in search-and-answer.md.
grep -qF '`uncertain`' "$DOC" && grep -qF 'folder name is offered' "$DOC" && grep -qF 'still shadow' "$DOC" && ok "index.md: an uncertain block offers only the folder name and may still shadow" || bad "index.md lacks the uncertain-block rule"
grep -qF '`uncertain`' "$SAA" && ok "search-and-answer.md: the uncertain-block rule" || bad "search-and-answer.md lacks the uncertain-block rule"
# Round 48 text consistency: the name-validity rule is stated once in index.md
# and applied before keys, prefixes and shadows; a refused name gives no alias.
grep -qF "Characters a skill name can" "$DOC" && grep -qF 'refused' <<< "$(grep '^- \*\*Effective name\*\*' "$DOC")" && ok "index.md: the effective name applies Claude Code's name refusal rule" || bad "index.md lacks the name-validity rule"
grep -qF 'a refused `name` gives no alias' "$DOC" && grep -qF 'refused' "$SAA" && ok "a refused name gives no alias (index.md, search-and-answer.md)" || bad "the refused-name alias rule is missing"
! grep -qF 'one pair of matching quotes removed' "$DOC" && ok "index.md: the old quote-stripping rule is gone" || bad "index.md still strips quotes without validating"
# Round 47 text consistency: invocable names (effective name and folder name)
# decide shadowing; the answer suggests only a command that reaches the skill;
# a plugin's own prefix in its frontmatter name is stripped once.
grep -qF 'invocable names' "$DOC" && grep -qF 'invocable names' "$SAA" && grep -qF 'invocable names' "$SK" && ok "the three files use invocable names" || bad "invocable names missing in a file"
[ "$(grep -c '^- \*\*Invocable names\*\*' "$DOC")" = 1 ] && grep '^- \*\*Invocable names\*\*' "$DOC" | grep -qF 'folder name' && ok "index.md defines Invocable names once, with the folder name" || bad "index.md lacks a single Invocable names definition"
grep -qF 'only a command name that reaches' "$SAA" && grep -qF 'only a command name that reaches' "$SK" && ok "the answer suggests only a command that reaches the skill" || bad "the reaching-command rule is missing"
grep -qF 'plugin'"'"'s own prefix' "$DOC" && grep -qF 'exactly one' <<< "$(grep -F 'plugin'"'"'s own prefix' "$DOC")" && ok "index.md strips exactly one own plugin prefix" || bad "index.md lacks the own-prefix rule"
grep -q 'own plugin prefix' "$HERE/frontmatter-name.py" && grep -q 'frontmatter-name.py' "$HERE/check-index.sh" && ok "check-index.sh strips the own plugin prefix" || bad "check-index.sh keeps a doubled prefix"
! grep -qF 'If the folder name and the frontmatter `name` differ, the session name wins.' "$DOC" && ok "index.md: the old folder-or-session rule is replaced" || bad "index.md still has the old vague rule"
if [ "$BAD" -eq 0 ]; then echo "TEST SHORTLIST-COPY OK"; exit 0; else echo "TEST SHORTLIST-COPY FAILED ($BAD)"; exit 1; fi
