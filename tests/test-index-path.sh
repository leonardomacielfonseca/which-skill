#!/usr/bin/env bash
# Sandbox test of the index path check (the "prepare the location" block,
# extracted verbatim from references/index.md). No claude run, no real
# ~/.claude: HOME and every index path live in a private mktemp folder.
# Each case runs the block and expects its marker: INDEX PATH OK or
# INDEX PATH UNSAFE. Unsafe cases also check that nothing was changed.
# The shell is $WS_SH (default bash); check.sh also runs it with zsh.
# Exit 0 = every case as expected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; DOC="$HERE/../references/index.md"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"; trap 'chmod -R u+w "$d" 2>/dev/null; rm -rf "$d"' EXIT
PREP="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"loose()")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$PREP" ] || { echo "ABORT: prepare block not found in index.md"; exit 2; }
BAD=0; N=0
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
# run_case <label> <want OK|UNSAFE> <WHICH_SKILL_INDEX or "-" for the default> [CLAUDE_CONFIG_DIR]
run_case() {
  N=$((N+1))
  local out
  if [ "$3" = - ]; then
    out="$(cd "$d/home" && env -u WHICH_SKILL_INDEX PATH="${FAKEBIN:+$FAKEBIN:}$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="${4:-$d/home/.claude}" "${WS_SH:-bash}" -c "$PREP" 2>&1)"
  else
    out="$(cd "$d/home" && env PATH="${FAKEBIN:+$FAKEBIN:}$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$3" "${WS_SH:-bash}" -c "$PREP" 2>&1)"
  fi
  local got=NONE
  grep -q '^INDEX PATH UNSAFE: ' <<< "$out" && got=UNSAFE
  [ "$(tail -1 <<< "$out")" = "INDEX PATH OK" ] && got=OK
  if [ "$got" = "$2" ]; then echo "ok     $1 ($got)"; else BAD=$((BAD+1)); echo "NOT OK $1: got $got, expected $2"; sed 's/^/  /' <<< "$out"; fi
}
mkdir -p "$d/home"

# 1. a good private custom folder, with an index file
mkdir -m 700 "$d/good"; printf 'x\n' > "$d/good/index.md"
run_case "private custom folder" OK "$d/good/index.md"

# 2. a group-writable custom folder (must not be chmod-ed)
mkdir -m 770 "$d/gw"
run_case "group-writable custom folder" UNSAFE "$d/gw/index.md"
[ "$(mode "$d/gw")" = 770 ] && echo "ok     group-writable folder left at 770" || { BAD=$((BAD+1)); echo "NOT OK custom folder mode changed to $(mode "$d/gw")"; }

# 3. an other-writable custom folder
mkdir -m 703 "$d/ow"
run_case "other-writable custom folder" UNSAFE "$d/ow/index.md"

# 4. the index file is a symlink to a victim file
mkdir -m 700 "$d/sl"; printf 'victim\n' > "$d/victim"; ln -s "$d/victim" "$d/sl/index.md"
chmod 644 "$d/victim"
run_case "symlinked index file" UNSAFE "$d/sl/index.md"
[ "$(mode "$d/victim")" = 644 ] && [ "$(cat "$d/victim")" = victim ] && echo "ok     symlink target untouched (not chmod-ed through the link)" || { BAD=$((BAD+1)); echo "NOT OK symlink target changed"; }

# 5. a symlink in the folder path
mkdir -m 700 "$d/real"; ln -s "$d/real" "$d/link"
run_case "symlink in the folder path" UNSAFE "$d/link/index.md"

# 6. the lock is a symlink
mkdir -m 700 "$d/lk"; mkdir -m 700 "$d/elsewhere"; ln -s "$d/elsewhere" "$d/lk/index.md.lock"
run_case "symlinked lock" UNSAFE "$d/lk/index.md"

