#!/usr/bin/env bash
# Sandbox test of three discovery edge cases (no claude run), each under bash
# and zsh, with the discovery block extracted verbatim from index.md:
#   A. a newline inside the working folder, the git top folder or
#      CLAUDE_CONFIG_DIR tries to inject a second root that exists; that root
#      must not be walked (its "secret" skill never appears), an UNSAFE-ROOT
#      line is printed, and discovery still ends DISCOVERY OK;
#   B. an existing index that cannot be read (mode 0000 or 0200) must not give
#      DISCOVERY OK; a readable one (0400) still does;
#   C. a SKILL.md symlinked to a FIFO or to /dev/zero, and a plugin manifest
#      symlinked to a FIFO, must not hang: discovery finishes within the
#      watchdog, reports SKIPPED-NONREGULAR, and still lists the good skill;
#   D. symlinks whose canonical target leaves the skill folders: a SKILL.md
#      linked to an external secret (canary name), a commands/x.md linked to an
#      external non-.md file and a plugin manifest linked outside give
#      SKIPPED-OUTSIDE-ROOT, no cksum line, no PLUGIN line and no canary text;
#      a verified card of the leaking skill comes out GONE and check-index
#      --located rejects it; a whole skill folder symlinked from outside (the
#      ~/dev case), a SKILL.md linked into a same-named folder outside, a
#      command linked into an outside commands/ folder and a symlink into
#      another discovery root stay accepted; a SKILL.md linked into a folder of
#      another name outside is rejected; index.md names the line in its
#      never-Read rule;
#   E. a plugin whose plugin.json is rejected (a symlink outside the skill
#      folders, a FIFO, a dangling symlink, a folder, a non-empty folder with a
#      nested manifest and SKILL.md, a symlink to an outside folder holding a
#      canary file and a nested manifest, or at an unsafe path; nothing below
#      a manifest folder is visited),
#      with a regular SKILL.md and a pre-existing verified card: PLUGIN-REJECTED
#      for the plugin folder, its SKILL.md is never fingerprinted (no NOCARD,
#      UNCHANGED 0, SKIPPED-REJECTED-PLUGIN or UNSAFE-PATH), the card comes out
#      GONE and check-index --located rejects it;
#   F. a SKILL.md and a commands/x.md that are a folder or a symlink to an
#      outside folder (each holding a canary and a nested manifest), and
#      node_modules and .trash folders holding a symlink loop, an unreadable
#      folder (entering it would fail find) and a canary SKILL.md: DISCOVERY OK with no DISCOVERY FAILED, no line names a canary
#      or a path below them, and no nested PLUGIN line.
# Exit 0 = every check as expected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; DOC="$HERE/../references/index.md"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"
PIDS=""; trap 'for p in $PIDS; do kill -9 -- -"$p" 2>/dev/null; done; chmod -R u+rwx "$d" 2>/dev/null; rm -rf "$d"' EXIT
BAD=0; ok() { echo "ok     $1"; }; bad() { BAD=$((BAD+1)); echo "NOT OK $1"; }
DISC="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"DISCOVERY OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$DISC" ] || { echo "ABORT: discovery block not found"; exit 2; }
NL='
'
unset CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR WHICH_SKILL_INDEX
export HOME="$d/home"
mkskill() { mkdir -p "$1/$2"; printf -- '---\nname: %s\n---\nbody\n' "$2" > "$1/$2/SKILL.md"; }
mkskill "$HOME/.claude/skills" good

# disc <shell> <cwd> <outfile> [VAR=value...]: runs discovery with a 10 s
# watchdog in its own process group; prints "rc=<n>" or "rc=TIMEOUT".
disc() {
  local sh="$1" cwd="$2" out="$3"; shift 3
  set -m; (cd "$cwd" && exec env "$@" "$sh" -c "$DISC") > "$out" 2>&1 & local pid=$!; set +m
  PIDS="$PIDS $pid"; local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "rc=TIMEOUT"; return; fi
  wait "$pid"; echo "rc=$?"
}

