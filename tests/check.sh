#!/usr/bin/env bash
# Structural checks for the which-skill folder. Exit 0 = all pass, 1 = a check
# failed, 2 = aborted (the temp folder for plugin validate could not be made).
# No `set -e`: failures are counted, not fatal. `set -u` and `pipefail` are safe
# here because every pipeline below reads small files to the end.
set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd -P)" || { echo "ABORT: cannot resolve the skill folder" >&2; exit 2; }
case "$SKILL_DIR" in /?*) ;; *) echo "ABORT: bad skill folder '$SKILL_DIR'" >&2; exit 2;; esac
FAILS=0
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
ok() { echo "ok:   $1"; }

SKILL="$SKILL_DIR/SKILL.md"

# 1. SKILL.md, name, description length
if [ ! -f "$SKILL" ]; then
  fail "SKILL.md does not exist"
else
  FM="$(sed -n '2,/^---$/p' "$SKILL")"
  if grep -qx 'name: which-skill' <<< "$FM"; then ok "frontmatter name"; else fail "frontmatter must contain 'name: which-skill'"; fi
  DESC=$(sed -n 's/^description: *//p' <<< "$FM" | sed -n '1p')
  DESC=${DESC#\"}; DESC=${DESC%\"}
  LEN=${#DESC}
  if [ "$LEN" -gt 0 ] && [ "$LEN" -le 1024 ]; then ok "description length $LEN"; else fail "description length $LEN (must be 1..1024)"; fi
  LINES=$(wc -l < "$SKILL" | tr -d ' ')
  if [ "$LINES" -le 150 ]; then ok "SKILL.md has $LINES lines"; else fail "SKILL.md has $LINES lines (max 150)"; fi

  # 2. linked references exist
  for ref in $(grep -oE 'references/[A-Za-z0-9._-]+\.md' "$SKILL" | sort -u); do
    if [ -f "$SKILL_DIR/$ref" ]; then ok "reference $ref"; else fail "missing reference $ref"; fi
  done
fi

# 3. privacy grep (whole-word names, paths, emails), excluding tests/.
# The private names live in tests/private-words.local (one word per line). That
# file is never published, so a public checkout skips only the names part.
PW="$SKILL_DIR/tests/private-words.local"
if [ -f "$PW" ]; then HITS=$(grep -rniwF -f "$PW" "$SKILL_DIR" --exclude-dir=tests 2>/dev/null)
else HITS=""; ok "privacy names list not present (public checkout): names part skipped"; fi
# D8 (owner decision, 16/11/2026): the copyright holder is public on purpose; only these two exact lines are allowed
HITS=$(grep -vxF -e "$SKILL_DIR/LICENSE:3:Copyright (c) 2026 Leonardo Maciel" -e "$SKILL_DIR/README.md:$(grep -nxF '[MIT](LICENSE). Copyright (c) 2026 Leonardo Maciel.' "$SKILL_DIR/README.md" | cut -d: -f1):[MIT](LICENSE). Copyright (c) 2026 Leonardo Maciel." <<< "$HITS")
HITS2=$(grep -rniE '/Users/|@gmail' "$SKILL_DIR" --exclude-dir=tests 2>/dev/null)
if [ -z "$HITS$HITS2" ]; then ok "privacy grep clean"; else fail "privacy hits:"; echo "$HITS$HITS2"; fi

# 4. English only: no accented Portuguese characters in *.md
ACC=$(grep -rnE '[ãõçáéíóúâêô]' "$SKILL_DIR" --include='*.md' --exclude-dir=tests 2>/dev/null)
if [ -z "$ACC" ]; then ok "no accented characters"; else fail "accented characters found:"; echo "$ACC"; fi

# 5. plugin validate (bare skill folders are rejected, so wrap in a temp plugin)
# Every path below is built from TMP, so TMP is validated before anything is
# created, copied or removed, and the cleanup trap is set only after that.
abort() { echo "ABORT: $*" >&2; exit 2; }
if command -v claude >/dev/null 2>&1; then
  TMP="$(mktemp -d 2>/dev/null)" || abort "mktemp -d failed (TMPDIR=${TMPDIR:-unset}); plugin validate not run"
  case "$TMP" in /?*) ;; *) abort "mktemp -d returned a non-absolute path '$TMP'";; esac
  [ -d "$TMP" ] && [ ! -L "$TMP" ] || abort "mktemp -d result is not a real directory: $TMP"
  TMP_REAL="$(cd -P "$TMP" 2>/dev/null && pwd -P)" || abort "cannot resolve $TMP"
  [ "$TMP_REAL" != / ] || abort "mktemp -d resolved to /"
  TMP="$TMP_REAL"
  trap 'rm -rf "$TMP"' EXIT
  if mkdir "$TMP/skills" "$TMP/.claude-plugin" \
     && cp -R "$SKILL_DIR" "$TMP/skills/which-skill" \
     && rm -rf "$TMP/skills/which-skill/tests" \
     && echo '{"name":"which-skill-check","version":"0.0.0","description":"Temporary wrapper for validation"}' > "$TMP/.claude-plugin/plugin.json"; then
    if (cd "$TMP" && claude plugin validate . >/dev/null 2>&1); then ok "claude plugin validate"; else fail "claude plugin validate failed (run it in a wrapper dir to see why)"; fi
  else
    fail "could not build the validation wrapper in $TMP"
  fi