# 7. a folder owned by someone else: /usr/bin is root-owned and not writable
#    by others on every Unix; the block must refuse it without writing there.
if [ "$(id -u)" -ne 0 ] && [ -d /usr/bin ] && [ ! -O /usr/bin ]; then
  run_case "folder owned by another user (/usr/bin)" UNSAFE "/usr/bin/which-skill-test-index.md"
else
  echo "SKIP   folder owned by another user (running as root or /usr/bin missing)"
fi

# 8. a relative path (run from $d/home, so nothing lands in the repo)
run_case "relative WHICH_SKILL_INDEX" UNSAFE "which-skill/index.md"
[ ! -e "$d/home/which-skill" ] && echo "ok     nothing created for the relative path" || { BAD=$((BAD+1)); echo "NOT OK a folder was created for the relative path"; }

# 9. the default folder, too open: tightened to 0700, then OK
mkdir -p -m 755 "$d/home/.claude/which-skill"; chmod 755 "$d/home/.claude/which-skill"
run_case "default folder at 0755 (tightened)" OK -
[ "$(mode "$d/home/.claude/which-skill")" = 700 ] && echo "ok     default folder tightened to 700" || { BAD=$((BAD+1)); echo "NOT OK default folder mode $(mode "$d/home/.claude/which-skill")"; }

# 10. the default folder reached through a symlinked config folder
mkdir -m 700 "$d/realcfg"; ln -s "$d/realcfg" "$d/home/cfglink"
run_case "default folder under a symlinked config folder" UNSAFE - "$d/home/cfglink"

# 11. an ancestor writable by others without the sticky bit (0770 and 0777)
mkdir -m 770 "$d/team"; chmod 770 "$d/team"; mkdir -m 700 "$d/team/alice"
run_case "parent 0770 without sticky bit, 0700 child" UNSAFE "$d/team/alice/index.md"
mkdir -m 700 "$d/team2"; chmod 777 "$d/team2"; mkdir -m 700 "$d/team2/alice"
run_case "parent 0777 without sticky bit, 0700 child" UNSAFE "$d/team2/alice/index.md"

# 12. a sticky shared parent (like /tmp) with a private child of ours
mkdir -m 700 "$d/sticky"; chmod 1777 "$d/sticky"; mkdir -m 700 "$d/sticky/alice"
run_case "parent 1777 (sticky), 0700 child" OK "$d/sticky/alice/index.md"

# 13. missing components under a trusted parent are created, private
mkdir -m 700 "$d/trusted"
run_case "missing components under a trusted parent" OK "$d/trusted/a/b/index.md"
[ "$(mode "$d/trusted/a")" = 700 ] && [ "$(mode "$d/trusted/a/b")" = 700 ] && echo "ok     created components are 0700" || { BAD=$((BAD+1)); echo "NOT OK created components: $(mode "$d/trusted/a" 2>&1) $(mode "$d/trusted/a/b" 2>&1)"; }

# 14. an untrusted parent: nothing is created under it
mkdir -m 700 "$d/open"; chmod 777 "$d/open"
run_case "missing component under an untrusted parent" UNSAFE "$d/open/new/index.md"
[ ! -e "$d/open/new" ] && echo "ok     nothing created under the untrusted parent" || { BAD=$((BAD+1)); echo "NOT OK $d/open/new was created"; }

# 15. a symlinked config folder: refused before anything is created
mkdir -m 700 "$d/realcfg2"; ln -s "$d/realcfg2" "$d/home/cfglink2"
run_case "symlinked config folder, missing child" UNSAFE - "$d/home/cfglink2"
[ ! -e "$d/realcfg2/which-skill" ] && echo "ok     nothing created through the symlink" || { BAD=$((BAD+1)); echo "NOT OK a folder was created through the symlink"; }