# A. root injection through a newline
mkskill "$d/inj/.claude/skills" secret_cwd           # reachable only via the CWD newline
mkskill "$d/inj3/.claude/skills" secret_root         # reachable only via the ROOT newline
mkskill "$d/inj4/skills" secret_cfg                  # reachable only via the CLAUDE_CONFIG_DIR newline
CWD_EVIL="$d/a${NL}s $d/inj"; mkdir -p "$CWD_EVIL"
REPO="$d/b${NL}s $d/inj3"; mkdir -p "$REPO/sub"; git -C "$REPO" init -q 2>/dev/null || echo "SKIP   git init failed"
mkdir -p "$d/plain"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP   $sh not found"; continue; }
  for c in cwd root cfg; do
    case "$c" in
      cwd) r="$(disc "$sh" "$CWD_EVIL" "$d/out" HOME="$HOME")";;
      root) r="$(disc "$sh" "$REPO/sub" "$d/out" HOME="$HOME")";;
      cfg) r="$(disc "$sh" "$d/plain" "$d/out" HOME="$HOME" CLAUDE_CONFIG_DIR="$d/cfg${NL}s $d/inj4")";;
    esac
    out="$(cat "$d/out")"
    if grep -q 'secret_' <<< "$out"; then bad "$sh $c: an injected root was walked: $(grep secret_ <<< "$out" | head -2)"; else ok "$sh $c: injected root not walked"; fi
    grep -q '^UNSAFE-ROOT ' <<< "$out" && ok "$sh $c: UNSAFE-ROOT reported" || bad "$sh $c: no UNSAFE-ROOT line"
    [ "$r" = rc=0 ] && tail -1 <<< "$out" | grep -q '^DISCOVERY OK' && ok "$sh $c: DISCOVERY OK" || bad "$sh $c: $r, last line '$(tail -1 <<< "$out")'"
  done
done

# B. an existing index that cannot be read
G="$HOME/.claude/skills/good/SKILL.md"; FP="$(cksum < "$G")"
IDX="$d/idx/index.md"; mkdir -p "$d/idx"
printf '%s\n\n## user/good\n\n```yaml\nname: good\nsource: user\npath: ~/.claude/skills/good/SKILL.md\nfingerprint: %s\nstatus: installed\n```\n' '<!-- which-skill index v1 · updated 2026-11-16 -->' "$FP" > "$IDX"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for m in 000 200 400; do
    chmod "$m" "$IDX"
    r="$(disc "$sh" "$d/plain" "$d/out" HOME="$HOME" WHICH_SKILL_INDEX="$IDX")"; out="$(cat "$d/out")"
    if [ "$m" = 400 ]; then
      [ "$r" = rc=0 ] && grep -qx 'UNCHANGED 1' <<< "$out" && ok "$sh index $m: read, UNCHANGED 1" || bad "$sh index $m: $r, $(tail -2 <<< "$out" | tr '\n' ' ')"
    else
      if [ "$r" != rc=0 ] && ! grep -q '^DISCOVERY OK' <<< "$out" && grep -q '^DISCOVERY FAILED' <<< "$out"; then ok "$sh index $m: DISCOVERY FAILED, no DISCOVERY OK"; else bad "$sh index $m: $r, $(tail -2 <<< "$out" | tr '\n' ' ')"; fi
    fi
  done
  chmod 600 "$IDX"
done

# C. non-regular targets behind -L
mkfifo "$d/fifo1" "$d/fifo2"
mkdir -p "$HOME/.claude/skills/fifo" "$HOME/.claude/skills/zero" "$HOME/.claude/plugins/cache/m/pl/1.0/.claude-plugin"
ln -s "$d/fifo1" "$HOME/.claude/skills/fifo/SKILL.md"
ln -s /dev/zero "$HOME/.claude/skills/zero/SKILL.md"
ln -s "$d/fifo2" "$HOME/.claude/plugins/cache/m/pl/1.0/.claude-plugin/plugin.json"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  r="$(disc "$sh" "$d/plain" "$d/out" HOME="$HOME")"; out="$(cat "$d/out")"
  [ "$r" != rc=TIMEOUT ] && ok "$sh: finished within the watchdog" || bad "$sh: discovery hung (killed after 10 s)"
  [ "$(grep -c '^SKIPPED-NONREGULAR ' <<< "$out")" -eq 3 ] && ok "$sh: 3 SKIPPED-NONREGULAR lines" || bad "$sh: SKIPPED-NONREGULAR lines: $(grep -c '^SKIPPED-NONREGULAR ' <<< "$out")"
  [ "$r" = rc=0 ] && grep -q '/good/SKILL.md$' <<< "$out" && tail -1 <<< "$out" | grep -q '^DISCOVERY OK' && ok "$sh: good skill listed, DISCOVERY OK" || bad "$sh: $r, last line '$(tail -1 <<< "$out")'"
done

