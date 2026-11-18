#!/usr/bin/env bash
# Sandbox test: skill folders whose names carry shell syntax must never turn
# into commands. Builds, in a private mktemp HOME, user skills named with a
# single quote, `;`, `$(...)`, a backtick and a newline (each payload would
# delete a canary file), plus two safe ones (one with a space). Then:
#   1. runs the discovery block from references/index.md (bash and zsh):
#      it must end DISCOVERY OK with only the two safe files counted, print
#      one UNSAFE-PATH line per unsafe folder, and print no line that holds a
#      quote, `$`, backtick or `;`;
#   2. renders every hand-built path template still in index.md (`'<file>'`)
#      with each discovered path, exactly as the model would, and runs it;
#   3. checks the single-quote rule round-trips every safe path;
#   4. checks the canary is intact.
# Exit 0 = every check as expected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; DOC="$HERE/../references/index.md"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"; trap 'rm -rf "$d"' EXIT
BAD=0; ok() { echo "ok     $1"; }; bad() { BAD=$((BAD+1)); echo "NOT OK $1"; }
DISC="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"DISCOVERY OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$DISC" ] || { echo "ABORT: discovery block not found"; exit 2; }

export HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$d/idx/index.md" WS_CANARY="$d/canary"
unset CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR
S="$CLAUDE_CONFIG_DIR/skills"; mkdir -p "$S" "$d/proj" "$d/idx"
echo canary > "$WS_CANARY"
NL='
'
UNSAFE=("q'; rm -f \"\$WS_CANARY\"; echo '" "s;x" "d\$(rm -f \"\$WS_CANARY\")" "b\`rm -f \"\$WS_CANARY\"\`" "n${NL}l")
for n in good "sp ace" "${UNSAFE[@]}"; do mkdir -p "$S/$n"; printf -- '---\nname: x\n---\nbody\n' > "$S/$n/SKILL.md"; done

for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP   $sh not found"; continue; }
  out="$(cd "$d/proj" && "$sh" -c "$DISC" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(tail -1 <<< "$out")" = "DISCOVERY OK 2" ] && ok "$sh: DISCOVERY OK 2 (safe files only)" || bad "$sh: exit $rc, last line '$(tail -1 <<< "$out")'"
  [ "$(grep -c '^UNSAFE-PATH ' <<< "$out")" -eq "${#UNSAFE[@]}" ] && ok "$sh: one UNSAFE-PATH line per unsafe folder" || bad "$sh: UNSAFE-PATH lines: $(grep -c '^UNSAFE-PATH ' <<< "$out")"
  grep -q "[\"'\`\$;]" <<< "$out" && bad "$sh: an output line holds a quote, \$, backtick or ;: $(grep "[\"'\`\$;]" <<< "$out" | head -3)" || ok "$sh: no output line holds shell syntax"
  grep -q "/good/SKILL.md\$" <<< "$out" && grep -q "/sp ace/SKILL.md\$" <<< "$out" && ok "$sh: both safe files listed" || bad "$sh: a safe file is missing"
done

# 2. every hand-built path template left in index.md, rendered and run
TPL="$(grep -o "\[ \"\$(cksum < '<file>')\" = '<fingerprint in the new card>' \]" "$DOC" | head -1)"
if [ -z "$TPL" ]; then
  ok "no hand-built path template ('<file>') left in index.md"
else
  for n in "${UNSAFE[@]}"; do
    r="${TPL//<file>/$S/$n/SKILL.md}"; r="${r//<fingerprint in the new card>/1 2}"
    (cd "$d/proj" && bash -c "$r") >/dev/null 2>&1
  done
  echo "       (rendered the template '$TPL' with each unsafe path)"
fi

# 3. the single-quote rule for safe paths
for n in good "sp ace"; do
  p="$S/$n/SKILL.md"; [ "$(bash -c "printf '%s' '$p'")" = "$p" ] && ok "single-quoted '$n' path round-trips" || bad "single-quoted '$n' path changed"
done

# 4. the canary
[ -f "$WS_CANARY" ] && [ "$(cat "$WS_CANARY")" = canary ] && ok "canary intact (no command ran)" || bad "canary deleted: a path ran as a command"

if [ "$BAD" -eq 0 ]; then echo "TEST UNSAFE-PATHS OK"; exit 0; else echo "TEST UNSAFE-PATHS FAILED ($BAD)"; exit 1; fi
