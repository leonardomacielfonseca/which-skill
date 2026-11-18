#!/usr/bin/env bash
# Sandbox test of the deferred items E1 r53 (3) and E1 r55 (no claude run),
# under bash and zsh, with the discovery block extracted verbatim from
# index.md:
#   A. depth of the skill roots: a personal or project skill folder holding an
#      ordinary symlink to a large outside tree (a home folder, a dataset) must
#      not make discovery walk that tree. The skill roots are walked only as
#      deep as a skill file can sit (`<root>/<name>/SKILL.md`; synced skills
#      have their own root, `<config>/skills/synced`, one level deeper), so a
#      canary SKILL.md and an unreadable folder deep inside the linked tree are
#      never visited: DISCOVERY OK, no line names the canary, while the
#      personal, project and synced skills are still located;
#   B. legacy commands (code.claude.com/docs/en/skills: "Files in
#      .claude/commands/ still work"): `<config>/commands/<name>.md` and
#      `<D>/.claude/commands/<name>.md` for every project folder D are
#      discovery roots one level deep, so a command file is located; a file in
#      a subfolder of commands/ is not (a known limit).
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
command -v git >/dev/null 2>&1 || { echo "ABORT: git not found"; exit 2; }
unset CLAUDE_CONFIG_DIR CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR WHICH_SKILL_INDEX

disc() { # disc <shell> <cwd> <out> <home>: discovery with a 10 s watchdog
  local sh="$1" cwd="$2" out="$3" h="$4"
  set -m; (cd "$cwd" && exec env HOME="$h" WHICH_SKILL_INDEX="$h/idx/index.md" GIT_CEILING_DIRECTORIES="$d" "$sh" -c "$DISC") > "$out" 2>&1 & local pid=$!; set +m
  PIDS="$PIDS $pid"; local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "rc=TIMEOUT"; return; fi
  wait "$pid"; echo "rc=$?"
}
sk() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: %s skill.\n---\nbody\n' "$2" "$2" > "$1/$2/SKILL.md"; }
located() { grep -qxF "NOCARD $(cksum "$2")" "$1"; }