# 16. an existing index the user cannot read or write: refused in a custom
#     folder (mode left as is), tightened to 0600 in the default folder
mkdir -m 700 "$d/rw"
for m in 000 200 400; do
  printf 'x\n' > "$d/rw/index.md"; chmod "$m" "$d/rw/index.md"
  run_case "custom index at $m" UNSAFE "$d/rw/index.md"
  [ "$(mode "$d/rw/index.md")" = "$((10#$m))" ] && echo "ok     custom index left at $m" || { BAD=$((BAD+1)); echo "NOT OK custom index mode changed to $(mode "$d/rw/index.md")"; }
  chmod 600 "$d/rw/index.md"
  printf 'x\n' > "$d/home/.claude/which-skill/index.md"; chmod "$m" "$d/home/.claude/which-skill/index.md"
  run_case "default index at $m (tightened)" OK -
  [ "$(mode "$d/home/.claude/which-skill/index.md")" = 600 ] && echo "ok     default index tightened from $m to 600" || { BAD=$((BAD+1)); echo "NOT OK default index mode $(mode "$d/home/.claude/which-skill/index.md")"; }
  chmod 600 "$d/home/.claude/which-skill/index.md"
done

# 16b. repeated and trailing slashes are collapsed lexically (no symlink is
#     resolved), so a valid path is not refused; a . component stays refused
mkdir -p "$d/home/.claude/which-skill"; chmod 700 "$d/home/.claude/which-skill"
run_case "CLAUDE_CONFIG_DIR with a trailing slash" OK - "$d/home/.claude/"
run_case "CLAUDE_CONFIG_DIR with a doubled slash" OK - "$d/home//.claude"
run_case "WHICH_SKILL_INDEX with //" OK "$d/good//index.md"
run_case "WHICH_SKILL_INDEX with // in the middle" OK "$d//good/index.md"
run_case "WHICH_SKILL_INDEX with /./" UNSAFE "$d/good/./index.md"
run_case "WHICH_SKILL_INDEX with /../" UNSAFE "$d/good/../good/index.md"
# discovery agrees: with a trailing slash on CLAUDE_CONFIG_DIR, no root or
# index path it prints has a //
DISC="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"DISCOVERY OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$DISC" ] || { echo "ABORT: discovery block not found in index.md"; exit 2; }
mkdir -p "$d/home/.claude/skills/s1"; printf -- '---\nname: s1\ndescription: x\n---\n' > "$d/home/.claude/skills/s1/SKILL.md"
N=$((N+1))
out="$(cd "$d/home" && env -u WHICH_SKILL_INDEX -u CLAUDE_CODE_PLUGIN_CACHE_DIR -u CLAUDE_CODE_PLUGIN_DIRS -u CLAUDE_CODE_PLUGIN_SEED_DIR HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude/" "${WS_SH:-bash}" -c "$DISC" 2>&1)"
if grep -q "$d/home/.claude/skills/s1/SKILL.md" <<< "$out" && ! grep -q '//' <<< "$out"; then
  echo "ok     discovery with a trailing-slash config folder prints single-slash paths"
else BAD=$((BAD+1)); echo "NOT OK discovery with a trailing-slash config folder:"; grep -n '//\|DISCOVERY\|s1' <<< "$out" | sed 's/^/  /' | head -20; fi
rm -rf "$d/home/.claude/skills"