# D. symlinks whose canonical target is outside every discovery root
CHECK="$HERE/check-index.sh"
mkdir -p "$d/ext/sub" "$d/dev/tool" "$d/dev/tool2" "$d/dev/other" "$d/ext2/commands" "$d/projD/.claude/skills/shared"
printf 'SECRET CONTENT\n' > "$d/ext/sub/secret-CANARY-7f3a.txt"
printf 'NOTES CONTENT\n' > "$d/ext/notes-CANARY-9c1d.txt"
printf '{"name": "leaked-CANARY"}\n' > "$d/ext/manifest-CANARY.json"
printf -- '---\nname: tool\n---\ntool body\n' > "$d/dev/tool/SKILL.md"
printf -- '---\nname: tool2\n---\ntool2 body\n' > "$d/dev/tool2/SKILL.md"
printf -- '---\nname: other\n---\nother body\n' > "$d/dev/other/SKILL.md"
printf -- 'y command\n' > "$d/ext2/commands/y.md"
S="$HOME/.claude/skills"; CP="$HOME/.claude/plugins/cache/m/cp/1.0"; MP="$HOME/.claude/plugins/cache/m/mp/1.0"
mkdir -p "$S/leak" "$S/tool2" "$S/wrongname" "$CP/commands" "$CP/.claude-plugin" "$MP/.claude-plugin" "$MP/skills/ms"
ln -s "$d/ext/sub/secret-CANARY-7f3a.txt" "$S/leak/SKILL.md"           # rejected: secret file
ln -s "$d/dev/tool" "$S/tool"                                          # accepted: whole folder from ~/dev
ln -s "$d/dev/tool2/SKILL.md" "$S/tool2/SKILL.md"                      # accepted: same-named folder
ln -s "$d/dev/other/SKILL.md" "$S/wrongname/SKILL.md"                  # rejected: folder name differs
printf '{"name": "cp"}\n' > "$CP/.claude-plugin/plugin.json"
ln -s "$d/ext/notes-CANARY-9c1d.txt" "$CP/commands/x.md"               # rejected: non-.md target
ln -s "$d/ext2/commands/y.md" "$CP/commands/y.md"                      # rejected (Codex adiados r13): a command must stay inside a root
ln -s "$d/ext/manifest-CANARY.json" "$MP/.claude-plugin/plugin.json"   # rejected manifest
printf -- '---\nname: ms\n---\nms body\n' > "$MP/skills/ms/SKILL.md"
ln -s "$S/good/SKILL.md" "$d/projD/.claude/skills/shared/SKILL.md"     # accepted: into another root
# a verified card of `leak`, built while its SKILL.md was still a regular file
IDXD="$d/idxD/index.md"; mkdir -p "$d/idxD"
printf -- '---\nname: leak\n---\nold body\n' > "$d/oldleak"; FPL="$(cksum < "$d/oldleak" | cut -d' ' -f1-2)"
printf '%s\n\n## user/leak\n\n```yaml\nname: leak\nsource: user\npath: ~/.claude/skills/leak/SKILL.md\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Leaks.\n**Use when:** Never.\n**Don'"'"'t use when:** Always.\n**Depends on:** Nothing special.\n**Keywords:** leak\n**Examples:**\n- "a"\n- "b"\n' \
  '<!-- which-skill index v1 · updated 2026-11-16 -->' "$FPL" > "$IDXD"