for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP   $sh not found"; continue; }
  # A. a symlink to a large outside tree inside a skill folder
  X="$d/$sh-depth"; H="$X/home"; R="$X/repo"; BIG="$X/big"; mkdir -p "$H/idx" "$R"
  git init -q "$R" || { bad "$sh: git init"; continue; }
  sk "$H/.claude/skills" mine; sk "$R/.claude/skills" proj; sk "$H/.claude/skills/synced/abc" cloud
  mkdir -p "$BIG/a/b/c" "$BIG/a/locked/x"; printf -- '---\nname: canary\n---\nCANARY\n' > "$BIG/a/b/c/SKILL.md"
  printf -- '---\nname: canary2\n---\n' > "$BIG/a/b/SKILL.md"; chmod 000 "$BIG/a/locked"
  ln -s "$BIG" "$H/.claude/skills/mine/data"; ln -s "$BIG" "$R/.claude/skills/proj/data"
  L="$sh A depth"; r="$(disc "$sh" "$R" "$X/out" "$H")"
  [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK 3$' && ok "$L: DISCOVERY OK 3" || bad "$L: $r $(grep -E 'DISCOVERY' "$X/out" | sed "s|$X/||g" | tr '\n' ';')"
  ! grep -q 'canary\|/big/\|/data/' "$X/out" && ok "$L: nothing below the linked tree is named" || bad "$L: walked the linked tree: $(grep 'canary\|/big/\|/data/' "$X/out" | sed "s|$X/||g" | head -3 | tr '\n' ';')"
  for f in "$H/.claude/skills/mine/SKILL.md" "$R/.claude/skills/proj/SKILL.md" "$H/.claude/skills/synced/abc/cloud/SKILL.md"; do
    located "$X/out" "$f" && ok "$L: located ${f#$X/}" || bad "$L: not located ${f#$X/}"
  done
  chmod 700 "$BIG/a/locked"
  # B. legacy commands
  Y="$d/$sh-cmd"; H="$Y/home"; R="$Y/repo"; S="$R/apps"; mkdir -p "$H/idx" "$H/.claude/commands/sub" "$R/.claude/commands" "$S/.claude/commands"
  git init -q "$R"
  printf -- '---\ndescription: ship it.\n---\nbody\n' > "$H/.claude/commands/ship.md"
  printf -- '---\ndescription: nested.\n---\n' > "$H/.claude/commands/sub/deep.md"
  printf -- '---\ndescription: top.\n---\n' > "$R/.claude/commands/top.md"
  printf -- '---\ndescription: mid.\n---\n' > "$S/.claude/commands/mid.md"
  L="$sh B commands"; r="$(disc "$sh" "$S" "$Y/out" "$H")"
  [ "$r" = rc=0 ] && tail -1 "$Y/out" | grep -q '^DISCOVERY OK 3$' && ok "$L: DISCOVERY OK 3" || bad "$L: $r $(grep -E 'DISCOVERY' "$Y/out" | tr '\n' ';')"
  for f in "$H/.claude/commands/ship.md" "$R/.claude/commands/top.md" "$S/.claude/commands/mid.md"; do
    located "$Y/out" "$f" && ok "$L: located ${f#$Y/}" || bad "$L: not located ${f#$Y/}"
  done
  ! grep -q '/sub/deep.md' "$Y/out" && ok "$L: a command in a subfolder is not located (known limit)" || bad "$L: located a nested command"
  got="$(sed -n 's/^ROOT_DIR //p' "$Y/out" | grep '/commands$' | LC_ALL=C sort | tr '\n' ';')"
  want="$(printf '%s\n' "$H/.claude/commands" "$R/.claude/commands" "$S/.claude/commands" | LC_ALL=C sort | tr '\n' ';')"
  [ "$got" = "$want" ] && ok "$L: ROOT_DIR for every commands folder" || bad "$L: ROOT_DIR '$(sed "s|$Y/||g" <<< "$got")'"
  # D. Codex adiados r10: a project command or SKILL.md that is a symlink to a
  #    secret file under another discovery root (a user skill's .env) is
  #    rejected: a target inside a root must still have the expected name
  Z="$d/$sh-leak"; H="$Z/home"; R="$Z/repo"; mkdir -p "$H/idx" "$R/.claude/commands" "$R/.claude/skills/leak2"
  git init -q "$R"; sk "$H/.claude/skills" deploy; printf 'TOKEN=CANARY-ENV-5e1\n' > "$H/.claude/skills/deploy/.env"
  ln -s "$H/.claude/skills/deploy/.env" "$R/.claude/commands/leak.md"; ln -s "$H/.claude/skills/deploy/.env" "$R/.claude/skills/leak2/SKILL.md"
  sk "$R/.claude/skills" okskill; ln -s "$H/.claude/skills/deploy/SKILL.md" "$R/.claude/skills/okskill/SKILL.md" 2>/dev/null || { rm -f "$R/.claude/skills/okskill/SKILL.md"; ln -s "$H/.claude/skills/deploy/SKILL.md" "$R/.claude/skills/okskill/SKILL.md"; }
  L="$sh D leak"; r="$(disc "$sh" "$R" "$Z/out" "$H")"
  [ "$r" = rc=0 ] && tail -1 "$Z/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || bad "$L: $r $(tail -1 "$Z/out")"
  grep -qxF "SKIPPED-OUTSIDE-ROOT $R/.claude/commands/leak.md" "$Z/out" && grep -qxF "SKIPPED-OUTSIDE-ROOT $R/.claude/skills/leak2/SKILL.md" "$Z/out" && ok "$L: both links to the .env are SKIPPED-OUTSIDE-ROOT" || bad "$L: a link to the .env was accepted: $(grep -E 'leak' "$Z/out" | sed "s|$Z/||g" | tr '\n' ';')"
  ! grep -qE '^(NOCARD|LOCATED) .*(leak\.md|leak2/SKILL\.md)$' "$Z/out" && ok "$L: no checksum of the .env" || bad "$L: the .env was fingerprinted"
  located "$Z/out" "$R/.claude/skills/okskill/SKILL.md" && ok "$L: a SKILL.md linked to a SKILL.md in another root stays accepted" || bad "$L: a SKILL.md link into another root was rejected"
  # Codex adiados r11: a command linked to a .md that is not in a commands/ folder
  Z2="$d/$sh-leakmd"; H="$Z2/home"; R="$Z2/repo"; mkdir -p "$H/idx" "$R/.claude/commands" "$H/.claude/commands"; git init -q "$R"
  sk "$R/.claude/skills" private; mkdir -p "$R/.claude/skills/private/references"; printf 'CANARY-MD-77 token\n' > "$R/.claude/skills/private/references/secrets.md"
  sk "$H/.claude/skills" mine; printf 'CANARY-MD-78\n' > "$H/.claude/skills/mine/credentials.md"
  ln -s "$R/.claude/skills/private/references/secrets.md" "$R/.claude/commands/deploy.md"; ln -s "$H/.claude/skills/mine/credentials.md" "$H/.claude/commands/c.md"
  mkdir -p "$Z2/ext/commands"; printf -- '---\ndescription: ok.\n---\n' > "$Z2/ext/commands/fine.md"; ln -s "$Z2/ext/commands/fine.md" "$R/.claude/commands/fine.md"
  L="$sh D leak-md"; r="$(disc "$sh" "$R" "$Z2/out" "$H")"
  grep -qxF "SKIPPED-OUTSIDE-ROOT $R/.claude/commands/deploy.md" "$Z2/out" && grep -qxF "SKIPPED-OUTSIDE-ROOT $H/.claude/commands/c.md" "$Z2/out" && ok "$L: commands linked to secrets.md and credentials.md in skill folders are refused" || bad "$L: $(grep -E '/(deploy|c)\.md$' "$Z2/out" | sed "s|$Z2/||g" | tr '\n' ';')"
  grep -qxF "SKIPPED-OUTSIDE-ROOT $R/.claude/commands/fine.md" "$Z2/out" && ok "$L: a command linked to a .md in an outside commands/ folder is refused (Codex adiados r13)" || bad "$L: fine.md accepted"
  mkdir -p "$H/.claude/commands"; printf -- '---\ndescription: mine.\n---\n' > "$H/.claude/commands/real.md"; ln -s "$H/.claude/commands/real.md" "$R/.claude/commands/alias.md"
  r="$(disc "$sh" "$R" "$Z2/out2" "$H")"; located "$Z2/out2" "$R/.claude/commands/alias.md" && ok "$L: a command linked into another commands root stays accepted" || bad "$L: alias.md refused"
  # Codex adiados r15: a command named SKILL.md linked outside every root
  mkdir -p "$Z2/priv/commands"; printf 'CANARY-SK-91\n' > "$Z2/priv/commands/SKILL.md"; ln -s "$Z2/priv/commands/SKILL.md" "$R/.claude/commands/SKILL.md"
  r="$(disc "$sh" "$R" "$Z2/out3" "$H")"; grep -qxF "SKIPPED-OUTSIDE-ROOT $R/.claude/commands/SKILL.md" "$Z2/out3" && ok "$L: commands/SKILL.md linked outside is refused" || bad "$L: commands/SKILL.md accepted: $(grep -F 'commands/SKILL.md' "$Z2/out3" | sed "s|$Z2/||g")"
  rm -f "$R/.claude/commands/SKILL.md"; ln -s "$H/.claude/skills/mine/SKILL.md" "$R/.claude/commands/SKILL.md"
  r="$(disc "$sh" "$R" "$Z2/out4" "$H")"; grep -qxF "SKIPPED-OUTSIDE-ROOT $R/.claude/commands/SKILL.md" "$Z2/out4" && ok "$L: commands/SKILL.md linked to a personal SKILL.md is refused" || bad "$L: commands/SKILL.md -> skill accepted: $(grep -F 'commands/SKILL.md' "$Z2/out4" | sed "s|$Z2/||g")"
  rm -f "$R/.claude/commands/SKILL.md"; printf 'CANARY-CR-92\n' > "$H/.claude/commands/credentials"; ln -s "$H/.claude/commands/credentials" "$R/.claude/commands/SKILL.md"
  r="$(disc "$sh" "$R" "$Z2/out5" "$H")"; grep -qxF "SKIPPED-OUTSIDE-ROOT $R/.claude/commands/SKILL.md" "$Z2/out5" && ok "$L: commands/SKILL.md linked to a non-.md file in a commands root is refused" || bad "$L: commands/SKILL.md -> credentials accepted"
  # Codex adiados r19: a skill folder named commands is a skill, not a command
  mkdir -p "$Z2/dev/commands" "$R/.claude/skills/commands" "$H/.claude/skills/commands"; printf -- '---\nname: commands\n---\nok\n' > "$Z2/dev/commands/SKILL.md"
  ln -s "$Z2/dev/commands/SKILL.md" "$R/.claude/skills/commands/SKILL.md"; ln -s "$H/.claude/commands/real.md" "$H/.claude/skills/commands/SKILL.md"
  r="$(disc "$sh" "$R" "$Z2/out6" "$H")"
  located "$Z2/out6" "$R/.claude/skills/commands/SKILL.md" && ok "$L: a skill named commands linked to an outside same-named folder is accepted" || bad "$L: skills/commands/SKILL.md refused: $(grep -F 'skills/commands/SKILL.md' "$Z2/out6" | sed "s|$Z2/||g" | head -1)"
  grep -qxF "SKIPPED-OUTSIDE-ROOT $H/.claude/skills/commands/SKILL.md" "$Z2/out6" && ok "$L: a skill named commands linked to a command .md is refused" || bad "$L: skills/commands/SKILL.md -> real.md accepted"
  # E. Codex adiados r29: a command with a secret-like name, or a clean alias
  #    whose canonical target has one, is never fingerprinted or located; a
  #    verified card of it comes out GONE
  Q="$d/$sh-secretcmd"; H="$Q/home"; R="$Q/repo"; mkdir -p "$H/idx" "$H/.claude/commands" "$R/.claude/commands"; git init -q "$R"
  printf -- '---\ndisable-model-invocation: true\n---\nKEY=CANARY-SC-1\n' > "$H/.claude/commands/credentials.md"
  printf -- '---\ndescription: t.\n---\nCANARY-SC-2\n' > "$H/.claude/commands/Token-refresh.md"
  ln -s "$H/.claude/commands/credentials.md" "$R/.claude/commands/release.md"
  printf -- '---\ndescription: fine.\n---\n' > "$R/.claude/commands/fine.md"
  # Codex adiados r39: a clean alias whose canonical target sits in a
  # secret-like FOLDER below its discovery root (.env.d/, Secrets/) is skipped too
  mkdir -p "$R/.claude/skills/private/.env.d/commands" "$R/.claude/skills/private/Secrets/commands"
  printf -- '---\ndescription: d.\n---\nKEY=CANARY-SC-3\n' > "$R/.claude/skills/private/.env.d/commands/deploy.md"
  printf -- '---\ndescription: s.\n---\nKEY=CANARY-SC-4\n' > "$R/.claude/skills/private/Secrets/commands/ship.md"
  ln -s "$R/.claude/skills/private/.env.d/commands/deploy.md" "$R/.claude/commands/deploy.md"
  ln -s "$R/.claude/skills/private/Secrets/commands/ship.md" "$R/.claude/commands/ship.md"
  printf '# which-skill index\n\n## user/credentials\n\n```yaml\nname: credentials\nsource: user\npath: %s\nfingerprint: 1 2\nstatus: installed\n```\n' "$H/.claude/commands/credentials.md" > "$H/idx/index.md"
  L="$sh E secret-named commands"; r="$(disc "$sh" "$R" "$Q/out" "$H")"
  [ "$r" = rc=0 ] && tail -1 "$Q/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || bad "$L: $r $(tail -1 "$Q/out")"
  for f in "$H/.claude/commands/credentials.md" "$H/.claude/commands/Token-refresh.md" "$R/.claude/commands/release.md" "$R/.claude/commands/deploy.md" "$R/.claude/commands/ship.md"; do
    grep -qxF "SKIPPED-SECRET-NAME $f" "$Q/out" && ! grep -qE "^(NOCARD|LOCATED) .*${f##*/}$" "$Q/out" && ok "$L: ${f##*/} skipped, not located" || bad "$L: ${f##*/}: $(grep -F "${f##*/}" "$Q/out" | sed "s|$Q/||g" | tr '\n' ';')"
  done
  located "$Q/out" "$R/.claude/commands/fine.md" && ok "$L: a clean command is still located" || bad "$L: fine.md not located"
  grep -q '^GONE user/credentials | ' "$Q/out" && ok "$L: the old verified card of credentials is GONE (downgraded)" || bad "$L: no GONE line for user/credentials"
  ! grep -q CANARY "$Q/out" && ok "$L: no content printed" || bad "$L: canary leaked"
done
# C. the text of index.md states both rules
grep -qF '| `<config>/commands/<name>.md` (a legacy command file, one level deep) | `user` |' "$DOC" && grep -qF '| `<D>/.claude/commands/<name>.md`' "$DOC" && ok "index.md: path table rows for legacy commands" || bad "index.md: no path table rows for legacy commands"
M="$(grep '^- \*\*Manual skills\*\*' "$DOC")"; grep -qF '`<config>/commands/<name>.md`' <<< "$M" && grep -qF '`<D>/.claude/commands/<name>.md`' <<< "$M" && ok "index.md: Manual skills covers legacy command files" || bad "index.md: Manual skills ignores legacy command files"
grep -qF 'If a skill and a command share the same name, the skill takes precedence' "$DOC" && ok "index.md: a skill beats a command of the same name" || bad "index.md: no skill-over-command rule"
grep -q '^\*\*Depth\.\*\* ' "$DOC" && grep -qF 'walk "$d" : 2' "$DOC" && grep -qF 'walk "$d" : 3' "$DOC" && grep -qF 'walk "$d" : 1' "$DOC" && ok "index.md: the Depth rule and the bounded walks" || bad "index.md: Depth rule or bounded walks missing"
if [ "$BAD" -eq 0 ]; then echo "TEST DEPTH-COMMANDS OK"; exit 0; else echo "TEST DEPTH-COMMANDS FAILED ($BAD)"; exit 1; fi
