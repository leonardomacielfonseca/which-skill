#!/usr/bin/env bash
# Sandbox test of the active plugin copy (no claude run), under bash and zsh,
# with the discovery block extracted verbatim from index.md. A fake config
# root holds copies of plugin `pl` (marketplace `mkt`) in the cache, each with
# skill `rep`, and (in most cases) plugins/installed_plugins.json. The session
# lists `pl:rep`. Each case gives: the copies (name and mtime), the JSON
# records, the copy the card was built from (or none), a change made after the
# card was written, and the expected outcome:
#   - the ACTIVE copy (or AMBIGUOUS-ACTIVE, or an UNSAFE-PATH install path);
#   - every other copy is STALE-COPY, never NOCARD;
#   - the plan classification of the card (index.md, "Building and updating"):
#     UNCHANGED, DOWNGRADED, or NEW from the active copy, never from another.
# JSON cases: user only; project and local records whose projectPath is the
# session folder win over user; a record of another project, or with an
# empty, relative (".", "..", "sub/dir") or missing projectPath, never
# qualifies and its copy is stale; two
# records at the same level are ambiguous. Fallback cases (no usable JSON):
# the newest copy by folder mtime is active, with hash-like names whose
# lexical order disagrees with their age; its file missing, a FIFO, dangling
# or at an unsafe folder downgrades the card; equal mtimes are ambiguous.
# Synced generations (<plugins>/synced/<id>/<name> and <name>~gN, each with
# different content): the highest N is effective (the unsuffixed folder is
# generation 1) and every other generation is STALE-COPY; a broken effective
# generation (FIFO or missing file) downgrades the card, never falling back to
# an older one; a tie (~g2 and ~g02) or an unparseable suffix (~g2x) gives
# AMBIGUOUS-ACTIVE and a downgrade.
# Also: check-index --located, and the skill text names the rules.
# Exit 0 = every check as expected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; DOC="$HERE/../references/index.md"; SK="$HERE/../SKILL.md"; CHECK="$HERE/check-index.sh"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"
PIDS=""; trap 'for p in $PIDS; do kill -9 -- -"$p" 2>/dev/null; done; rm -rf "$d"' EXIT
BAD=0; ok() { echo "ok     $1"; }; bad() { BAD=$((BAD+1)); echo "NOT OK $1"; }
DISC="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"DISCOVERY OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$DISC" ] || { echo "ABORT: discovery block not found"; exit 2; }
unset CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR

disc() {
  local sh="$1" out="$2"
  set -m; (cd "$P" && exec env HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" WHICH_SKILL_INDEX="$I" "$sh" -c "$DISC") > "$out" 2>&1 & local pid=$!; set +m
  PIDS="$PIDS $pid"; local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "rc=TIMEOUT"; return; fi
  wait "$pid"; echo "rc=$?"
}
# check-index --located runs discovery itself: same env, from the session folder, in shell $sh
chk() { (cd "$P" && exec env HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" CHECK_SH="$sh" ${1+"$@"} bash "$CHECK" --located "$I" "$P") 2>&1; }
mkcopy() { # mkcopy <name> <touch -t stamp>
  local c="$CA/$1"; mkdir -p "$c/.claude-plugin" "$c/skills/rep"
  printf '{"name": "pl", "version": "%s"}\n' "$1" > "$c/.claude-plugin/plugin.json"
  printf -- '---\nname: rep\ndescription: Reports.\n---\nbody of %s\n' "$1" > "$c/skills/rep/SKILL.md"
  touch -t "$2" "$c"
}
card() { # card <copy name>: a verified card built from that copy
  printf '%s\n\n## plugin:pl/rep\n\n```yaml\nname: rep\nsource: plugin:pl\npath: ~/.claude/plugins/cache/mkt/pl/%s/skills/rep/SKILL.md\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Reports.\n**Use when:** Reports.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** report\n**Examples:**\n- "a"\n- "b"\n' \
    '<!-- which-skill index v1 · updated 2026-11-16 -->' "$1" "$(cksum < "$CA/$1/skills/rep/SKILL.md" | cut -d' ' -f1-2)"
}
rec() { # rec <scope> <copy name> [projectPath | @EMPTY]: one JSON record (no third arg: no projectPath key)
  local pp="${3:-}"; [ "$pp" = @EMPTY ] && pp=""
  if [ -n "${3:-}" ]; then printf '{"scope": "%s", "installPath": "%s", "projectPath": "%s"}' "$1" "$CA/$2" "$pp"
  else printf '{"scope": "%s", "installPath": "%s"}' "$1" "$CA/$2"; fi
}
# Plan rule for the card: no card -> NEW <copy> from the NOCARD line;
# GONE and no NOCARD of skill rep -> DOWNGRADED; GONE with one -> CHANGED;
# otherwise UNCHANGED.
classify() {
  local nc; nc="$(sed -n 's|^NOCARD [0-9]* [0-9]* .*/cache/mkt/pl/\([^/]*\)/skills/rep/SKILL.md$|\1|p' "$1" | tr '\n' ' ')"
  if [ ! -f "$I" ]; then echo "NEW ${nc% }"
  elif ! grep -q '^GONE plugin:pl/rep ' "$1"; then echo UNCHANGED
  elif [ -n "$nc" ]; then echo "CHANGED from ${nc% }"
  else echo DOWNGRADED; fi
}

T1=202601010000; T2=202602010000          # T2 is newer
# id | copies (name:stamp,...) | json: none, fifo or records (scope:copy[:projectPath],...; @P = the session folder)
#    | card copy (- for none) | change | expected active (copy, AMBIGUOUS, UNSAFE) | expected plan
CASES='
j-new|1.0.0:T1,2.0.0:T2|user:2.0.0|-|-|2.0.0|NEW 2.0.0
j-regular|1.0.0:T1,2.0.0:T2|user:2.0.0|2.0.0|-|2.0.0|UNCHANGED
j-fifo|1.0.0:T1,2.0.0:T2|user:2.0.0|2.0.0|fifo:2.0.0|2.0.0|DOWNGRADED
j-dangling|1.0.0:T1,2.0.0:T2|user:2.0.0|2.0.0|dangling:2.0.0|2.0.0|DOWNGRADED
j-missing|1.0.0:T1,2.0.0:T2|user:2.0.0|2.0.0|rmcopy:2.0.0|2.0.0|DOWNGRADED
j-unsafe|1.0.0:T1,2.0.0;x:T2|user:2.0.0;x|1.0.0|-|UNSAFE|DOWNGRADED
j-project-wins|1.0.0:T1,2.0.0:T2|user:1.0.0,project:2.0.0:@P|-|-|2.0.0|NEW 2.0.0
j-local-wins|1.0.0:T2,2.0.0:T1|project:1.0.0:@P,local:2.0.0:@P|-|-|2.0.0|NEW 2.0.0
j-project-fifo|1.0.0:T1,2.0.0:T2|user:1.0.0,project:2.0.0:@P|2.0.0|fifo:2.0.0|2.0.0|DOWNGRADED
j-other-project|1.0.0:T1,2.0.0:T2|user:1.0.0,project:2.0.0:/elsewhere/proj|-|-|1.0.0|NEW 1.0.0
j-pp-empty|1.0.0:T1,2.0.0:T2|user:1.0.0,project:2.0.0:@EMPTY|-|-|1.0.0|NEW 1.0.0
j-pp-dot|1.0.0:T1,2.0.0:T2|user:1.0.0,local:2.0.0:.|-|-|1.0.0|NEW 1.0.0
j-pp-dotdot|1.0.0:T1,2.0.0:T2|user:1.0.0,project:2.0.0:..|-|-|1.0.0|NEW 1.0.0
j-pp-relative|1.0.0:T1,2.0.0:T2|user:1.0.0,local:2.0.0:sub/dir|-|-|1.0.0|NEW 1.0.0
j-pp-missing|1.0.0:T1,2.0.0:T2|user:1.0.0,project:2.0.0|-|-|1.0.0|NEW 1.0.0
j-ambiguous|1.0.0:T1,2.0.0:T2|user:1.0.0,user:2.0.0|2.0.0|-|AMBIGUOUS|DOWNGRADED
f-new|f07b2e:T1,a3f9c1:T2|none|-|-|a3f9c1|NEW a3f9c1
f-regular|f07b2e:T1,a3f9c1:T2|none|a3f9c1|-|a3f9c1|UNCHANGED
f-file-missing|f07b2e:T1,a3f9c1:T2|none|a3f9c1|rmfile:a3f9c1|a3f9c1|DOWNGRADED
f-fifo|f07b2e:T1,a3f9c1:T2|none|a3f9c1|fifo:a3f9c1|a3f9c1|DOWNGRADED
f-dangling|f07b2e:T1,a3f9c1:T2|none|a3f9c1|dangling:a3f9c1|a3f9c1|DOWNGRADED
f-unsafe|f07b2e:T1,a3f9;c1:T2|none|f07b2e|-|UNSAFE|DOWNGRADED
f-tie|f07b2e:T2,a3f9c1:T2|none|a3f9c1|-|AMBIGUOUS|DOWNGRADED
f-fifojson|f07b2e:T1,a3f9c1:T2|fifo|a3f9c1|fifo:a3f9c1|a3f9c1|DOWNGRADED
'

for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP   $sh not found"; continue; }
  while IFS='|' read -r id copies json cardc change act want; do
    [ -n "$id" ] || continue
    C="$d/$sh-$id"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; PL="$H/.claude/plugins"; CA="$PL/cache/mkt/pl"
    mkdir -p "$P" "$C/idx" "$CA"
    names=""
    for cs in $(tr ',' ' ' <<< "$copies"); do
      n="${cs%:*}"; t="${cs##*:}"; case "$t" in T1) t=$T1;; T2) t=$T2;; esac
      mkcopy "$n" "$t"; names="$names $n"
    done
    case "$json" in
      none) ;;
      fifo) mkfifo "$PL/installed_plugins.json";;
      *) r=""; for x in $(tr ',' ' ' <<< "$json"); do
           sc="${x%%:*}"; rest="${x#*:}"; cp_="${rest%%:*}"; pp=""; [ "$rest" != "$cp_" ] && pp="${rest#*:}"
           [ "$pp" = @P ] && pp="$P"; r="${r:+$r, }$(rec "$sc" "$cp_" "$pp")"
         done
         printf '{"version": 2, "plugins": {"pl@mkt": [%s]}}\n' "$r" > "$PL/installed_plugins.json";;
    esac
    [ "$cardc" = - ] || card "$cardc" > "$I"
    for n in $names; do touch -t "$( for cs in $(tr ',' ' ' <<< "$copies"); do [ "${cs%:*}" = "$n" ] && { t="${cs##*:}"; [ "$t" = T1 ] && echo $T1 || echo $T2; }; done )" "$CA/$n"; done
    case "$change" in
      fifo:*) f="$CA/${change#*:}/skills/rep/SKILL.md"; rm "$f"; mkfifo "$f";;
      dangling:*) f="$CA/${change#*:}/skills/rep/SKILL.md"; rm "$f"; ln -s "$C/nowhere" "$f";;
      rmfile:*) rm "$CA/${change#*:}/skills/rep/SKILL.md";;
      rmcopy:*) rm -rf "$CA/${change#*:}";;
    esac
    r="$(disc "$sh" "$C/out")"; o="$C/out"; L="$sh $id"
    [ "$r" = rc=0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 "$o")'"; continue; }
    case "$json" in none|fifo) grep -q '^NOTE .*installed_plugins.json.*newest copy' "$o" && ok "$L: fallback NOTE" || bad "$L: no fallback NOTE";; esac
    case "$act" in
      AMBIGUOUS) grep -qx 'AMBIGUOUS-ACTIVE pl@mkt' "$o" && ! grep -q '^ACTIVE ' "$o" && ok "$L: AMBIGUOUS-ACTIVE, no ACTIVE" || bad "$L: $(grep -E '^(ACTIVE|AMBIGUOUS)' "$o" | tr '\n' ' ')";;
      UNSAFE) grep -q '^UNSAFE-PATH .*/cache/mkt/pl/[^/]*?[^/]*$' "$o" && ! grep -q '^ACTIVE ' "$o" && ok "$L: unsafe active copy, no ACTIVE" || bad "$L: $(grep -E '^(ACTIVE|UNSAFE-PATH)' "$o" | tr '\n' ' ')";;
      *) [ "$(grep -c '^ACTIVE ' "$o")" -eq 1 ] && grep -qxF "ACTIVE pl@mkt $CA/$act" "$o" && ok "$L: one ACTIVE line, $act" || bad "$L: ACTIVE lines: $(grep -E '^(ACTIVE|AMBIGUOUS)' "$o" | tr '\n' ' ')";;
    esac
    for n in $names; do
      [ "$n" = "$act" ] && continue
      f="$CA/$n/skills/rep/SKILL.md"; [ -f "$f" ] || continue
      case "$n" in *';'*) continue;; esac
      grep -qxF "STALE-COPY $f" "$o" && ! grep -q "^NOCARD .*/pl/$n/" "$o" && ok "$L: $n is STALE-COPY, never NOCARD" || bad "$L: $n not STALE-COPY"
    done
    got="$(classify "$o")"; [ "$got" = "$want" ] && ok "$L: plan $want" || bad "$L: plan '$got', expected '$want'"
    if [ "$want" = UNCHANGED ] || [ "$want" = DOWNGRADED ]; then
      ci="$(chk)"; rc=$?
      if [ "$want" = UNCHANGED ]; then [ "$rc" -eq 0 ] && ok "$L: check-index --located OK" || bad "$L: check-index failed: $(grep FAIL <<< "$ci" | head -2)"
      else [ "$rc" -ne 0 ] && grep -q 'not located' <<< "$ci" && ok "$L: check-index --located rejects the stale card (its file regular or not)" || bad "$L: stale card accepted"; fi
    fi
  done <<< "$CASES"
