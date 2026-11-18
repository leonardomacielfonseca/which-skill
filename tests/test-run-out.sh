#!/usr/bin/env bash
# Sandbox test of how tests/run.sh writes tests/out (no real claude run).
# Copies the skill folder into a private mktemp folder, puts a fake `claude`
# first on PATH, points HOME and TMPDIR into the sandbox, and runs the copied
# run.sh. Checks: tests/out ends 0700 and the outputs 0600 (an old 0755
# folder and 0644 file are tightened); a symlinked <id>.txt or <id>.jsonl is
# refused and its target (a canary) left intact; a symlinked tests/out is
# refused. Exit 0 = every check as expected.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd -P)"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"; trap 'rm -rf "$d"' EXIT
BAD=0; ok() { echo "ok     $1"; }; bad() { BAD=$((BAD+1)); echo "NOT OK $1"; }
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

mkdir -p "$d/skill" "$d/home" "$d/tmp" "$d/bin"
(cd "$SRC" && tar --exclude='./tests/out' --exclude='./tests/__pycache__' -cf - .) | (cd "$d/skill" && tar -xf -)
cat > "$d/bin/claude" <<'FAKE'
#!/bin/sh
case " $* " in
  *" stream-json "*) printf '%s\n' '{"type":"result","result":"fake answer"}';;
  *) echo "fake answer";;
esac
FAKE
chmod 700 "$d/bin/claude"
OUT="$d/skill/tests/out"
run() { (cd "$d/skill" && env -u CLAUDE_CONFIG_DIR -u WHICH_SKILL_INDEX HOME="$d/home" TMPDIR="$d/tmp" PATH="$d/bin:$PATH" bash -c 'umask 022; exec bash tests/run.sh "$@"' run "$@") > "$d/last.txt" 2>&1; }

# 1. an old 0755 tests/out with a 0644 file of the same id: tightened, 0600 outputs
(umask 022; mkdir -p "$OUT"; chmod 755 "$OUT"; echo old > "$OUT/A.txt"; chmod 644 "$OUT/A.txt")
if run --jsonl A "hello"; then ok "plain run exits 0"; else bad "plain run failed: $(cat "$d/last.txt")"; fi
[ "$(mode "$OUT")" = 700 ] && ok "tests/out is 0700" || bad "tests/out mode $(mode "$OUT")"
for f in A.txt A.jsonl; do
  [ -f "$OUT/$f" ] && [ "$(mode "$OUT/$f")" = 600 ] && ok "$f is 0600" || bad "$f mode $(mode "$OUT/$f" 2>&1)"
done
grep -q 'fake answer' "$OUT/A.txt" 2>/dev/null && ok "fake claude answer recorded" || bad "no answer in A.txt"
run B "hello"; [ "$(mode "$OUT/B.txt" 2>/dev/null)" = 600 ] && ok "new B.txt (no --jsonl) is 0600" || bad "B.txt mode $(mode "$OUT/B.txt" 2>&1)"

# 2. a symlinked <id>.txt pointing to a canary
echo canary > "$d/canary1"; chmod 644 "$d/canary1"; ln -s "$d/canary1" "$OUT/C.txt"
if run C "hello"; then bad "symlinked C.txt accepted"; elif grep -q "refusing: .*C.txt is a symlink" "$d/last.txt"; then ok "symlinked C.txt refused"; else bad "C run failed for another reason: $(cat "$d/last.txt")"; fi
[ "$(cat "$d/canary1")" = canary ] && [ "$(mode "$d/canary1")" = 644 ] && ok "canary behind C.txt intact" || bad "canary behind C.txt changed"

# 3. a symlinked <id>.jsonl pointing to a canary (nothing written for the id)
echo canary > "$d/canary2"; ln -s "$d/canary2" "$OUT/J.jsonl"
if run --jsonl J "hello"; then bad "symlinked J.jsonl accepted"; elif grep -q "refusing: .*J.jsonl is a symlink" "$d/last.txt"; then ok "symlinked J.jsonl refused"; else bad "J run failed for another reason: $(cat "$d/last.txt")"; fi
[ "$(cat "$d/canary2")" = canary ] && ok "canary behind J.jsonl intact" || bad "canary behind J.jsonl changed"
[ ! -e "$OUT/J.txt" ] && ok "no J.txt written before the refusal" || bad "J.txt was written"

# 4. a symlinked tests/out
mv "$OUT" "$d/oldout"; mkdir -m 755 "$d/elsewhere"; ln -s "$d/elsewhere" "$OUT"
if run K "hello"; then bad "symlinked tests/out accepted"; elif grep -q "refusing: .*out is a symlink" "$d/last.txt"; then ok "symlinked tests/out refused"; else bad "K run failed for another reason: $(cat "$d/last.txt")"; fi
[ -z "$(ls -A "$d/elsewhere")" ] && [ "$(mode "$d/elsewhere")" = 755 ] && ok "symlink target of tests/out untouched" || bad "symlink target of tests/out changed"

if [ "$BAD" -eq 0 ]; then echo "TEST RUN-OUT OK"; exit 0; else echo "TEST RUN-OUT FAILED ($BAD)"; exit 1; fi
