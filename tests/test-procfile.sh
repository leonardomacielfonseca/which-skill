#!/usr/bin/env bash
# Sandbox test of Codex adiados r25 (no claude run), under bash and zsh: the
# procedure-file check block of index.md (the block that prints PROCFILE
# lines) runs before any referenced procedure file is opened with Read. It
# must refuse a file that is a symlink (to the project's .env, or anywhere),
# a file that is not regular, and a file whose real folder leaves the
# boundary through a symlinked folder; it must accept a regular file, also
# when the whole skill folder is symlink-installed (~/.claude/skills/x ->
# ~/dev/x). It never prints file contents.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; DOC="$HERE/../references/index.md"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
d="$(cd -P "$d" && pwd -P)"; trap 'rm -rf "$d"' EXIT
BAD=0; ok() { echo "ok     $1"; }; bad() { BAD=$((BAD+1)); echo "NOT OK $1"; }
BLK="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"PROCFILE OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$BLK" ] || { echo "NOT OK index.md has no procedure-file check block (PROCFILE)"; echo "TEST PROCFILE FAILED (1)"; exit 1; }
S="$d/proj/.claude/skills/tok"; mkdir -p "$S/scripts" "$d/outside" "$d/dev/inst/scripts" "$d/home/.claude/skills"
printf 'TOKEN=CANARY-PF-1\n' > "$d/proj/.env"; printf 'print(1)\n' > "$S/scripts/ok.py"
ln -s ../../../../.env "$S/scripts/token_refresh.py"; ln -s "$d/outside" "$S/ext"; printf 'x\n' > "$d/outside/run.sh"; mkfifo "$S/scripts/pipe.sh"
printf 'y\n' > "$d/dev/inst/scripts/go.sh"; ln -s "$d/dev/inst" "$d/home/.claude/skills/inst"
P0="$d/projroot"; mkdir -p "$P0/secrets" "$P0/.env.d" "$P0/Tokens" "$P0/keys.pem" "$P0/scripts" "$d/tokens-home/proj/scripts"
for f in secrets/bootstrap.sh .env.d/setup.sh Tokens/run.sh keys.pem/go.sh scripts/Credentials.sh; do printf 'KEY=CANARY-PF-2\n' > "$P0/$f"; done
printf 'echo ok\n' > "$P0/scripts/build.sh"; printf 'echo ok\n' > "$d/tokens-home/proj/scripts/go.sh"
run() { # run <shell> <boundary> <files...>: the block with B and the files substituted
  local sh="$1" b="$2"; shift 2; local list=""; for f; do list="$list '$f'"; done
  "$sh" -c "$(printf '%s' "$BLK" | sed "s|<boundary>|$b|; s|'<file>' '<file>'|$list|")" 2>&1; }
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP   $sh not found"; continue; }
  out="$(run "$sh" "$S" "$S/scripts/ok.py" "$S/scripts/token_refresh.py" "$S/ext/run.sh" "$S/scripts/pipe.sh" "$S/scripts/missing.py")"
  grep -qxF "PROCFILE OK $S/scripts/ok.py" <<< "$out" && ok "$sh: regular file accepted" || bad "$sh: ok.py: $out"
  grep -qxF "PROCFILE REFUSED $S/scripts/token_refresh.py" <<< "$out" && ok "$sh: symlink to the project .env refused" || bad "$sh: token_refresh.py not refused"
  grep -qxF "PROCFILE REFUSED $S/ext/run.sh" <<< "$out" && ok "$sh: file behind a symlinked folder leaving the boundary refused" || bad "$sh: ext/run.sh not refused"
  grep -qxF "PROCFILE REFUSED $S/scripts/pipe.sh" <<< "$out" && grep -qxF "PROCFILE REFUSED $S/scripts/missing.py" <<< "$out" && ok "$sh: FIFO and missing file refused" || bad "$sh: FIFO or missing not refused"
  ! grep -q CANARY <<< "$out" && ok "$sh: no file content printed" || bad "$sh: content leaked"
  # Codex adiados r38: a secret-like FOLDER (or file name) below the boundary,
  # in any case, is refused before any Read: PROCFILE SECRET, content unseen.
  out3="$(run "$sh" "$P0" "$P0/secrets/bootstrap.sh" "$P0/.env.d/setup.sh" "$P0/Tokens/run.sh" "$P0/keys.pem/go.sh" "$P0/scripts/Credentials.sh" "$P0/scripts/build.sh")"
  for f in secrets/bootstrap.sh .env.d/setup.sh Tokens/run.sh keys.pem/go.sh scripts/Credentials.sh; do
    grep -qxF "PROCFILE SECRET $P0/$f" <<< "$out3" && ok "$sh: secret-like path $f refused" || bad "$sh: $f not refused as secret: $out3"; done
  grep -qxF "PROCFILE OK $P0/scripts/build.sh" <<< "$out3" && ok "$sh: clean project script accepted" || bad "$sh: build.sh: $out3"
  ! grep -q CANARY <<< "$out3" && ok "$sh: no secret content printed" || bad "$sh: secret content leaked"
  out4="$(run "$sh" "$d/tokens-home/proj" "$d/tokens-home/proj/scripts/go.sh" "$d/tokens-home/proj/scripts/go.sh")"
  grep -qxF "PROCFILE OK $d/tokens-home/proj/scripts/go.sh" <<< "$out4" && ok "$sh: secret-like folder ABOVE the boundary not counted" || bad "$sh: above-boundary: $out4"
  out2="$(run "$sh" "$d/home/.claude/skills/inst" "$d/home/.claude/skills/inst/scripts/go.sh" "$d/home/.claude/skills/inst/scripts/go.sh")"
  grep -qxF "PROCFILE OK $d/home/.claude/skills/inst/scripts/go.sh" <<< "$out2" && ok "$sh: symlink-installed skill folder accepted" || bad "$sh: inst: $out2"
done
if [ "$BAD" -eq 0 ]; then echo "TEST PROCFILE OK"; exit 0; else echo "TEST PROCFILE FAILED ($BAD)"; exit 1; fi