# 17. chmod fails closed: a fake chmod first on PATH that either exits 1 or
#     exits 0 without changing anything (a filesystem that ignores modes).
#     The default index at 0644, the default folder at 0755, the pre-write
#     ownership check and the backup must all refuse, and the index content
#     must stay the same (cksum before = after).
block() { awk -v m="$1" '/^ *```bash$/{b="";f=1;next} f&&/^ *```$/{f=0; if (index(b,m)) {printf "%s",b; exit}} f{sub(/^  /,""); b=b $0 "\n"}' "$DOC"; }
CHK="$(block 'LOCK OK')"; BAK="$(block 'BACKUP FAILED')"
[ -n "$CHK" ] && [ -n "$BAK" ] || { echo "ABORT: ownership check or backup block not found in index.md"; exit 2; }
DI="$d/home/.claude/which-skill/index.md"; DD="$d/home/.claude/which-skill"
for fake in fail noop; do
  FB="$d/fake-$fake"; mkdir -m 700 "$FB"
  if [ "$fake" = fail ]; then printf '#!/bin/sh\necho "chmod: injected failure" >&2\nexit 1\n' > "$FB/chmod"
  else printf '#!/bin/sh\nexit 0\n' > "$FB/chmod"; fi
  chmod 700 "$FB/chmod"
  # index 0644 in a 0700 default folder
  chmod 700 "$DD"; printf 'keep me\n' > "$DI"; chmod 644 "$DI"; c0="$(cksum < "$DI")"
  FAKEBIN="$FB" run_case "default index at 0644, chmod $fake" UNSAFE -
  [ "$(cksum < "$DI")" = "$c0" ] && echo "ok     index content unchanged (chmod $fake)" || { BAD=$((BAD+1)); echo "NOT OK index content changed (chmod $fake)"; }
  # default folder at 0755
  chmod 600 "$DI"; chmod 755 "$DD"; c0="$(cksum < "$DI")"
  FAKEBIN="$FB" run_case "default folder at 0755, chmod $fake" UNSAFE -
  [ "$(cksum < "$DI")" = "$c0" ] && echo "ok     index content unchanged (chmod $fake, folder)" || { BAD=$((BAD+1)); echo "NOT OK index content changed (chmod $fake, folder)"; }
  chmod 700 "$DD"
  # the pre-write ownership check, chained to an append as documented
  N=$((N+1)); mkdir -m 700 "$DI.lock"; echo tok > "$DI.lock/owner"; chmod 644 "$DI"; c0="$(cksum < "$DI")"
  out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "${CHK//<your token>/tok} && printf 'appended\n' >> \"\$INDEX\"" 2>&1)"
  if grep -qx "INDEX PATH UNSAFE: could not restrict permissions on $DI" <<< "$out" && ! grep -qx 'LOCK OK' <<< "$out" && [ "$(cksum < "$DI")" = "$c0" ]; then
    echo "ok     pre-write check refuses, nothing appended (chmod $fake)"
  else BAD=$((BAD+1)); echo "NOT OK pre-write check (chmod $fake):"; sed 's/^/  /' <<< "$out"; fi
  rm -rf "$DI.lock"
  # the backup: moved, but never reported as BACKUP when it stays open
  N=$((N+1)); umask 022; printf 'not an index\n' > "$DI"; chmod 644 "$DI"; umask 077
  out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "$BAK" 2>&1)"
  if grep -q '^INDEX PATH UNSAFE: could not restrict permissions on ' <<< "$out" && ! grep -q '^BACKUP ' <<< "$out"; then
    echo "ok     backup refuses (chmod $fake)"
  else BAD=$((BAD+1)); echo "NOT OK backup (chmod $fake):"; sed 's/^/  /' <<< "$out"; fi
  rm -f "$DI" "$DI".bak-*
done
# the lock is born open (a fake mkdir that leaves the lock at 0755): the
# acquire block removes its own lock and refuses
ACQ="$(block 'until mkdir')"; [ -n "$ACQ" ] || { echo "ABORT: lock acquire block not found in index.md"; exit 2; }
FB="$d/fake-mkdir"; mkdir -m 700 "$FB"
printf '#!/bin/sh\n%s "$@" || exit $?\nfor a; do case "$a" in *.lock) %s 755 "$a";; esac; done\n' "$(command -v mkdir)" "$(command -v chmod)" > "$FB/mkdir"; chmod 700 "$FB/mkdir"
N=$((N+1))
out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "$ACQ" 2>&1)"
if grep -qx "INDEX PATH UNSAFE: could not restrict permissions on $DI.lock" <<< "$out" && ! grep -q '^LOCK ACQUIRED' <<< "$out" && [ ! -e "$DI.lock" ]; then
  echo "ok     open lock refused and removed"