else
  echo "SKIP: claude CLI not found, plugin validate not run"
fi

# 6. self-test of the command audit (synthetic transcripts, no claude run)
if command -v python3 >/dev/null 2>&1; then
  if AOUT="$(python3 -I "$SKILL_DIR/tests/test_audit.py" 2>&1)"; then ok "audit self-test ($(tail -2 <<< "$AOUT" | head -1))"; else fail "audit self-test:"; grep -v '^ok ' <<< "$AOUT"; fi
else
  fail "python3 not found, audit self-test not run"
fi

# 7. self-test of check-index.sh (synthetic indexes)
if command -v python3 >/dev/null 2>&1; then
  if COUT="$(python3 -I "$SKILL_DIR/tests/test_check_index.py" 2>&1)"; then ok "check-index self-test ($(tail -2 <<< "$COUT" | head -1))"; else fail "check-index self-test:"; grep -v '^ok ' <<< "$COUT"; fi
fi

# 8. sandbox simulation of the post-lock re-discovery (blocks copied from index.md)
if SOUT="$(bash "$SKILL_DIR/tests/sim-relock.sh" 2>&1)"; then ok "relock simulation ($(tail -1 <<< "$SOUT"))"; else fail "relock simulation:"; grep -v '^ok' <<< "$SOUT"; fi

# 9. sandbox test of the index path check (block copied from index.md)
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP: $sh not found, index path check not run with it"; continue; }
  if POUT="$(WS_SH="$sh" bash "$SKILL_DIR/tests/test-index-path.sh" 2>&1)"; then ok "index path check ($(tail -2 <<< "$POUT" | head -1))"; else fail "index path check ($sh):"; grep -v '^ok' <<< "$POUT"; fi
done

# 10. sandbox test of how run.sh writes tests/out (fake claude, no real run)
if ROUT="$(bash "$SKILL_DIR/tests/test-run-out.sh" 2>&1)"; then ok "run.sh output privacy ($(tail -1 <<< "$ROUT"))"; else fail "run.sh output privacy:"; grep -v '^ok' <<< "$ROUT"; fi

# 11. sandbox test: skill folders named with shell syntax never run as commands
if UOUT="$(bash "$SKILL_DIR/tests/test-unsafe-paths.sh" 2>&1)"; then ok "unsafe paths ($(tail -1 <<< "$UOUT"))"; else fail "unsafe paths:"; grep -v '^ok' <<< "$UOUT"; fi

# 12. sandbox test of discovery edge cases: newline root injection, unreadable
#     index, SKILL.md behind a FIFO or /dev/zero, symlinks whose target leaves
#     the skill folders (bash and zsh, with a watchdog)
if EOUT="$(bash "$SKILL_DIR/tests/test-discovery-edge.sh" 2>&1)"; then ok "discovery edge cases ($(tail -1 <<< "$EOUT"))"; else fail "discovery edge cases:"; grep -v '^ok' <<< "$EOUT"; fi