done

# Synced generations. Folders under $SY = <plugins>/synced/ID, plugin `sb`,
# skill `inv`, each generation with its own content.
# id | folders | card folder (- for none) | change | expected active folder (or AMBIGUOUS) | expected plan
SCASES='
s-new|sb,sb~g3|-|-|sb~g3|NEW sb~g3
s-regular|sb,sb~g3|sb~g3|-|sb~g3|UNCHANGED
s-old-card|sb,sb~g3|sb|-|sb~g3|CHANGED from sb~g3
s-g3-fifo|sb,sb~g3|sb~g3|fifo:sb~g3|sb~g3|DOWNGRADED
s-g3-missing|sb,sb~g3|sb~g3|rmfile:sb~g3|sb~g3|DOWNGRADED
s-g3-outside|sb,sb~g3|sb~g3|outside:sb~g3|sb~g3|DOWNGRADED
s-g2x|sb~g2,sb~g2x|sb~g2|-|AMBIGUOUS|DOWNGRADED
s-tie|sb~g2,sb~g02|sb~g2|-|AMBIGUOUS|DOWNGRADED
s-many|sb~g10,sb~g9,sb|-|-|sb~g10|NEW sb~g10
'
smk() { local c="$SY/$1"; mkdir -p "$c/.claude-plugin" "$c/skills/inv"
  printf '{"name": "sb"}\n' > "$c/.claude-plugin/plugin.json"
  printf -- '---\nname: inv\ndescription: Chases invoices.\n---\nbody of %s\n' "$1" > "$c/skills/inv/SKILL.md"; }
scard() { printf '%s\n\n## plugin:sb/inv\n\n```yaml\nname: inv\nsource: plugin:sb\npath: ~/.claude/plugins/synced/ID/%s/skills/inv/SKILL.md\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Chases.\n**Use when:** Chases.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** invoice\n**Examples:**\n- "a"\n- "b"\n' \
    '<!-- which-skill index v1 · updated 2026-11-16 -->' "$1" "$(cksum < "$SY/$1/skills/inv/SKILL.md" | cut -d' ' -f1-2)"; }
sclassify() {
  local nc; nc="$(sed -n 's|^NOCARD [0-9]* [0-9]* .*/synced/ID/\([^/]*\)/skills/inv/SKILL.md$|\1|p' "$1" | tr '\n' ' ')"
  if [ ! -f "$I" ]; then echo "NEW ${nc% }"
  elif ! grep -q '^GONE plugin:sb/inv ' "$1"; then echo UNCHANGED
  elif [ -n "$nc" ]; then echo "CHANGED from ${nc% }"
  else echo DOWNGRADED; fi
}
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  while IFS='|' read -r id folders cardc change act want; do
    [ -n "$id" ] || continue
    C="$d/$sh-$id"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; SY="$H/.claude/plugins/synced/ID"
    mkdir -p "$P" "$C/idx" "$SY" "$C/ext"
    for n in $(tr ',' ' ' <<< "$folders"); do smk "$n"; done
    [ "$cardc" = - ] || scard "$cardc" > "$I"
    case "$change" in
      fifo:*) f="$SY/${change#*:}/skills/inv/SKILL.md"; rm "$f"; mkfifo "$f";;
      rmfile:*) rm "$SY/${change#*:}/skills/inv/SKILL.md";;
      outside:*) f="$SY/${change#*:}/skills/inv/SKILL.md"; mv "$f" "$C/ext/secret.txt"; ln -s "$C/ext/secret.txt" "$f";;
    esac
    r="$(disc "$sh" "$C/out")"; o="$C/out"; L="$sh $id"
    [ "$r" = rc=0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 "$o")'"; continue; }
    if [ "$act" = AMBIGUOUS ]; then
      grep -qx 'AMBIGUOUS-ACTIVE synced/ID/sb' "$o" && ! grep -q '^ACTIVE ' "$o" && ok "$L: AMBIGUOUS-ACTIVE, no ACTIVE" || bad "$L: $(grep -E '^(ACTIVE|AMBIGUOUS)' "$o" | tr '\n' ' ')"
    else
      [ "$(grep -c '^ACTIVE ' "$o")" -eq 1 ] && grep -qxF "ACTIVE synced/ID/sb $SY/$act" "$o" && ok "$L: one ACTIVE line, $act" || bad "$L: ACTIVE lines: $(grep -E '^(ACTIVE|AMBIGUOUS)' "$o" | tr '\n' ' ')"
    fi
    for n in $(tr ',' ' ' <<< "$folders"); do
      [ "$n" = "$act" ] && continue
      f="$SY/$n/skills/inv/SKILL.md"
      grep -qxF "STALE-COPY $f" "$o" && ! grep -q "^NOCARD .*/synced/ID/$n/" "$o" && ok "$L: $n is STALE-COPY, never NOCARD" || bad "$L: $n not STALE-COPY"
    done
    case "$change" in outside:*) grep -qxF "SKIPPED-OUTSIDE-ROOT $SY/$act/skills/inv/SKILL.md" "$o" && ok "$L: effective file SKIPPED-OUTSIDE-ROOT" || bad "$L: no SKIPPED-OUTSIDE-ROOT";; esac
    got="$(sclassify "$o")"; [ "$got" = "$want" ] && ok "$L: plan $want" || bad "$L: plan '$got', expected '$want'"
    if [ "$want" = UNCHANGED ]; then
      chk >/dev/null && ok "$L: check-index --located OK" || bad "$L: check-index failed"
    elif [ "$want" = DOWNGRADED ]; then
      ci="$(chk)"; grep -q 'not located' <<< "$ci" && ok "$L: check-index --located rejects the stale card" || bad "$L: stale card accepted by check-index"
    fi
  done <<< "$SCASES"
done