else BAD=$((BAD+1)); echo "NOT OK open lock:"; sed 's/^/  /' <<< "$out"; fi
rm -rf "$DI.lock"; N=$((N+1))
out="$(cd "$d/home" && env HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "$ACQ" 2>&1)"
grep -q '^LOCK ACQUIRED TOKEN=' <<< "$out" && echo "ok     real mkdir: lock acquired" || { BAD=$((BAD+1)); echo "NOT OK real lock:"; sed 's/^/  /' <<< "$out"; }
rm -rf "$DI.lock"
# 18. lock commands fail closed: a fake touch or rm first on PATH that exits 1
#     or exits 0 without any effect. The heartbeat must not print LOCK OK (and
#     a chained append must not run), the release must not print LOCK
#     RELEASED, and the acquire must not print LOCK ACQUIRED when the owner
#     file cannot be written or its own cleanup does not take effect.
REL="$(block 'LOCK RELEASED')"; [ -n "$REL" ] || { echo "ABORT: release block not found in index.md"; exit 2; }
RM="$(command -v rm)"; MK="$(command -v mkdir)"; CM="$(command -v chmod)"; TC="$(command -v touch)"
printf 'keep me\n' > "$DI"; chmod 600 "$DI"
for fake in fail noop; do
  FB="$d/fake18-$fake"; mkdir -m 700 "$FB"
  if [ "$fake" = fail ]; then body='echo "injected failure" >&2; exit 1'; else body='exit 0'; fi
  printf '#!/bin/sh\n%s\n' "$body" > "$FB/touch"; printf '#!/bin/sh\n%s\n' "$body" > "$FB/rm"; chmod 700 "$FB/touch" "$FB/rm"
  # heartbeat: the lock was last refreshed long ago, touch fails or does nothing
  N=$((N+1)); "$MK" -m 700 "$DI.lock"; echo tok > "$DI.lock/owner"; "$TC" -t 202001010000 "$DI.lock"; c0="$(cksum < "$DI")"
  out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "${CHK//<your token>/tok} && printf 'appended\n' >> \"\$INDEX\"" 2>&1)"
  if grep -qx 'LOCK HEARTBEAT FAILED' <<< "$out" && ! grep -qx 'LOCK OK' <<< "$out" && [ "$(cksum < "$DI")" = "$c0" ]; then
    echo "ok     heartbeat refuses, nothing appended (touch $fake)"
  else BAD=$((BAD+1)); echo "NOT OK heartbeat (touch $fake):"; sed 's/^/  /' <<< "$out"; fi
  # release: rm fails or does nothing
  N=$((N+1))
  out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "${REL//<your token>/tok}; echo \"rc=\$?\"" 2>&1)"
  if grep -qx "LOCK RELEASE FAILED: remove $DI.lock manually after closing other sessions" <<< "$out" && ! grep -qx 'LOCK RELEASED' <<< "$out" && grep -qx 'rc=1' <<< "$out" && [ -d "$DI.lock" ]; then
    echo "ok     release refuses (rm $fake)"
  else BAD=$((BAD+1)); echo "NOT OK release (rm $fake):"; sed 's/^/  /' <<< "$out"; fi
  "$RM" -rf "$DI.lock"
  # acquire: the lock is born open and the cleanup rm fails or does nothing
  printf '#!/bin/sh\n%s "$@" || exit $?\nfor a; do case "$a" in *.lock) %s 755 "$a";; esac; done\n' "$MK" "$CM" > "$FB/mkdir"; chmod 700 "$FB/mkdir"
  N=$((N+1))
  out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "$ACQ" 2>&1)"
  if grep -qx "LOCK RELEASE FAILED: remove $DI.lock manually after closing other sessions" <<< "$out" && ! grep -q '^LOCK ACQUIRED' <<< "$out"; then
    echo "ok     acquire reports a failed cleanup (rm $fake)"
  else BAD=$((BAD+1)); echo "NOT OK acquire cleanup (rm $fake):"; sed 's/^/  /' <<< "$out"; fi
  "$RM" -rf "$DI.lock" "$FB/mkdir"