# 13. stateful sandbox test of the downgraded transition: a verified card whose
#     SKILL.md became a FIFO, a dangling symlink or moved to an unsafe folder
#     (bash and zsh; discovery, plan rules, check-index --located)
if DOUT="$(bash "$SKILL_DIR/tests/test-downgrade.sh" 2>&1)"; then ok "downgrade transition ($(tail -1 <<< "$DOUT"))"; else fail "downgrade transition:"; grep -v '^ok' <<< "$DOUT"; fi

# 14. sandbox test of the active plugin copy: installed_plugins.json points to
#     v2, v1 stays in the cache (bash and zsh; ACTIVE, STALE-COPY, fallback),
#     and synced ~gN generations (the highest is effective)
if AOUT2="$(bash "$SKILL_DIR/tests/test-active-copy.sh" 2>&1)"; then ok "active plugin copy ($(tail -1 <<< "$AOUT2"))"; else fail "active plugin copy:"; grep -v '^ok' <<< "$AOUT2"; fi

# 15. sandbox simulation of which file a session opens at shortlist time: two
#     projects with different active copies, a card written by the other one
#     (bash and zsh; the documented rule selects this session's copy)
if SOUT2="$(bash "$SKILL_DIR/tests/test-shortlist-copy.sh" 2>&1)"; then ok "shortlist copy ($(tail -1 <<< "$SOUT2"))"; else fail "shortlist copy:"; grep -v '^ok' <<< "$SOUT2"; fi

# 16. round 53 sandbox test: project roots from the working folder up to the
#     git top folder (an intermediate .claude/skills, a folder-name clash with
#     the top one) and manual skills (disable-model-invocation: true in a user
#     or project skill), discovery under bash and zsh plus the shortlist rule
#     and the text of the three files; round 54: skillOverrides (off,
#     user-invocable-only, unreadable settings) and the manual exception text
if MOUT="$(bash "$SKILL_DIR/tests/test-manual-nested.sh" 2>&1)"; then ok "manual and nested skills ($(tail -1 <<< "$MOUT"))"; else fail "manual and nested skills:"; grep -v '^ok' <<< "$MOUT"; fi

# 17. external fallback: the catalog search block run on fake catalogs whose
#     plugin and marketplace names carry shell metacharacters (no unsafe name
#     reaches a MATCH line), and the text of the identifier, GitHub skill-file
#     and fresh-install rules and scenarios
if COUT2="$(bash "$SKILL_DIR/tests/test-catalog.sh" 2>&1)"; then ok "catalog identifiers ($(tail -1 <<< "$COUT2"))"; else fail "catalog identifiers:"; grep -v '^ok' <<< "$COUT2"; fi

# 17b. deferred T9: the "paste the block" rule is stated in index.md and SKILL.md
if grep -qF -- '- **Paste the block.**' "$SKILL_DIR/references/index.md" && grep -qF 'never run one by line range or pattern of a skill file' "$SKILL"; then ok "paste-the-block rule"; else fail "the paste-the-block rule is missing in index.md or SKILL.md"; fi

# 17c. deferred Fable r5, reversed by Codex adiados r27: run targets get the
#     same secret checks (name list, .env*, a key put in them); such a script
#     is not opened and, as an unopened run target, bars the top spot (T7c)
SAA_="$SKILL_DIR/references/search-and-answer.md"
if grep -qF 'A file the SKILL.md tells you to run is a script, and the secret checks apply to it too' "$SAA_" \
   && grep -qF 'The names below apply to every referenced file, run targets included' "$SAA_" \
   && ! grep -qF 'open it whatever its name' "$SAA_" \
   && grep -qF 'a script the SKILL.md tells you to run gets the same secret checks' "$SKILL_DIR/references/index.md" && grep -A8 '^## T7c' "$SKILL_DIR/tests/scenarios.md" | grep -qF 'credentials.sh'; then ok "run targets get the secret checks"
else fail "run targets do not get the secret-name checks (search-and-answer.md, index.md, T7c)"; fi