ck() { grep -E '^NOCARD [0-9]+ [0-9]+ ' <<< "$out" | cut -d' ' -f4- | grep -qxF "$1"; }
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  r="$(disc "$sh" "$d/projD" "$d/out" HOME="$HOME" WHICH_SKILL_INDEX="$IDXD")"; out="$(cat "$d/out")"
  [ "$r" = rc=0 ] && tail -1 <<< "$out" | grep -q '^DISCOVERY OK' && ok "$sh D: DISCOVERY OK" || { bad "$sh D: $r, last line '$(tail -1 <<< "$out")'"; continue; }
  for f in "$S/leak/SKILL.md" "$S/wrongname/SKILL.md" "$CP/commands/x.md" "$MP/.claude-plugin/plugin.json"; do
    grep -qxF "SKIPPED-OUTSIDE-ROOT $f" <<< "$out" && ok "$sh D: SKIPPED-OUTSIDE-ROOT ${f#$HOME/}" || bad "$sh D: no SKIPPED-OUTSIDE-ROOT for ${f#$HOME/}"
    if grep -F "$f" <<< "$out" | grep -vF "SKIPPED-OUTSIDE-ROOT $f" | grep -qv '^GONE '; then bad "$sh D: ${f#$HOME/} on another line: $(grep -F "$f" <<< "$out" | grep -vF SKIPPED-OUTSIDE-ROOT | head -2)"; else ok "$sh D: ${f#$HOME/} only on its SKIPPED-OUTSIDE-ROOT line (and a GONE line; no cksum, NOCARD or CHANGED line)"; fi
  done
  grep -q 'CANARY' <<< "$out" && bad "$sh D: canary text in the output: $(grep CANARY <<< "$out" | head -2)" || ok "$sh D: no canary text in the output"
  grep -qx 'PLUGIN_NONAME .*\|PLUGIN leaked.*' <<< "$out" && bad "$sh D: the outside manifest was read" || ok "$sh D: the outside manifest was not read"
  grep -q '^GONE user/leak | ' <<< "$out" && ! grep -q '^CHANGED user/leak ' <<< "$out" && ok "$sh D: the verified card of leak is GONE (downgraded)" || bad "$sh D: no GONE line for user/leak"
  grep -qxF "SKIPPED-OUTSIDE-ROOT $CP/commands/y.md" <<< "$out" && ok "$sh D: a command linked to an outside commands/ folder is refused" || bad "$sh D: $CP/commands/y.md not refused"
  for f in "$S/tool/SKILL.md" "$S/tool2/SKILL.md" "$d/projD/.claude/skills/shared/SKILL.md" "$S/good/SKILL.md"; do
    ck "$f" && ok "$sh D: accepted ${f#$d/}" || bad "$sh D: not accepted ${f#$d/}: $(grep -F "$f" <<< "$out" | head -1)"
  done
  grep -qx "PLUGIN cp $CP" <<< "$out" && ok "$sh D: regular manifest still read" || bad "$sh D: PLUGIN cp missing"
done
ci="$(HOME="$HOME" bash "$CHECK" --located "$IDXD" 2>&1)"
grep -q 'FAIL card ## user/leak: .*not located' <<< "$ci" && ok "check-index --located rejects the verified card of a skill whose file points outside" || bad "check-index --located accepted the leaking card: $(tail -3 <<< "$ci" | tr '\n' ' ')"
grep -q 'CANARY' <<< "$ci" && bad "check-index printed canary text" || ok "check-index printed no canary text"
grep -q -- '^- `SKIPPED-OUTSIDE-ROOT ' "$DOC" && ok "index.md documents SKIPPED-OUTSIDE-ROOT" || bad "index.md does not document SKIPPED-OUTSIDE-ROOT"
grep -q 'Never put a path from an `UNSAFE-PATH`, `UNSAFE-ROOT`, `SKIPPED-NONREGULAR` or `SKIPPED-OUTSIDE-ROOT` line' "$DOC" && ok "index.md: never-Read rule names SKIPPED-OUTSIDE-ROOT" || bad "index.md: never-Read rule lacks SKIPPED-OUTSIDE-ROOT"
grep -q 'file points outside the skill folders; not read' "$DOC" && ok "index.md: warning text for the unverified card" || bad "index.md: no warning text"

# E. a rejected manifest rejects its whole plugin folder. Kinds: out (a
# symlink outside the skill folders), fifo, dangling, dir (a folder named
# plugin.json), unsafe (the plugin folder name has a `;`). Each plugin has a
# regular SKILL.md and its own index with a pre-existing verified card.
mkrp() { # mkrp <folder>: a plugin `rp` with the regular skill rs, manifest left to the caller
  mkdir -p "$1/.claude-plugin" "$1/skills/rs"; printf -- '---\nname: rs\n---\nrs body of %s\n' "${1##*/}" > "$1/skills/rs/SKILL.md"; }
ecard() { # ecard <path under ~> <skill file>
  printf '%s\n\n## plugin:rp/rs\n\n```yaml\nname: rs\nsource: plugin:rp\npath: ~/%s\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Rs.\n**Use when:** Rs.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** rs\n**Examples:**\n- "a"\n- "b"\n' \
    '<!-- which-skill index v1 · updated 2026-11-16 -->' "$1" "$(cksum < "$2" | cut -d' ' -f1-2)"; }