# CLAUDE_CODE_PLUGIN_DIRS and cache copies that installed_plugins.json does not
# list (round 28). The JSON always exists and lists another plugin (zz@mkt);
# `user:<copy>` also lists pl@mkt. Each plugin dir entry $C/ext/<n> is a copy
# of plugin `pl` (manifest name pl, folder name <n>), with its own content.
# A plugin dir copy wins over every cache copy of the same manifest name
# (ACTIVE plugin-dir/pl, the cache copies STALE-COPY, no ACTIVE pl@mkt line);
# two plugin dir entries with that name give AMBIGUOUS-ACTIVE plugin-dir/pl and
# every copy is STALE-COPY. A cache plugin the JSON does not list takes the
# newest-copy rule (one ACTIVE pl@mkt, or AMBIGUOUS-ACTIVE on a tie), with a
# NOTE naming it, and no global fallback NOTE.
# id | cache copies | json (other | user:<copy>) | plugin dir entries (- for none)
#    | card (- | cache:<copy> | ext:<n>) | expected active (<copy> | x:<n> | AMBIGUOUS-X | AMBIGUOUS) | expected plan
XCASES='
x-unreg-card|1.0.0:T1|other|e1|cache:1.0.0|x:e1|CHANGED from e1
x-unreg-new|1.0.0:T1|other|e1|-|x:e1|NEW e1
x-reg-card|1.0.0:T1|user:1.0.0|e1|cache:1.0.0|x:e1|CHANGED from e1
x-two|1.0.0:T1|other|e1,e2|ext:e1|AMBIGUOUS-X|DOWNGRADED
u-new|1.0.0:T1,2.0.0:T2|other|-|-|2.0.0|NEW 2.0.0
u-card|1.0.0:T1,2.0.0:T2|other|-|cache:2.0.0|2.0.0|UNCHANGED
u-old-card|1.0.0:T1,2.0.0:T2|other|-|cache:1.0.0|2.0.0|CHANGED from 2.0.0
u-tie|1.0.0:T2,2.0.0:T2|other|-|cache:2.0.0|AMBIGUOUS|DOWNGRADED
'
xcard() { # xcard <SKILL.md path>
  printf '%s\n\n## plugin:pl/rep\n\n```yaml\nname: rep\nsource: plugin:pl\npath: %s\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Reports.\n**Use when:** Reports.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** report\n**Examples:**\n- "a"\n- "b"\n' \
    '<!-- which-skill index v1 · updated 2026-11-16 -->' "$1" "$(cksum < "$1" | cut -d' ' -f1-2)"
}
xclassify() {
  local nc; nc="$(sed -n -e 's|^NOCARD [0-9]* [0-9]* .*/cache/mkt/pl/\([^/]*\)/skills/rep/SKILL.md$|\1|p' -e 's|^NOCARD [0-9]* [0-9]* .*/ext/\([^/]*\)/skills/rep/SKILL.md$|\1|p' "$1" | tr '\n' ' ')"
  if [ ! -f "$I" ]; then echo "NEW ${nc% }"
  elif ! grep -q '^GONE plugin:pl/rep ' "$1"; then echo UNCHANGED
  elif [ -n "$nc" ]; then echo "CHANGED from ${nc% }"
  else echo DOWNGRADED; fi
}
xdisc() {
  local sh="$1" out="$2"
  set -m; (cd "$P" && exec env HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" WHICH_SKILL_INDEX="$I" CLAUDE_CODE_PLUGIN_DIRS="$XD" CLAUDE_CODE_PLUGIN_SEED_DIR="${XSEED:-}" "$sh" -c "$DISC") > "$out" 2>&1 & local pid=$!; set +m
  PIDS="$PIDS $pid"; local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "rc=TIMEOUT"; return; fi
  wait "$pid"; echo "rc=$?"
}
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  while IFS='|' read -r id copies json xs cardc act want; do
    [ -n "$id" ] || continue
    C="$d/$sh-$id"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; PL="$H/.claude/plugins"; CA="$PL/cache/mkt/pl"
    mkdir -p "$P" "$C/idx" "$CA"
    names=""
    for cs in $(tr ',' ' ' <<< "$copies"); do
      n="${cs%:*}"; t="${cs##*:}"; case "$t" in T1) t=$T1;; T2) t=$T2;; esac
      mkcopy "$n" "$t"; names="$names $n"
    done
    r='{"scope": "user", "installPath": "/nowhere/zz"}'
    printf '{"version": 2, "plugins": {"zz@mkt": [%s]%s}}\n' "$r" "$( [ "$json" = other ] || printf ', "pl@mkt": [%s]' "$(rec user "${json#user:}")" )" > "$PL/installed_plugins.json"
    XD=""; xnames=""
    if [ "$xs" != - ]; then for n in $(tr ',' ' ' <<< "$xs"); do
      e="$C/ext/$n"; mkdir -p "$e/.claude-plugin" "$e/skills/rep"
      printf '{"name": "pl"}\n' > "$e/.claude-plugin/plugin.json"
      printf -- '---\nname: rep\ndescription: Reports.\n---\nbody of ext %s\n' "$n" > "$e/skills/rep/SKILL.md"
      XD="${XD:+$XD:}$e"; xnames="$xnames $n"
    done; fi
    case "$cardc" in cache:*) xcard "$CA/${cardc#cache:}/skills/rep/SKILL.md" > "$I";; ext:*) xcard "$C/ext/${cardc#ext:}/skills/rep/SKILL.md" > "$I";; esac
    for cs in $(tr ',' ' ' <<< "$copies"); do t="${cs##*:}"; [ "$t" = T1 ] && t=$T1 || t=$T2; touch -t "$t" "$CA/${cs%:*}"; done
    r="$(xdisc "$sh" "$C/out")"; o="$C/out"; L="$sh $id"
    [ "$r" = rc=0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 "$o")'"; continue; }
    ! grep -q '^NOTE installed_plugins.json missing' "$o" && ok "$L: no global fallback NOTE (the JSON was read)" || bad "$L: global fallback NOTE printed"
    al="$(grep -E '^(ACTIVE|AMBIGUOUS-ACTIVE) (pl@mkt|plugin-dir/pl)( |$)' "$o")"
    case "$act" in
      x:*) want_al="ACTIVE plugin-dir/pl $C/ext/${act#x:}";;
      AMBIGUOUS-X) want_al="AMBIGUOUS-ACTIVE plugin-dir/pl";;
      AMBIGUOUS) want_al="AMBIGUOUS-ACTIVE pl@mkt";;
      *) want_al="ACTIVE pl@mkt $CA/$act";;
    esac
    [ "$al" = "$want_al" ] && ok "$L: exactly '$want_al'" || bad "$L: active lines '$(tr '\n' ';' <<< "$al")', expected '$want_al'"
    case "$json:$xs" in user:*:e*) grep -qx 'SUPERSEDED pl@mkt by plugin-dir/pl' "$o" && ok "$L: the listed cache copy is SUPERSEDED" || bad "$L: no SUPERSEDED pl@mkt line";; esac
    case "$json:$xs" in other:-) grep -qx 'NOTE not listed in installed_plugins.json, so its newest copy by folder mtime is taken as active: pl@mkt' "$o" && ok "$L: NOTE names pl@mkt" || bad "$L: no NOTE for the unlisted pl@mkt";; esac
    for n in $names; do
      [ "$n" = "$act" ] && continue; f="$CA/$n/skills/rep/SKILL.md"
      grep -qxF "STALE-COPY $f" "$o" && ! grep -q "^NOCARD .*/pl/$n/" "$o" && ok "$L: cache $n is STALE-COPY, never NOCARD" || bad "$L: cache $n not STALE-COPY"
    done
    for n in $xnames; do
      [ "x:$n" = "$act" ] && continue; f="$C/ext/$n/skills/rep/SKILL.md"
      grep -qxF "STALE-COPY $f" "$o" && ! grep -q "^NOCARD .*/ext/$n/" "$o" && ok "$L: plugin dir $n is STALE-COPY, never NOCARD" || bad "$L: plugin dir $n not STALE-COPY"
    done
    got="$(xclassify "$o")"; [ "$got" = "$want" ] && ok "$L: plan $want" || bad "$L: plan '$got', expected '$want'"
    if [ "$want" = UNCHANGED ]; then chk CLAUDE_CODE_PLUGIN_DIRS="$XD" CLAUDE_CODE_PLUGIN_SEED_DIR="${XSEED:-}" >/dev/null && ok "$L: check-index --located OK" || bad "$L: check-index failed"; fi
  done <<< "$XCASES"