# 17d. deferred E2 r4: the question stage sees a new manual skill (no card yet):
#     discovery and overrides run before deciding whether to ask; scenario T9e
QS_="$(sed -n '/^## 1\. Clarifying questions/,/^## 2/p' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'every manual skill whose card lacks `invocation: manual` or is `CHANGED`' <<< "$QS_" && grep -qF '`CHANGED`' <<< "$QS_" && grep -q '^## T9f' "$SKILL_DIR/tests/scenarios.md" && grep -qF 'run the discovery block and the overrides block of index.md' <<< "$QS_" && grep -q '^## T9e' "$SKILL_DIR/tests/scenarios.md"; then ok "question stage sees new manual skills"
else fail "the question stage does not include new manual skills (search-and-answer.md section 1, scenario T9e)"; fi

# 17e. Codex adiados r2: a command a same-name skill wins over maps to no key;
#     legacy command files get the same procedure-file review (T7d); a manual
#     status change from skillOverrides alone rebuilds the card (T9g)
IDX_="$SKILL_DIR/references/index.md"
if grep -qF 'maps to no key: it is not a session skill, never a candidate, and never counted' "$IDX_" \
   && grep -qF 'the instruction file (its SKILL.md, or the command file of a legacy command)' "$SKILL_DIR/references/search-and-answer.md" \
   && grep -qF -- '- **manual status changed**' "$IDX_" \
   && grep -q '^## T7d' "$SKILL_DIR/tests/scenarios.md" && grep -q '^## T9g' "$SKILL_DIR/tests/scenarios.md"; then ok "Codex adiados r2 rules"
else fail "Codex adiados r2 rules missing (command under a skill maps to no key; command procedure review; manual status changed; T7d; T9g)"; fi

# 17f. Codex adiados r3: the write gate lists manual status changed; a run
#     target any reviewed procedure file says to fill with a key is never
#     opened (T7e); every located manual skill whose card is CHANGED is read
#     by its current description before asking
if grep -qF 'If nothing is new, changed, secret name, manual status changed, unreadable,' "$IDX_" \
   && grep -qF 'Read the documentation files first' "$SKILL_DIR/references/search-and-answer.md" \
   && grep -q '^## T7e' "$SKILL_DIR/tests/scenarios.md" \
   && grep -qF 'whose card lacks `invocation: manual` or is `CHANGED`' "$SKILL_DIR/references/search-and-answer.md"; then ok "Codex adiados r3 rules"
else fail "Codex adiados r3 rules missing (write gate, indirect key-filled script T7e, CHANGED manual description)"; fi

# 17g. Codex adiados r4: a manual skill or command with no frontmatter
#     description is matched by the first paragraph of its body (T9h)
if [ "$(grep -cF 'its first frontmatter block, or, when that is missing or empty, by the first paragraph of its body' "$SKILL_DIR/references/search-and-answer.md")" = 2 ] && grep -q '^## T9h' "$SKILL_DIR/tests/scenarios.md"; then ok "description-less manual skills matched by their body"
else fail "description-less manual skills: first-paragraph rule missing in search-and-answer.md (question stage and shortlist) or T9h"; fi

# 17h. Codex adiados r5: a run target is opened only after every referenced
#     documentation file was read; otherwise the skill cannot be the top (T7f)
if grep -qF 'A run target is opened only when every documentation file in the queue, however it got there (from the SKILL.md or from any opened file), was read' "$SKILL_DIR/references/search-and-answer.md" && grep -q '^## T7f' "$SKILL_DIR/tests/scenarios.md"; then ok "run targets only after all documentation"
else fail "run-target gate after documentation missing (search-and-answer.md, T7f)"; fi

# 17i. Codex adiados r6: files a reviewed documentation file says to run or
#     load join the same queues (T7g); GitHub uses the same per-kind budget
SAA_="$SKILL_DIR/references/search-and-answer.md"
if grep -qF 'A file that any file you opened (a documentation file or a run target) tells you to run or load' "$SAA_" && grep -qF 'advanced.md' "$SKILL_DIR/tests/scenarios.md" && grep -qF 'joins the same queues (a document to the documentation files, a script to the run targets)' "$SAA_" && grep -qF 'fetch the files that SKILL.md tells you to run or load for setup or execution: up to 3 documentation files, then up to 3 run targets' "$SAA_" && grep -q '^## T7g' "$SKILL_DIR/tests/scenarios.md"; then ok "indirect procedure files and GitHub budget"
else fail "indirect procedure files or GitHub per-kind budget missing (search-and-answer.md, T7g)"; fi