EC="$HOME/.claude/plugins/cache/m"
mkfifo "$d/fifo-manifest"
for k in out fifo dangling dir dirnest dirlink unsafe; do
  case "$k" in unsafe) RPk="$EC/rp;u/1.0";; *) RPk="$EC/rp-$k/1.0";; esac
  mkrp "$RPk"; M="$RPk/.claude-plugin/plugin.json"
  case "$k" in
    out) printf '{"name": "rp"}\n' > "$d/ext/rp-manifest.json"; ln -s "$d/ext/rp-manifest.json" "$M";;
    fifo) ln -s "$d/fifo-manifest" "$M";;
    dangling) ln -s "$d/ext/no-such-manifest.json" "$M";;
    dir) mkdir "$M";;
    dirnest) mkdir -p "$M/.claude-plugin" "$M/skills/nx"; printf '{"name": "nested-CANARY"}\n' > "$M/.claude-plugin/plugin.json"
      printf -- '---\nname: nx\n---\nCANARY\n' > "$M/SKILL.md"; cp "$M/SKILL.md" "$M/skills/nx/SKILL.md";;
    dirlink) X="$d/extdir-CANARY"; mkdir -p "$X/.claude-plugin" "$X/skills/ny"; printf 'secret\n' > "$X/CANARY-dir.txt"
      printf '{"name": "linked-CANARY"}\n' > "$X/.claude-plugin/plugin.json"; printf -- '---\nname: ny\n---\nCANARY\n' > "$X/SKILL.md"
      cp "$X/SKILL.md" "$X/skills/ny/SKILL.md"; ln -s "$X" "$M";;
    unsafe) printf '{"name": "rp"}\n' > "$M";;
  esac
  mkdir -p "$d/idxE-$k"; ecard "${RPk#$HOME/}/skills/rs/SKILL.md" "$RPk/skills/rs/SKILL.md" > "$d/idxE-$k/index.md"
done
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  for k in out fifo dangling dir dirnest dirlink unsafe; do
    case "$k" in unsafe) RPk="$EC/rp;u/1.0"; SP="$EC/rp?u/1.0";; *) RPk="$EC/rp-$k/1.0"; SP="$RPk";; esac
    IDXE="$d/idxE-$k/index.md"; L="$sh E $k"
    r="$(disc "$sh" "$d/plain" "$d/out" HOME="$HOME" WHICH_SKILL_INDEX="$IDXE")"; out="$(cat "$d/out")"
    [ "$r" = rc=0 ] && tail -1 <<< "$out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r, last line '$(tail -1 <<< "$out")'"; continue; }
    grep -qxF "PLUGIN-REJECTED $SP" <<< "$out" && ok "$L: PLUGIN-REJECTED marker" || bad "$L: no PLUGIN-REJECTED $SP"
    case "$k" in
      out) w="SKIPPED-OUTSIDE-ROOT $SP/.claude-plugin/plugin.json";;
      unsafe) w="UNSAFE-PATH $SP/.claude-plugin/plugin.json";;
      *) w="SKIPPED-NONREGULAR $SP/.claude-plugin/plugin.json";;
    esac
    grep -qxF "$w" <<< "$out" && ok "$L: manifest line ${w%% *}" || bad "$L: no manifest line '${w%% *}'"
    grep -qx 'UNCHANGED 0' <<< "$out" && ok "$L: UNCHANGED 0" || bad "$L: $(grep '^UNCHANGED' <<< "$out")"
    grep -qF "/m/rp-$k/" <<< "$(grep '^NOCARD ' <<< "$out")" && bad "$L: NOCARD for a file of the rejected plugin" || ok "$L: no NOCARD for the rejected plugin"
    grep -q '^NOCARD .*/m/rp?u/' <<< "$out" && bad "$L: NOCARD for the unsafe plugin" || true
    if [ "$k" = unsafe ]; then f="UNSAFE-PATH $SP/skills/rs/SKILL.md"; else f="SKIPPED-REJECTED-PLUGIN $SP/skills/rs/SKILL.md"; fi
    grep -qxF "$f" <<< "$out" && ok "$L: SKILL.md not fingerprinted (${f%% *})" || bad "$L: no '${f%% *}' line for its SKILL.md"
    grep -q '^PLUGIN rp ' <<< "$out" && bad "$L: PLUGIN line for a rejected plugin" || ok "$L: no PLUGIN line for it"
    grep -q '^GONE plugin:rp/rs | ' <<< "$out" && ok "$L: the verified card is GONE (downgraded)" || bad "$L: no GONE line"
    case "$k" in dir*)
      if grep -qF "$RPk/.claude-plugin/plugin.json/" <<< "$out" || grep -q 'CANARY' <<< "$out"; then bad "$L: a descendant of the manifest folder was visited: $(grep -F -e "$RPk/.claude-plugin/plugin.json/" -e CANARY <<< "$out" | head -2)"
      else ok "$L: nothing below the manifest folder was visited"; fi;;
    esac
  done