done

# Unlisted cache copies, by manifest name: u-reg-name, an unlisted pl@mkt whose
# manifest name `pl` is also the name of a listed plugin (folder pl2 in
# marketplace mk2), is SUPERSEDED by it (its files STALE-COPY, no NOTE for it);
# u-two-names, two unlisted keys pl@mkt and pl@mk2 with the same manifest name,
# give AMBIGUOUS-ACTIVE for both, and every copy is STALE-COPY.
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in u-reg-name u-two-names; do
    C="$d/$sh-$id"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; PL="$H/.claude/plugins"; XD=""; mkdir -p "$P" "$C/idx"
    CA="$PL/cache/mkt/pl"; mkcopy 1.0.0 $T1
    if [ "$id" = u-reg-name ]; then CA="$PL/cache/mk2/pl2"; mkcopy 3.0.0 $T1; CA="$PL/cache/mkt/pl"
      printf '{"version": 2, "plugins": {"pl2@mk2": [{"scope": "user", "installPath": "%s"}]}}\n' "$PL/cache/mk2/pl2/3.0.0" > "$PL/installed_plugins.json"
    else CA="$PL/cache/mk2/pl"; mkcopy 1.0.0 $T2; CA="$PL/cache/mkt/pl"
      printf '{"version": 2, "plugins": {"zz@mkt": [{"scope": "user", "installPath": "/nowhere/zz"}]}}\n' > "$PL/installed_plugins.json"; fi
    r="$(xdisc "$sh" "$C/out")"; o="$C/out"; L="$sh $id"
    [ "$r" = rc=0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 "$o")'"; continue; }
    if [ "$id" = u-reg-name ]; then
      grep -qx 'SUPERSEDED pl@mkt by pl2@mk2' "$o" && grep -qxF "ACTIVE pl2@mk2 $PL/cache/mk2/pl2/3.0.0" "$o" && ! grep -q '^ACTIVE pl@mkt ' "$o" && ok "$L: pl@mkt SUPERSEDED by the listed pl2@mk2" || bad "$L: $(grep -E '^(ACTIVE|AMBIGUOUS-ACTIVE|SUPERSEDED) ' "$o" | tr '\n' ';')"
      ! grep -q '^NOTE not listed.*pl@mkt' "$o" && ok "$L: no NOTE for the superseded key" || bad "$L: NOTE printed for a superseded key"
      grep -qxF "STALE-COPY $PL/cache/mkt/pl/1.0.0/skills/rep/SKILL.md" "$o" && grep -q "^NOCARD .*/mk2/pl2/3.0.0/skills/rep/SKILL.md$" "$o" && ok "$L: only the listed copy is located" || bad "$L: located files wrong"
    else
      grep -qx 'AMBIGUOUS-ACTIVE pl@mkt' "$o" && grep -qx 'AMBIGUOUS-ACTIVE pl@mk2' "$o" && ! grep -q '^ACTIVE pl@' "$o" && ok "$L: both unlisted keys AMBIGUOUS-ACTIVE" || bad "$L: $(grep -E '^(ACTIVE|AMBIGUOUS-ACTIVE|SUPERSEDED) ' "$o" | tr '\n' ';')"
      grep -qxF "STALE-COPY $PL/cache/mkt/pl/1.0.0/skills/rep/SKILL.md" "$o" && grep -qxF "STALE-COPY $PL/cache/mk2/pl/1.0.0/skills/rep/SKILL.md" "$o" && ! grep -q '^NOCARD ' "$o" && ok "$L: every copy is STALE-COPY" || bad "$L: a copy is still located"
    fi
  done
done

# Round 30: a listed key that does not end up cleanly ACTIVE still reserves its
# manifest names (tests/r30-fixture.sh has the table).
. "$HERE/r30-fixture.sh"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in $R30_CASES; do
    C="$d/$sh-r30-$id"; r30fix "$id" "$C"; H="$C/home"; P="$C/A"; I="$C/idx/index.md"; XD=""
    r="$(xdisc "$sh" "$C/out")"; L="$sh r30 $id"
    [ "$r" = rc=0 ] && tail -1 "$C/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 "$C/out")'"; continue; }
    e="$(r30check "$C/out")"; [ -z "$e" ] && ok "$L: SUPERSEDED by $R30_LK, no ACTIVE or NOCARD for pl, card GONE" || bad "$L: $(tr '\n' ';' <<< "$e")"
    case "$id" in unsafe) grep -qx 'UNSAFE-ACTIVE pl@mk2' "$C/out" && ok "$L: UNSAFE-ACTIVE carries the key" || bad "$L: no UNSAFE-ACTIVE pl@mk2";; esac
  done
done

# Round 31: CLAUDE_CODE_PLUGIN_DIRS entries that are refused (tests/r31-fixture.sh).
. "$HERE/r31-fixture.sh"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in $R31_CASES; do
    C="$d/$sh-r31-$id"; r31fix "$id" "$C"; H="$C/home"; P="$C/A"; I="$C/idx/index.md"; XD="$R31_DIRS"
    XSEED="$C/seed"; r31pl "$C/seed/ss" ss rs
    r="$(xdisc "$sh" "$C/out")"; L="$sh r31 $id"; XSEED=""
    [ "$r" = rc=0 ] && tail -1 "$C/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 "$C/out")'"; continue; }
    e="$(r31check "$id" "$C/out")"; [ -z "$e" ] && ok "$L: as expected" || bad "$L: $(tr '\n' ';' <<< "$e")"
    sf="$C/seed/ss/skills/rs/SKILL.md"
    if [ "$id" = safe ]; then grep -q "^NOCARD .* $sf\$" "$C/out" && ok "$L: the seed copy is located as before" || bad "$L: seed copy not located"
    else grep -qxF "STALE-COPY $sf" "$C/out" && ok "$L: the seed copy is not trusted (STALE-COPY)" || bad "$L: seed copy still located"; fi
  done
done

# Round 32: a plugin dir entry refused after expansion, or whose manifest is
# rejected or nameless (tests/r32-fixture.sh).
. "$HERE/r32-fixture.sh"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in $R32_CASES; do
    C="$d/$sh-r32-$id"; r32fix "$id" "$C"; L="$sh r32 $id"; r="$(r32disc "$sh" "$C" "$C/out")"
    [ "$r" = rc=0 ] && tail -1 "$C/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 "$C/out")'"; continue; }
    e="$(r32check "$id" "$C" "$C/out")"; [ -z "$e" ] && ok "$L: refused entry, leftover and seed not trusted" || bad "$L: $(tr '\n' ';' <<< "$e")"
  done
done