# 17j. Codex adiados r7: every run target not opened, for any reason, keeps
#     the skill from the top spot (T7c, T7e)
if grep -qF 'Every run target that is not opened, for any reason' "$SKILL_DIR/references/search-and-answer.md" && ! grep -qF 'skipped as possibly holding secrets); otherwise it is not opened, and a run target not opened for that reason' "$SKILL_DIR/references/search-and-answer.md" && grep -A8 '^## T7c' "$SKILL_DIR/tests/scenarios.md" | grep -qF 'neither skill is the top recommendation'; then ok "unopened run targets bar the top spot"
else fail "unopened run targets do not bar the top spot (search-and-answer.md, T7c)"; fi

# 17k. Codex adiados r8: the "does not bar" exceptions name documentation
#     files only, and the closing rule covers every unopened run target
P50_="$(grep -F '**Which file to open.**' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'A documentation file that is not opened (it may hold secrets, or it is outside the boundary) is noted and does not bar the skill by itself' <<< "$P50_" \
   && grep -qF 'keeps the skill from the top spot: any run target not opened (for any reason above, or outside the boundary, or missing), and any documentation file inside the boundary that exists but cannot be read' <<< "$P50_" \
   && ! grep -qF 'which does not bar the skill by itself. Only regular files' <<< "$P50_" && ! grep -qF 'Only a file inside the boundary that exists but cannot be read keeps the skill' <<< "$P50_"; then ok "procedure-file exceptions consistent"
else fail "procedure-file paragraph still has exceptions that let an unopened run target through"; fi

# 17l. Codex adiados r9: a file that an opened file runs or sources joins the
#     queues (wrapper -> payload, T7h); imports are a stated limit
P50_="$(grep -F '**Which file to open.**' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'A file that any file you opened (a documentation file or a run target) tells you to run or load, or runs or sources itself' <<< "$P50_" && grep -qF 'Code a script reaches only through imports or libraries is not followed' <<< "$P50_" && grep -q '^## T7h' "$SKILL_DIR/tests/scenarios.md"; then ok "wrapper scripts followed to their payload"
else fail "wrapper -> payload rule missing (search-and-answer.md, T7h)"; fi

# 17m. Codex adiados r10: the secret checks apply to every queued file, a
#     sourced file counts as loaded (T7h variant with secrets.sh)
P50_="$(grep -F '**Which file to open.**' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'The secret checks below apply to every file in the queues, however it got there' <<< "$P50_" && grep -qF 'but it is code: when it is not opened it bars the top spot like a run target' <<< "$P50_" && grep -qF 'secrets.sh' "$SKILL_DIR/tests/scenarios.md"; then ok "secret checks on every queued file"
else fail "secret checks do not cover indirectly queued or sourced files (search-and-answer.md, T7h)"; fi

# 17n. Codex adiados r12: a legacy command is named by its file name only (the
#     docs: commands support the same frontmatter except name and paths); a key
#     instruction in any opened file counts, run targets add no documentation
P50_="$(grep -F '**Which file to open.**' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'except `name` and `paths`' "$IDX_" && ! grep -qF 'because the docs do not say whether Claude Code honors it there' "$IDX_" \
   && grep -qF 'or any file you opened for it (the SKILL.md, a documentation file or a run target) tells you to put a key' <<< "$P50_" \
   && grep -qF 'a run target never adds documentation' <<< "$P50_" && grep -qF 'a key or user data put in it, said by any opened file of the skill' "$IDX_"; then ok "command names and key instructions from any opened file"
else fail "Codex adiados r12 rules missing (command name from file only; key instruction from any opened file; run targets add no documentation)"; fi