done
for k in out fifo dangling dir dirnest dirlink unsafe; do
  ci="$(HOME="$HOME" bash "$CHECK" --located "$d/idxE-$k/index.md" 2>&1)"
  grep -q 'FAIL card ## plugin:rp/rs: .*not located' <<< "$ci" && ok "E $k: check-index --located rejects the card" || bad "E $k: check-index accepted it: $(tail -2 <<< "$ci" | tr '\n' ' ')"
done
grep -q -- '^- `PLUGIN-REJECTED ' "$DOC" && grep -q 'plugin manifest points outside the skill folders' "$DOC" && grep -q 'plugin manifest is not a regular file' "$DOC" && ok "index.md documents PLUGIN-REJECTED and its warnings" || bad "index.md lacks PLUGIN-REJECTED or a warning"

# F. folders named like skill files, and node_modules/.trash, are never entered
RQ="$EC/rq/1.0"; mkdir -p "$RQ/.claude-plugin" "$RQ/skills" "$RQ/commands"; printf '{"name": "rq"}\n' > "$RQ/.claude-plugin/plugin.json"
fill() { mkdir -p "$1/.claude-plugin"; printf 'x\n' > "$1/CANARY-f.txt"; printf '{"name": "nested-CANARY"}\n' > "$1/.claude-plugin/plugin.json"
  printf -- '---\nname: n\n---\nCANARY\n' > "$1/SKILL.md"; mkdir -p "$1/commands"; cp "$1/SKILL.md" "$1/commands/c.md"; }
mkdir -p "$RQ/skills/sd/SKILL.md"; fill "$RQ/skills/sd/SKILL.md"
mkdir -p "$RQ/skills/sl"; fill "$d/extsl-CANARY"; ln -s "$d/extsl-CANARY" "$RQ/skills/sl/SKILL.md"
mkdir -p "$RQ/commands/cd.md"; fill "$RQ/commands/cd.md"
fill "$d/extcl-CANARY"; ln -s "$d/extcl-CANARY" "$RQ/commands/cl.md"
for b in "$RQ" "$HOME/.claude/skills"; do
  for t in node_modules .trash; do
    mkdir -p "$b/$t/pkg-CANARY/sub"; ln -s .. "$b/$t/pkg-CANARY/sub/loop"; ln -s loop2 "$b/$t/loop2"
    printf -- '---\nname: hidden\n---\nCANARY\n' > "$b/$t/pkg-CANARY/SKILL.md"; fill "$b/$t/pkg-CANARY/inner"
    mkdir -p "$b/$t/locked-CANARY"; chmod 000 "$b/$t/locked-CANARY"   # entering it would make find fail
  done
done
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  r="$(disc "$sh" "$d/plain" "$d/out" HOME="$HOME")"; out="$(cat "$d/out")"; L="$sh F"
  [ "$r" = rc=0 ] && tail -1 <<< "$out" | grep -q '^DISCOVERY OK' && ! grep -q '^DISCOVERY \(FAILED\|INCOMPLETE\)' <<< "$out" && ok "$L: DISCOVERY OK, no FAILED or INCOMPLETE" || bad "$L: $r, $(grep '^DISCOVERY' <<< "$out" | head -3 | tr '\n' ' ')"
  grep -q 'CANARY' <<< "$out" && bad "$L: canary text in the output: $(grep CANARY <<< "$out" | head -2)" || ok "$L: no canary text"
  grep -qE '/(SKILL\.md|cd\.md|cl\.md)/|/node_modules/|/\.trash/' <<< "$out" && bad "$L: a path below a pruned folder: $(grep -E '/(SKILL\.md|cd\.md|cl\.md)/|/node_modules/|/\.trash/' <<< "$out" | head -2)" || ok "$L: no path below a pruned folder"
  grep -q '^PLUGIN .*nested' <<< "$out" && bad "$L: nested PLUGIN line" || ok "$L: no nested PLUGIN line"
  grep -qx "PLUGIN rq $RQ" <<< "$out" && ok "$L: PLUGIN rq still read" || bad "$L: no PLUGIN rq"
done

if [ "$BAD" -eq 0 ]; then echo "TEST DISCOVERY-EDGE OK"; exit 0; else echo "TEST DISCOVERY-EDGE FAILED ($BAD)"; exit 1; fi