done
# acquire: the owner file cannot be written (a fake mkdir puts a folder there)
FB="$d/fake18-owner"; mkdir -m 700 "$FB"
printf '#!/bin/sh\n%s "$@" || exit $?\nfor a; do case "$a" in *.lock) %s -m 700 "$a/owner";; esac; done\n' "$MK" "$MK" > "$FB/mkdir"; chmod 700 "$FB/mkdir"
N=$((N+1))
out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "$ACQ" 2>&1)"
if grep -qx "LOCK ACQUIRE FAILED: could not write $DI.lock/owner" <<< "$out" && ! grep -q '^LOCK ACQUIRED' <<< "$out" && [ ! -e "$DI.lock" ]; then
  echo "ok     acquire refuses an unwritable owner file and removes its lock"
else BAD=$((BAD+1)); echo "NOT OK acquire owner file:"; sed 's/^/  /' <<< "$out"; fi
"$RM" -rf "$DI.lock"
# 19. a release that races with a new owner: a fake rm removes the lock and
#     recreates it before returning 0, as if another session had taken it
#     at once, with another token (released, left untouched), the same token
#     (a real failure) or no owner file yet (neutral, no manual removal)
for v in other same none; do
  FB="$d/fake19-$v"; mkdir -m 700 "$FB"
  {
    printf '#!/bin/sh\nV=%s\nfor a; do :; done\n' "$v"
    printf 'o="$(cat "$a/owner" 2>/dev/null)"\n%s "$@" || exit $?\n' "$RM"
    printf '%s -m 700 "$a"\n' "$MK"
    printf 'if [ "$V" = other ]; then echo other-token > "$a/owner"; fi\n'
    printf 'if [ "$V" = same ]; then echo "$o" > "$a/owner"; fi\nexit 0\n'
  } > "$FB/rm"; chmod 700 "$FB/rm"
  # the release block
  N=$((N+1)); "$MK" -m 700 "$DI.lock"; echo tok > "$DI.lock/owner"
  out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "${REL//<your token>/tok}; echo \"rc=\$?\"" 2>&1)"
  ok19=0
  if [ "$v" = other ]; then grep -qx 'LOCK RELEASED' <<< "$out" && grep -qx 'rc=0' <<< "$out" && [ "$(cat "$DI.lock/owner")" = other-token ] && ok19=1; fi
  if [ "$v" = same ]; then grep -qx "LOCK RELEASE FAILED: remove $DI.lock manually after closing other sessions" <<< "$out" && grep -qx 'rc=1' <<< "$out" && ok19=1; fi
  if [ "$v" = none ]; then grep -qx 'LOCK RELEASED (another session may hold the lock now)' <<< "$out" && ! grep -q 'manually' <<< "$out" && grep -qx 'rc=0' <<< "$out" && ok19=1; fi
  if [ "$ok19" = 1 ]; then echo "ok     release with a re-created lock ($v)"; else BAD=$((BAD+1)); echo "NOT OK release with a re-created lock ($v):"; sed 's/^/  /' <<< "$out"; fi
  "$RM" -rf "$DI.lock"
  # drop() in the acquire block (the lock is born open, so it is dropped)
  [ "$v" = none ] && continue
  printf '#!/bin/sh\n%s "$@" || exit $?\nfor a; do case "$a" in *.lock) %s 755 "$a";; esac; done\n' "$MK" "$CM" > "$FB/mkdir"; chmod 700 "$FB/mkdir"
  N=$((N+1))
  out="$(cd "$d/home" && env PATH="$FB:$PATH" HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "$ACQ" 2>&1)"
  ok19=0
  if [ "$v" = other ]; then grep -q '^INDEX PATH UNSAFE' <<< "$out" && ! grep -q 'LOCK RELEASE FAILED' <<< "$out" && [ "$(cat "$DI.lock/owner")" = other-token ] && ok19=1; fi
  if [ "$v" = same ]; then grep -qx "LOCK RELEASE FAILED: remove $DI.lock manually after closing other sessions" <<< "$out" && ok19=1; fi
  if [ "$ok19" = 1 ]; then echo "ok     acquire cleanup with a re-created lock ($v)"; else BAD=$((BAD+1)); echo "NOT OK acquire cleanup with a re-created lock ($v):"; sed 's/^/  /' <<< "$out"; fi
  "$RM" -rf "$DI.lock"