# 17o. Codex adiados r13: one reference base per candidate (decoy variant of T7d)
if grep -qF 'the one base for every reference of the candidate' "$SKILL_DIR/references/search-and-answer.md" && grep -qF 'the session working folder for a legacy command (its text runs there, like any injected command)' "$SKILL_DIR/references/search-and-answer.md" && grep -qF 'Nested working folder variant' "$SKILL_DIR/tests/scenarios.md" && grep -qF 'Decoy variant' "$SKILL_DIR/tests/scenarios.md" && ! grep -qF 'join a relative reference to the skill folder (not the plugin folder);' "$SKILL_DIR/references/search-and-answer.md"; then ok "one reference base per candidate"
else fail "reference base for commands is ambiguous (search-and-answer.md, T7d decoy)"; fi

# 17p. Codex adiados r18: a bare relative path inside a run target runs from the
#     session folder, so it is outside the boundary (decoy variant of T7h)
P50_="$(grep -F '**Which file to open.**' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'Inside a run target, a bare relative path runs from the session folder, not the skill folder' <<< "$P50_" && grep -qF 'session-folder decoy' "$SKILL_DIR/tests/scenarios.md"; then ok "relative paths inside scripts resolved from the session folder"
else fail "relative paths inside run targets not handled (search-and-answer.md, T7h decoy)"; fi

# 17q. Codex adiados r21: a run target whose actual path is not certain from
#     the text (a directory change before it, a variable, a computed path) is
#     not opened and bars the top spot (cd variant of T7d)
P50_="$(grep -F '**Which file to open.**' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'A run target whose actual path you cannot tell with certainty from the text' <<< "$P50_" && grep -qF 'cd helpers && ./publish.sh' "$SKILL_DIR/tests/scenarios.md"; then ok "uncertain run-target paths are not opened"
else fail "uncertain run-target paths rule missing (search-and-answer.md, T7d cd variant)"; fi

# 17r. Codex adiados r22: prose references in a SKILL.md resolve against the
#     skill folder (the model gets the skill's base directory); a command
#     injected with !`...` runs in the session folder (injected variant of T7h)
P50_="$(grep -F '**Which file to open.**' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'a command injected with' <<< "$P50_" && grep -qF 'or in a fenced block opened with' <<< "$P50_" && grep -qF 'Fenced variant' "$SKILL_DIR/tests/scenarios.md" && grep -qF 'runs in the session working folder before the model reads anything' <<< "$P50_" && grep -qF 'Injected variant' "$SKILL_DIR/tests/scenarios.md"; then ok "injected commands resolved from the session folder"
else fail "injected-command rule missing (search-and-answer.md, T7h injected variant)"; fi

# 17s. Codex adiados r24: a task runner's manifest is its run target (T7i)
P50_="$(grep -F '**Which file to open.**' "$SKILL_DIR/references/search-and-answer.md")"
if grep -qF 'A command that runs code declared in a manifest' <<< "$P50_" && grep -q '^## T7i' "$SKILL_DIR/tests/scenarios.md"; then ok "task-runner manifests are run targets"
else fail "task-runner rule missing (search-and-answer.md, T7i)"; fi

# 17t. Codex adiados r26: the procedure-file check runs per batch of newly
#     queued files, before any of them is opened
if grep -qF 'run this check block on each new batch of files before opening any of them' "$IDX_" && grep -qF 'every file that joins the queue goes through the procedure-file check' "$SKILL_DIR/references/search-and-answer.md"; then ok "procedure-file check per batch"
else fail "procedure-file check per batch missing (index.md, search-and-answer.md)"; fi

# 17u. Codex adiados r28: paths inside a manifest recipe are uncertain; a
#     legacy command with a secret-like name is never opened
if grep -qF 'A path inside a recipe of that manifest is uncertain' "$SKILL_DIR/references/search-and-answer.md" && grep -qF 'is printed as `SKIPPED-SECRET-NAME` by discovery and is never opened' "$IDX_"; then ok "recipe paths uncertain; secret-named commands never opened"
else fail "Codex adiados r28 rules missing (recipe paths; secret-named commands)"; fi

# 17v. Codex adiados r30: secret names compared in any case (mixed-case
#     variant of T7c); a card of a SKIPPED-SECRET-NAME file is neutralized
if grep -qF 'compare file names in any case' "$SKILL_DIR/references/search-and-answer.md" && grep -qF 'Credentials.sh' "$SKILL_DIR/tests/scenarios.md" \
   && grep -qF -- '- **secret name**' "$IDX_" && grep -qF 'when it is on a `SKIPPED-SECRET-NAME` line' "$IDX_"; then ok "secret names in any case; secret-name cards neutralized"