# Round 33: symlinked cache levels, and the unkeyed-file invariant
# (tests/r33-fixture.sh).
. "$HERE/r33-fixture.sh"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for id in $R33_LINK $R33_INV; do
    C="$d/$sh-r33-$id"; r33fix "$id" "$C"; L="$sh r33 $id"; r="$(r33disc "$id" "$sh" "$C" "$C/out")"
    [ "$r" = rc=0 ] && tail -1 "$C/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 "$C/out")'"; continue; }
    case " $R33_LINK " in *" $id "*) e="$(r32check noname "$C" "$C/out")";; *) e="$(r33inv "$id" "$C" "$C/out")";; esac
    [ -z "$e" ] && ok "$L: as expected" || bad "$L: $(tr '\n' ';' <<< "$e")"
  done
done

# Round 33b: a failing key enumeration (cache or synced) fails discovery. A
# PATH shim makes only the enumeration's `find <root> ... -maxdepth 2` fail
# (exit 1, no output) for SHIM_TARGET; every other find runs normally.
mkdir -p "$d/shim"; FIND="$(command -v find)"
printf '#!/bin/sh\nt=0; m=0\nfor a; do [ "$a" = "$SHIM_TARGET" ] && t=1; [ "$a" = -maxdepth ] && m=1; done\nif [ $t = 1 ] && [ $m = 1 ]; then echo "find: injected failure" >&2; exit 1; fi\nexec %s "$@"\n' "$FIND" > "$d/shim/find"; chmod 700 "$d/shim/find"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for tg in cache synced; do
    C="$d/$sh-r33b-$tg"; PL="$C/cfg/plugins"; mkdir -p "$C/A" "$C/idx"
    r32pl "$PL/cache/mkt/qq/1.0" qq rq; r32pl "$PL/synced/ID/sb" sb rs
    printf '{"version": 2, "plugins": {"zz@mkt": [{"scope": "user", "installPath": "/nowhere/zz"}]}}\n' > "$PL/installed_plugins.json"
    (cd "$C/A" && exec env PATH="$d/shim:$PATH" SHIM_TARGET="$PL/$tg" HOME="$C" CLAUDE_CONFIG_DIR="$C/cfg" WHICH_SKILL_INDEX="$C/idx/index.md" \
      CLAUDE_CODE_PLUGIN_DIRS= CLAUDE_CODE_PLUGIN_SEED_DIR= "$sh" -c "$DISC") > "$C/out" 2>&1; rc=$?; L="$sh r33b $tg"
    [ "$rc" -ne 0 ] && grep -qx 'DISCOVERY FAILED: cannot enumerate the plugin keys' "$C/out" && tail -1 "$C/out" | grep -qx 'DISCOVERY INCOMPLETE' && ! grep -q '^DISCOVERY OK' "$C/out" \
      && ok "$L: enumeration failure gives DISCOVERY FAILED and INCOMPLETE (rc=$rc)" || bad "$L: rc=$rc, last line '$(tail -1 "$C/out")'"
  done
done