done

# the real commands: heartbeat, append, release
N=$((N+1))
out="$(cd "$d/home" && env HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "$ACQ" 2>&1)"; tk="$(sed -n 's/^LOCK ACQUIRED TOKEN=//p' <<< "$out")"
out="$(cd "$d/home" && env HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude" WHICH_SKILL_INDEX="$DI" "${WS_SH:-bash}" -c "${CHK//<your token>/$tk} && printf 'appended\n' >> \"\$INDEX\" && ${REL//<your token>/$tk}" 2>&1)"
if [ -n "$tk" ] && grep -qx 'LOCK OK' <<< "$out" && grep -qx 'LOCK RELEASED' <<< "$out" && [ "$(tail -1 "$DI")" = appended ] && [ ! -e "$DI.lock" ]; then
  echo "ok     real lock: acquire, heartbeat, append, release"
else BAD=$((BAD+1)); echo "NOT OK real lock cycle:"; sed 's/^/  /' <<< "$out"; fi
"$RM" -rf "$DI.lock"; rm -f "$DI"

# 20. every block derives the same normalized paths: with a trailing-slash
#     CLAUDE_CONFIG_DIR (and no WHICH_SKILL_INDEX), acquire, pre-write check
#     with an append, backup and release run a clean cycle and print no //
N=$((N+1)); "$RM" -rf "$DI.lock"; printf 'not an index\n' > "$DI"; chmod 600 "$DI"
run20() { (cd "$d/home" && env -u WHICH_SKILL_INDEX HOME="$d/home" CLAUDE_CONFIG_DIR="$d/home/.claude/" "${WS_SH:-bash}" -c "$1" 2>&1); }
o1="$(run20 "$ACQ")"; tk="$(sed -n 's/^LOCK ACQUIRED TOKEN=//p' <<< "$o1")"
o2="$(run20 "${CHK//<your token>/$tk} && printf 'appended\n' >> \"\$INDEX\"")"
o3="$(run20 "$BAK")"
o4="$(run20 "${REL//<your token>/$tk}")"
all="$o1
$o2
$o3
$o4"
bk="$(sed -n 's/^BACKUP //p' <<< "$o3")"
if [ -n "$tk" ] && grep -qx 'LOCK OK' <<< "$o2" && [ -n "$bk" ] && [ "${bk#"$DI".bak-}" != "$bk" ] && [ "$(tail -1 "$bk")" = appended ] \
   && grep -qx 'LOCK RELEASED' <<< "$o4" && [ ! -e "$DI.lock" ] && ! grep -q '//' <<< "$all"; then
  echo "ok     trailing-slash config folder: clean lock cycle, single-slash paths in every block"
else BAD=$((BAD+1)); echo "NOT OK trailing-slash config folder cycle:"; sed 's/^/  /' <<< "$all"; fi
"$RM" -rf "$DI.lock"; rm -f "$DI" "$DI".bak-*

# the real chmod still tightens: index 0644 -> OK, 0600
printf 'keep me\n' > "$DI"; chmod 644 "$DI"; c0="$(cksum < "$DI")"
run_case "default index at 0644, real chmod (tightened)" OK -
[ "$(mode "$DI")" = 600 ] && [ "$(cksum < "$DI")" = "$c0" ] && echo "ok     index tightened to 600, content unchanged" || { BAD=$((BAD+1)); echo "NOT OK index mode $(mode "$DI")"; }

echo "$N cases, $BAD not as expected (${WS_SH:-bash})"
if [ "$BAD" -eq 0 ]; then echo "TEST INDEX PATH OK"; exit 0; else echo "TEST INDEX PATH FAILED"; exit 1; fi