else fail "Codex adiados r30 rules missing (case-insensitive names; secret-name card handling)"; fi

# 17w. Codex adiados r32: a leading ${CLAUDE_PROJECT_DIR} resolves against the
#     project top folder (boundary: that folder), scenario T7j
if grep -qF 'a leading `${CLAUDE_PROJECT_DIR}` with the project top folder' "$SKILL_DIR/references/search-and-answer.md" && grep -qF 'or the project top folder `ROOT` that a leading `${CLAUDE_PROJECT_DIR}` stands for, which is then also the boundary' "$IDX_" && grep -q '^## T7j' "$SKILL_DIR/tests/scenarios.md"; then ok "CLAUDE_PROJECT_DIR resolved"
else fail "CLAUDE_PROJECT_DIR rule missing (search-and-answer.md, T7j)"; fi

# 17x. Codex adiados r37: $0 inside a sourced file is the outer script
if grep -qF 'inside a sourced file `$0` is the outer script' "$SKILL_DIR/references/search-and-answer.md" && grep -qF 'Sourced $0 variant' "$SKILL_DIR/tests/scenarios.md"; then ok "\$0 in sourced files treated as uncertain"
else fail "sourced-file \$0 rule missing (search-and-answer.md, T7h)"; fi
# 17y. Codex adiados r38: secret-like FOLDER names below the boundary count (PROCFILE SECRET)
if grep -qF 'PROCFILE SECRET' "$SKILL_DIR/references/index.md" && grep -qF 'every folder of the path below the boundary' "$SKILL_DIR/references/search-and-answer.md"; then ok "secret-like folders in procedure paths refused"
else fail "secret-like folder rule missing (index.md PROCFILE SECRET, search-and-answer.md)"; fi
# 17z. Codex adiados r40: ROOT and every complete joined path pass the whole-value
#     safe-character check before they are written into the PROCFILE block
if grep -qF '`ROOT` itself must pass the safe set of index.md as a whole' "$SKILL_DIR/references/search-and-answer.md" && grep -qF '`ROOT` is printed by the project-root block without that check' "$IDX_" && grep -qF 'Unsafe project folder variant (Codex adiados r40)' "$SKILL_DIR/tests/scenarios.md" \
   && grep -qF '`/home/alice/Client Work/app` passes' "$IDX_" && grep -qF 'Space variant (Codex adiados r41)' "$SKILL_DIR/tests/scenarios.md" \
   && ! grep -qF 'must match `^/[A-Za-z0-9._/+@-]+$`' "$IDX_" && ! grep -qF 'must match `^/[A-Za-z0-9._/+@-]+$`' "$SKILL_DIR/references/search-and-answer.md"; then ok "unsafe ROOT never enters the procedure-file block"
else fail "whole-value check for ROOT/joined paths missing (search-and-answer.md, index.md, T7j)"; fi

# 18. deferred E1 r53 (3) and E1 r55: the skill roots are walked only as deep
#     as a skill file can sit (a symlink to a large tree is never walked), and
#     legacy command files (<config>/commands, <D>/.claude/commands) are
#     located; the text of index.md states both
if TOUT="$(bash "$SKILL_DIR/tests/test-depth-commands.sh" 2>&1)"; then ok "depth and legacy commands ($(tail -1 <<< "$TOUT"))"; else fail "depth and legacy commands:"; grep -v '^ok' <<< "$TOUT"; fi

# 19. Codex adiados r25: the procedure-file check block refuses symlinks,
#     non-regular files and folders leaving the boundary before any Read
if PFOUT="$(bash "$SKILL_DIR/tests/test-procfile.sh" 2>&1)"; then ok "procedure-file check ($(tail -1 <<< "$PFOUT"))"; else fail "procedure-file check:"; grep -v '^ok' <<< "$PFOUT"; fi

if [ "$FAILS" -eq 0 ]; then echo "ALL PASSED"; exit 0; else echo "$FAILS check(s) failed"; exit 1; fi