# Round 38: the record and PLUG spell the same path with different slash
# counts. The active copy must stay ACTIVE (card UNCHANGED, no STALE-COPY of
# it): a doubled and trailing slash in installPath, a trailing slash on
# CLAUDE_CONFIG_DIR, a projectPath with // and a trailing slash, and a
# CLAUDE_CODE_PLUGIN_DIRS entry with //. A . or .. component in installPath
# is never made active.
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for v in ip-slashes cfg-trailing pp-slashes ip-dotdot pd-slashes; do
    C="$d/$sh-r38-$v"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; PL="$H/.claude/plugins"; CA="$PL/cache/mkt/pl"
    mkdir -p "$P" "$C/idx" "$CA"; mkcopy 1.0.0 $T2; mkcopy 2.0.0 $T1
    cfg="$H/.claude"; ip="$CA/2.0.0"; xd=""
    case "$v" in
      ip-slashes) ip="$H/.claude//plugins/cache//mkt/pl/2.0.0/"; r="$(printf '{"scope": "user", "installPath": "%s"}' "$ip")";;
      cfg-trailing) cfg="$H/.claude/"; r="$(rec user 2.0.0)";;
      pp-slashes) r="$(rec user 1.0.0), $(printf '{"scope": "project", "installPath": "%s", "projectPath": "%s"}' "$CA//2.0.0" "$P//")";;
      ip-dotdot) r="$(printf '{"scope": "user", "installPath": "%s"}' "$CA/x/../2.0.0")";;
      pd-slashes) mkdir -p "$C/pd/pp/.claude-plugin" "$C/pd/pp/skills/dd"; printf '{"name": "pp"}\n' > "$C/pd/pp/.claude-plugin/plugin.json"
        printf -- '---\nname: dd\ndescription: D.\n---\n' > "$C/pd/pp/skills/dd/SKILL.md"; xd="$C//pd//pp/"; r="$(rec user 2.0.0)";;
    esac
    printf '{"version": 2, "plugins": {"pl@mkt": [%s]}}\n' "$r" > "$PL/installed_plugins.json"
    card 2.0.0 > "$I"
    (cd "$P" && exec env HOME="$H" CLAUDE_CONFIG_DIR="$cfg" WHICH_SKILL_INDEX="$I" CLAUDE_CODE_PLUGIN_DIRS="$xd" CLAUDE_CODE_PLUGIN_SEED_DIR= "$sh" -c "$DISC") > "$C/out" 2>&1; rc=$?; L="$sh r38 $v"; o="$C/out"
    [ "$rc" = 0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' || { bad "$L: rc=$rc, last line '$(tail -1 "$o")'"; continue; }
    if [ "$v" = ip-dotdot ]; then
      grep -qx 'UNSAFE-ACTIVE pl@mkt' "$o" && ! grep -q '^ACTIVE pl@mkt' "$o" && ok "$L: a .. component is UNSAFE-ACTIVE, never ACTIVE" || bad "$L: $(grep -E '^(ACTIVE|UNSAFE|AMBIG)' "$o" | tr '\n' ' ')"
      continue
    fi
    [ "$(grep -c '^ACTIVE pl@mkt ' "$o")" -eq 1 ] && grep -qxF "ACTIVE pl@mkt $CA/2.0.0" "$o" && ok "$L: ACTIVE pl@mkt $CA/2.0.0 (single slashes)" || bad "$L: ACTIVE lines: $(grep -E '^(ACTIVE|AMBIG|UNSAFE)' "$o" | tr '\n' ' ')"
    ! grep -q "^STALE-COPY .*/2.0.0/" "$o" && [ "$(classify "$o")" = UNCHANGED ] && ok "$L: card UNCHANGED, no STALE-COPY of the active copy" || bad "$L: plan $(classify "$o"); $(grep -E '^(STALE-COPY|GONE)' "$o" | tr '\n' ' ')"
    ! grep -q '//' "$o" && ok "$L: no // in the output" || bad "$L: // in: $(grep '//' "$o" | head -3 | tr '\n' ' ')"
    if [ "$v" = pd-slashes ]; then grep -qx "ACTIVE plugin-dir/pp $C/pd/pp" "$o" && ok "$L: ACTIVE plugin-dir/pp with single slashes" || bad "$L: $(grep 'plugin-dir' "$o" | tr '\n' ' ')"; fi
  done
done

# Round 39a: HOME ends with a slash and CLAUDE_CONFIG_DIR is unset. The card
# path ~/... expands with the same single-slash rule as discovery, so the
# card stays UNCHANGED and no // is printed.
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  C="$d/$sh-r39-home"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; PL="$H/.claude/plugins"; CA="$PL/cache/mkt/pl"
  mkdir -p "$P" "$C/idx" "$CA"; mkcopy 2.0.0 $T1
  printf '{"version": 2, "plugins": {"pl@mkt": [%s]}}\n' "$(rec user 2.0.0)" > "$PL/installed_plugins.json"; card 2.0.0 > "$I"
  (cd "$P" && exec env -u CLAUDE_CONFIG_DIR HOME="$H/" WHICH_SKILL_INDEX="$I" CLAUDE_CODE_PLUGIN_DIRS= CLAUDE_CODE_PLUGIN_SEED_DIR= "$sh" -c "$DISC") > "$C/out" 2>&1; rc=$?; L="$sh r39 home-trailing"; o="$C/out"
  [ "$rc" = 0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' && [ "$(classify "$o")" = UNCHANGED ] && ! grep -q '^NOCARD ' "$o" && ok "$L: card UNCHANGED, no NOCARD" || bad "$L: rc=$rc plan $(classify "$o"); $(grep -E '^(GONE|NOCARD)' "$o" | tr '\n' ' ')"
  ! grep -q '//' "$o" && ok "$L: no // in the output" || bad "$L: // in: $(grep '//' "$o" | head -3 | tr '\n' ' ')"
done

# Round 39b: / (or ////) in CLAUDE_CODE_PLUGIN_DIRS or CLAUDE_CODE_PLUGIN_SEED_DIR
# is refused as a root and never searched. A find shim logs and refuses any
# call with / as an argument (so a regression cannot scan the whole disk).
mkdir -p "$d/shim39"
printf '#!/bin/sh\nfor a; do if [ "$a" = / ]; then echo HIT >> "$SHIM_LOG"; exit 1; fi; done\nexec %s "$@"\n' "$FIND" > "$d/shim39/find"; chmod 700 "$d/shim39/find"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for var in CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR; do
    for val in / ////; do
      C="$d/$sh-r39-$var-${#val}"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; mkdir -p "$P" "$C/idx" "$H/.claude/skills/s1"
      printf -- '---\nname: s1\ndescription: x\n---\n' > "$H/.claude/skills/s1/SKILL.md"; : > "$C/log"
      pd=; sd=; [ "$var" = CLAUDE_CODE_PLUGIN_DIRS ] && pd="$val" || sd="$val"
      (cd "$P" && exec env PATH="$d/shim39:$PATH" SHIM_LOG="$C/log" HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" WHICH_SKILL_INDEX="$I" \
        CLAUDE_CODE_PLUGIN_DIRS="$pd" CLAUDE_CODE_PLUGIN_SEED_DIR="$sd" "$sh" -c "$DISC") > "$C/out" 2>&1; rc=$?; L="$sh r39 $var=$val"; o="$C/out"
      if [ ! -s "$C/log" ] && grep -qx 'UNSAFE-ROOT /' "$o" && [ "$rc" = 0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' && ! grep -qx 'ROOT_DIR /' "$o"; then
        ok "$L: refused (UNSAFE-ROOT /), find never sees /"
      else bad "$L: rc=$rc log=$(wc -l < "$C/log" | tr -d ' ') $(grep -E '^(UNSAFE-ROOT|ROOT_DIR|DISCOVERY|NOTE)' "$o" | tr '\n' ' ')"; fi
      if [ "$var" = CLAUDE_CODE_PLUGIN_DIRS ]; then grep -q '^NOTE a CLAUDE_CODE_PLUGIN_DIRS entry was refused' "$o" && ok "$L: NOTE printed" || bad "$L: no NOTE"; fi
    done
  done
done

# Round 40: roots that reach / through . or .. or a symlink. The shim
# resolves each argument that is a folder with cd -P and refuses (logging)
# any whose canonical path is /; it also refuses any folder outside the
# test's temp folder, so a regression can never walk a large tree (on macOS
# /tmp/.. and /var/.. are /private, not /).
mkdir -p "$d/shim40"
printf '#!/bin/sh\nfor a; do c="$(cd -P -- "$a" 2>/dev/null && pwd -P)" || continue\n  [ "$c" = / ] && { echo "HIT / from $a" >> "$SHIM_LOG"; exit 1; }\n  case "$c/" in "$SHIM_BASE"/*) ;; *) echo "OUT $c from $a" >> "$SHIM_LOG"; exit 1;; esac; done\nexec %s "$@"\n' "$FIND" > "$d/shim40/find"; chmod 700 "$d/shim40/find"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for var in CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR; do
    for kind in tmpdotdot vardotdot reldot rootlink; do
      C="$d/$sh-r40-$var-$kind"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; mkdir -p "$P" "$C/idx" "$H/.claude/skills/s1"
      printf -- '---\nname: s1\ndescription: x\n---\n' > "$H/.claude/skills/s1/SKILL.md"; : > "$C/log"
      case "$kind" in tmpdotdot) val=/tmp/..;; vardotdot) val=/var/..;; reldot) val=./x; mkdir -p "$P/x";; rootlink) ln -s / "$C/rootlink"; val="$C/rootlink";; esac
      pd=; sd=; [ "$var" = CLAUDE_CODE_PLUGIN_DIRS ] && pd="$val" || sd="$val"
      (cd "$P" && exec env PATH="$d/shim40:$PATH" SHIM_LOG="$C/log" SHIM_BASE="$d" HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" WHICH_SKILL_INDEX="$I" \
        CLAUDE_CODE_PLUGIN_DIRS="$pd" CLAUDE_CODE_PLUGIN_SEED_DIR="$sd" "$sh" -c "$DISC") > "$C/out" 2>&1; rc=$?; L="$sh r40 $var=$kind"; o="$C/out"
      if [ ! -s "$C/log" ] && [ "$rc" = 0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' && grep -q "$H/.claude/skills/s1/SKILL.md" "$o"; then ok "$L: / never walked, DISCOVERY OK"
      else bad "$L: rc=$rc log=$(tr '\n' ' ' < "$C/log") $(grep -E '^(UNSAFE-ROOT|ROOT_DIR|DISCOVERY)' "$o" | tr '\n' ' ')"; fi
      [ "$kind" = reldot ] && continue   # a relative entry is skipped, as documented
      grep -q '^UNSAFE-ROOT ' "$o" && ok "$L: UNSAFE-ROOT" || bad "$L: no UNSAFE-ROOT"
      if [ "$var" = CLAUDE_CODE_PLUGIN_DIRS ]; then grep -q '^NOTE a CLAUDE_CODE_PLUGIN_DIRS entry was refused' "$o" && ok "$L: NOTE printed" || bad "$L: no NOTE"; fi
    done
  done
done

# Round 41: a refused root was not inspected, so its cards are UNKNOWN, not
# GONE. A card under the cache is first UNCHANGED; then the same cache is
# configured as <cfg>/x/../plugins (refused for its .. component). Encoded
# plan rules (this test's reading of index.md): a card on a GONE line whose
# skill is not in the session becomes `not installed`; a card on an UNKNOWN
# line keeps its status. Encoded shortlist rule (search-and-answer.md): a
# card on a GONE or UNKNOWN line is judged `unverified`.
plan41() { # plan41 <out> <in-session yes|no>
  if grep -q '^GONE plugin:pl/rep ' "$1"; then [ "$2" = no ] && echo "not installed" || echo downgraded
  elif grep -q '^UNKNOWN plugin:pl/rep ' "$1"; then echo installed; else echo installed; fi; }
short41() { grep -qE '^(GONE|UNKNOWN) plugin:pl/rep ' "$1" && echo unverified || echo verified; }
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  C="$d/$sh-r41"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; PL="$H/.claude/plugins"; CA="$PL/cache/mkt/pl"
  mkdir -p "$P" "$C/idx" "$CA" "$H/.claude/x"; mkcopy 2.0.0 $T1
  printf '{"version": 2, "plugins": {"pl@mkt": [%s]}}\n' "$(rec user 2.0.0)" > "$PL/installed_plugins.json"; card 2.0.0 > "$I"
  for cache in "$PL" "$H/.claude/x/../plugins"; do
    (cd "$P" && exec env HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" CLAUDE_CODE_PLUGIN_CACHE_DIR="$cache" WHICH_SKILL_INDEX="$I" CLAUDE_CODE_PLUGIN_DIRS= CLAUDE_CODE_PLUGIN_SEED_DIR= "$sh" -c "$DISC") > "$C/out" 2>&1; rc=$?; o="$C/out"
    if [ "$cache" = "$PL" ]; then L="$sh r41 safe cache"
      [ "$rc" = 0 ] && [ "$(classify "$o")" = UNCHANGED ] && ! grep -q '^ROOTS-INCOMPLETE' "$o" && ok "$L: card UNCHANGED, no ROOTS-INCOMPLETE" || bad "$L: rc=$rc plan $(classify "$o")"
      continue; fi
    L="$sh r41 refused cache"
    [ "$rc" = 0 ] && tail -1 "$o" | grep -q '^DISCOVERY OK' && grep -q '^UNSAFE-ROOT ' "$o" && grep -qx 'ROOTS-INCOMPLETE' "$o" && ok "$L: UNSAFE-ROOT and ROOTS-INCOMPLETE" || bad "$L: rc=$rc $(grep -E '^(UNSAFE-ROOT|ROOTS|DISCOVERY)' "$o" | tr '\n' ' ')"
    grep -q '^UNKNOWN plugin:pl/rep ' "$o" && ! grep -q '^GONE ' "$o" && ok "$L: UNKNOWN, no GONE" || bad "$L: $(grep -E '^(GONE|UNKNOWN)' "$o" | tr '\n' ' ')"
    [ "$(plan41 "$o" no)" = installed ] && ok "$L: status stays installed (skill not in the session)" || bad "$L: plan $(plan41 "$o" no)"
    [ "$(short41 "$o")" = unverified ] && ok "$L: unverified at shortlist" || bad "$L: shortlist $(short41 "$o")"
  done
done
grep -q '^- `UNKNOWN ' "$DOC" && grep -q '^- `ROOTS-INCOMPLETE' "$DOC" && ok "index.md names UNKNOWN and ROOTS-INCOMPLETE" || bad "index.md lacks UNKNOWN or ROOTS-INCOMPLETE"
grep -q 'UNKNOWN' "$HERE/../references/search-and-answer.md" && ok "search-and-answer.md names UNKNOWN" || bad "search-and-answer.md lacks UNKNOWN"

for w in '^- `ACTIVE ' '^- `STALE-COPY ' '^- `AMBIGUOUS-ACTIVE ' 'projectPath' 'mtime' 'highest' 'ACTIVE synced/' 'ACTIVE plugin-dir/' 'AMBIGUOUS-ACTIVE plugin-dir/' '^- `SUPERSEDED ' 'not listed in installed_plugins.json' '^- `UNSAFE-ACTIVE ' 'entry was refused' '^- `UNKEYED '; do
  grep -q -- "$w" "$DOC" && ok "index.md names $w" || bad "index.md does not name $w"
done
grep -q 'assumption' <<< "$(grep -n 'projectPath' "$DOC")" && ok "index.md states the scope precedence as an assumption" || bad "index.md: scope precedence not stated as an assumption"
grep -qi 'active copy' "$SK" && grep -q 'AMBIGUOUS-ACTIVE' "$SK" && ok "SKILL.md names the active copy and AMBIGUOUS-ACTIVE" || bad "SKILL.md lacks the active copy or AMBIGUOUS-ACTIVE"
# Round 44: check-index --located takes this run's discovery. Copy 1.0.0 is a
# regular file but a STALE-COPY (installed_plugins.json makes 2.0.0 active);
# a card on 1.0.0 must fail until the card is on 2.0.0.
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  C="$d/$sh-r44"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; PL="$H/.claude/plugins"; CA="$PL/cache/mkt/pl"; L="$sh r44"
  mkdir -p "$P" "$C/idx" "$CA"; mkcopy 1.0.0 $T1; mkcopy 2.0.0 $T2
  printf '{"version": 2, "plugins": {"pl@mkt": [%s]}}\n' "$(rec user 2.0.0)" > "$PL/installed_plugins.json"
  card 1.0.0 > "$I"; r="$(disc "$sh" "$C/out")"
  [ "$r" = rc=0 ] && grep -qxF "STALE-COPY $CA/1.0.0/skills/rep/SKILL.md" "$C/out" && [ -f "$CA/1.0.0/skills/rep/SKILL.md" ] && ok "$L: 1.0.0 is regular and STALE-COPY" || bad "$L: fixture $r"
  ci="$(chk)"; rc=$?
  [ "$rc" -ne 0 ] && grep -q '^FAIL card ## plugin:pl/rep: .*not located in this run' <<< "$ci" && ok "$L: card on the stale 1.0.0 fails check-index --located" || bad "$L: card on 1.0.0 accepted: $(tail -2 <<< "$ci" | tr '\n' ' ')"
  card 2.0.0 > "$I"; ci="$(chk)"; rc=$?
  [ "$rc" -eq 0 ] && grep -qx 'INDEX OK' <<< "$ci" && ok "$L: card on the active 2.0.0: INDEX OK" || bad "$L: card on 2.0.0: $(grep FAIL <<< "$ci" | tr '\n' ' ')"
done
if [ "$BAD" -eq 0 ]; then echo "TEST ACTIVE-COPY OK"; exit 0; else echo "TEST ACTIVE-COPY FAILED ($BAD)"; exit 1; fi
