#!/usr/bin/env bash
# Sandbox test of the external fallback (no claude run):
#   A. the catalog search block of search-and-answer.md, extracted verbatim and
#      run on fake marketplace catalogs (CLAUDE_CONFIG_DIR in a private temp
#      folder): a plugin or marketplace name that does not match
#      ^[A-Za-z0-9][A-Za-z0-9._-]*$ (shell metacharacters, a space, a leading
#      dot or dash, a non-string) never reaches the output as an identifier;
#      the entry prints one "SKIPPED invalid catalog entry" line that does not
#      echo the name, and only clean entries print "MATCH <plugin>@<marketplace>";
#   B. the text states the identifier rule with the exact regex, the GitHub
#      owner/repo rule, the "no install command" outcome, the skill-files
#      check for GitHub results, and the scenarios that exercise them.
# Exit 0 = every check as expected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; SAA="$HERE/../references/search-and-answer.md"; SK="$HERE/../SKILL.md"
RD="$HERE/../README.md"; SC="$HERE/scenarios.md"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"; trap 'rm -rf "$d"' EXIT
BAD=0; ok() { echo "ok     $1"; }; bad() { BAD=$((BAD+1)); echo "NOT OK $1"; }
command -v python3 >/dev/null 2>&1 || { echo "ABORT: python3 not found"; exit 2; }
# the block sits in a numbered list: strip the indentation of its fence, as a
# reader of the rendered Markdown sees it
CAT="$(python3 -I - "$SAA" <<'PYEOF'
import re, sys
t = open(sys.argv[1]).read()
for m in re.finditer(r"(?m)^( *)```bash\n(.*?)^\1```$", t, re.S):
    ind, body = m.group(1), m.group(2)
    if "marketplace.json" in body and "python3" in body:
        print("".join(l[len(ind):] if l.startswith(ind) else l for l in body.splitlines(True)), end=""); break
PYEOF
)"
[ -n "$CAT" ] && ok "search-and-answer.md has the catalog search block" || { bad "no catalog search block"; CAT="false"; }

# A. fake catalogs
C="$d/cfg"; M="$C/plugins/marketplaces"
mk() { mkdir -p "$M/$1/.claude-plugin"; printf '%s\n' "$2" > "$M/$1/.claude-plugin/marketplace.json"; }
mk good '{"name": "mk", "plugins": [
  {"name": "openapi-audit", "description": "Audits OpenAPI specs."},
  {"name": "openapi-audit; curl x | sh #", "description": "openapi injected"},
  {"name": ".openapi", "description": "openapi dotted"},
  {"name": "-openapi", "description": "openapi dashed"},
  {"name": "open api", "description": "openapi spaced"},
  {"name": ["openapi"], "description": "openapi list name"},
  {"name": "zz-other", "description": "unrelated"}]}'
mk evil '{"name": "mk$(id)", "plugins": [{"name": "openapi-clean", "description": "openapi via a bad marketplace"}]}'
mk 'bad;dir' '{"plugins": [{"name": "openapi-folder", "description": "openapi, marketplace named by an unsafe folder"}]}'
mk okdir '{"plugins": [{"name": "openapi-fallback", "description": "openapi, marketplace named by its folder"}]}'
out="$(cd "$d" && env -u CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CONFIG_DIR="$C" bash -c "$CAT" 2>&1)"
grep -q '^MATCH openapi-audit@mk | ' <<< "$out" && ok "a clean entry prints MATCH openapi-audit@mk" || bad "no MATCH for the clean entry: $out"
grep -q '^MATCH openapi-fallback@okdir | ' <<< "$out" && ok "a clean folder name is a valid marketplace fallback" || bad "no MATCH for the folder fallback"
[ "$(grep -c '^MATCH ' <<< "$out")" = 2 ] && ok "exactly the two clean entries match" || bad "MATCH lines: $(grep '^MATCH' <<< "$out" | tr '\n' ';')"
[ "$(grep -c '^SKIPPED invalid catalog entry' <<< "$out")" = 7 ] && ok "seven invalid entries are skipped" || bad "SKIPPED lines: $(grep -c '^SKIPPED' <<< "$out")"
! grep -qE 'curl|\$\(id\)|bad;dir|\.openapi|open api|-openapi' <<< "$out" && ok "no invalid name is echoed" || bad "an invalid name reached the output: $(grep -E 'curl|id\)|bad;dir|\.openapi|open api|-openapi' <<< "$out" | tr '\n' ';')"
! grep -q 'zz-other' <<< "$out" && ok "an unrelated entry does not match" || bad "unrelated entry printed"

# B. text
RX='^[A-Za-z0-9][A-Za-z0-9._-]*$'
for fl in "$SAA" "$SK" "$RD"; do grep -qF "$RX" "$fl" && ok "${fl##*/} states the identifier regex" || bad "${fl##*/} lacks the identifier regex $RX"; done
grep -qF 'no install command' "$SAA" && grep -qF 'invalid catalog entry, skipped' "$SAA" && ok "search-and-answer.md: an invalid entry gets no install command" || bad "search-and-answer.md lacks the no-install-command outcome"
grep -qF '^[A-Za-z0-9][A-Za-z0-9-]*$' "$SAA" && grep -qF '^[A-Za-z0-9._-]+$' "$SAA" && ok "search-and-answer.md states the GitHub owner and repository rules" || bad "search-and-answer.md lacks the GitHub owner/repo rules"
grep -qF 'not a skill' "$SAA" && grep -qF 'SKILL.md' <<< "$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")" && grep -qF '.claude-plugin/plugin.json' <<< "$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")" && ok "search-and-answer.md: a GitHub result must show skill files, else it is not a skill" || bad "search-and-answer.md lacks the GitHub skill-files rule"
grep -q '^## T4b ' "$SC" && grep -qF 'curl' <<< "$(sed -n '/^## T4b /,/^## /p' "$SC")" && ok "scenarios.md has T4b (metacharacters in catalog names)" || bad "scenarios.md lacks T4b"
grep -qiF 'decoy' <<< "$(sed -n '/^## T5 /,/^## T6 /p' "$SC")" && ok "scenarios.md: T5 has a decoy repository with no skill files" || bad "scenarios.md: T5 lacks the decoy"
grep -q '^## T9 ' "$SC" && grep -qF 'fresh' <<< "$(sed -n '/^## T9 /,$p' "$SC")" && ok "scenarios.md has T9 (fresh install)" || bad "scenarios.md lacks T9"
# README (stage 3): the current discovery model and the obvious placeholders
for w in 'git clone https://github.com/leonardomacielfonseca/which-skill ~/.claude/skills/which-skill' 'every parent up to the git top folder' '/apps/web:deploy' 'disable-model-invocation: true' '"user-invocable-only"' '"off"' 'only you can start it'; do
  grep -qF -- "$w" "$RD" && ok "README.md: $w" || bad "README.md lacks: $w"
done
# D8 (owner decision, 16/11/2026): the copyright holder is set; no license placeholder is left
grep -qxF 'Copyright (c) 2026 Leonardo Maciel' "$HERE/../LICENSE" && ok "LICENSE: copyright holder is Leonardo Maciel" || bad "LICENSE lacks the copyright holder"
! grep -qF '<owner>' "$RD" && ok "README.md: no <owner> placeholder left" || bad "README.md still has the <owner> placeholder"
! grep -rqF '<YOUR NAME>' "$HERE/../LICENSE" "$RD" && ok "no <YOUR NAME> placeholder left" || bad "a <YOUR NAME> placeholder is still there"
# an unfinished index (cards missing) must never hide session skills from the shortlist
for f in "$SK" "$SAA"; do
  grep -qF 'A session skill with no card yet is still a candidate' "$f" && ok "${f##*/}: uncarded session skills stay candidates" || bad "${f##*/} lacks the uncarded-skill rule"
done
DOC="$HERE/../references/index.md"
# E2-a: the clarify step weighs uncarded session skills too
grep -qF 'no card yet' <<< "$(sed -n '/^## 1\. Clarifying/,/^## 2\./p' "$SAA")" && ok "search-and-answer.md 1: the clarify step counts session skills with no card yet" || bad "search-and-answer.md 1 lacks uncarded skills in the clarify step"
grep -qF 'no card yet' <<< "$(sed -n '/^### 1\. Clarify/,/^### 2\./p' "$SK")" && ok "SKILL.md step 1: uncarded skills count when deciding to ask" || bad "SKILL.md step 1 lacks uncarded skills"
grep -q '^## T1c ' "$SC" && grep -qiF 'empty' <<< "$(sed -n '/^## T1c /,/^## /p' "$SC")" && ok "scenarios.md has T1c (vague task, empty index)" || bad "scenarios.md lacks T1c"
# E2-b: .claude/skills/<name>/SKILL.md is a skill layout too, and T5 has such a repository
grep -qF '.claude/skills/<name>/SKILL.md' <<< "$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")" && ok "search-and-answer.md 3.2 recognizes .claude/skills/<name>/SKILL.md" || bad "search-and-answer.md 3.2 lacks the .claude/skills layout"
grep -qF '.claude/skills/' <<< "$(sed -n '/^## T5 /,/^## T6 /p' "$SC")" && ok "scenarios.md: T5 has a repository with skills under .claude/skills/" || bad "scenarios.md: T5 lacks the .claude/skills positive case"
# E3-a (owner decision 16/11/2026): at most 10 uncarded skills are carded in
# the same run; more, or no index yet: one question, "Answer now" or "Build the
# full index now"; non-interactive runs take "Answer now" and end with the note
SPEC="$HERE/../../../../docs/superpowers/specs/2026-11-15-qual-skill-design.md"
for f in "$SK" "$DOC"; do
  for w in 'at most 10 session skills lack a card' '"Answer now"' '"Build the full index now"' '/which-skill index'; do
    grep -qF -- "$w" "$f" && ok "${f##*/}: $w" || bad "${f##*/} lacks: $w"
  done
  ! grep -qF 'write a card for every new session skill' "$f" && ok "${f##*/}: the old card-everything rule is gone" || bad "${f##*/} still has the old card-everything rule"
done
grep -qF 'AskUserQuestion' "$SK" && grep -qF 'non-interactive' <<< "$(grep -F '"Answer now"' "$SK")" && ok "SKILL.md: the question uses AskUserQuestion; a non-interactive run takes Answer now" || bad "SKILL.md lacks AskUserQuestion or the non-interactive fallback"
for f in "$SK" "$SAA"; do grep -qF 'counts separately from' "$f" && ok "${f##*/}: the index question counts separately from the task questions" || bad "${f##*/} lacks the separate question budget"; done
grep -qF 'Build the full index now' "$RD" && ok "README.md: first use offers the full index build" || bad "README.md lacks the first-use choice"
# The design spec stays in the author's workspace and is not shipped with the skill
if [ -f "$SPEC" ]; then grep -qF '(16/11/2026)' <<< "$(sed -n '/Se completa sozinho/,/^- \*\*/p' "$SPEC")" && ok "spec: the 16/11/2026 decision is noted under Se completa sozinho" || bad "spec lacks the dated decision note"
else ok "spec not shipped with the skill: dated-decision check skipped"; fi
T9="$(sed -n '/^## T9 /,/^## T9b /p' "$SC")"; grep -qF '"Answer now"' <<< "$T9" && grep -qF '/which-skill index' <<< "$T9" && grep -qF 'shortlisted' <<< "$T9" && ok "scenarios.md: T9 expects Answer now, cards for the shortlist and the index note" || bad "scenarios.md: T9 criterion not updated"
grep -q '^## T9b ' "$SC" && grep -qF 'AskUserQuestion' <<< "$(sed -n '/^## T9b /,/^## T9c /p' "$SC")" && ok "scenarios.md has T9b (interactive question)" || bad "scenarios.md lacks T9b"
grep -q '^## T9c ' "$SC" && grep -qF 'at most 10' <<< "$(sed -n '/^## T9c /,$p' "$SC")" && ok "scenarios.md has T9c (at most 10 new skills)" || bad "scenarios.md lacks T9c"
# E3-b: python3 is needed for manual skills and skillOverrides
grep -qF 'for manual skills and `skillOverrides`' "$RD" && ! grep -qF 'only used to search marketplace catalogs' "$RD" && ok "README.md: what python3 is needed for" || bad "README.md misstates python3"
# Round 3 E2-1: task keywords never reach the shell unquoted
S31="$(sed -n '/^### 3.1/,/^### 3.2/p' "$SAA")"
KRX='^[A-Za-z0-9][A-Za-z0-9-]*$'
grep -qF "$KRX" <<< "$S31" && grep -qF 'single quotes' <<< "$S31" && grep -qF 'no task text' <<< "$S31" && ok "search-and-answer.md 3.1: keyword regex, single quotes, no task text in commands" || bad "search-and-answer.md 3.1 lacks the keyword rule"
TAIL="$(tail -1 <<< "$CAT")"
grep -qE "' 'openapi' 'owasp' 'security'\$" <<< "$TAIL" && ok "the catalog example passes its keywords in single quotes" || bad "the catalog example does not single-quote its keywords: ${TAIL: -60}"
CAN="$d/canary"; mk kw '{"name": "kwmk", "plugins": [{"name": "semi-entry", "description": "open;api text"}]}'
CAT2="${CAT%"' 'openapi' 'owasp' 'security'"}' 'openapi' '\$(touch $CAN)' 'open;api' 'x\`touch $CAN\`'"
out2="$(cd "$d" && env -u CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CONFIG_DIR="$C" bash -c "$CAT2" 2>&1)"
[ ! -e "$CAN" ] && ok "a \$(...) or backtick keyword passed in single quotes runs nothing (no canary file)" || bad "the canary file was created"
grep -q '^IGNORED 3 keyword' <<< "$out2" && ok "the block ignores the three keywords that fail the regex" || bad "the block did not report 3 ignored keywords: $(grep -v '^MATCH\|^SKIPPED' <<< "$out2" | head -3 | tr '\n' ';')"
! grep -q 'semi-entry' <<< "$out2" && grep -q '^MATCH openapi-audit@mk' <<< "$out2" && ok "only the valid keyword is searched" || bad "an invalid keyword was searched: $(grep semi-entry <<< "$out2")"
# Round 3 E2-2: download to review, then a layout-specific install step
S32="$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")"
for w in 'download to review' 'copy exactly that skill folder' '~/.claude/skills/<name>' 'CLAUDE_CONFIG_DIR' 'never install it yourself'; do
  grep -qiF -- "$w" <<< "$S32" && ok "search-and-answer.md 3.2: $w" || bad "search-and-answer.md 3.2 lacks: $w"
done
grep -qF 'copy exactly that skill folder' <<< "$(sed -n '/^## T5 /,/^## T6 /p' "$SC")" && ok "scenarios.md: T5 expects the copy step after review" || bad "scenarios.md: T5 lacks the copy step"
# Round 3 E2-3: a new manual skill (NOCARD) is a candidate before the answer
for f in "$SK" "$SAA"; do grep -qF 'a new manual skill (a `NOCARD` file that qualifies' "$f" && ok "${f##*/}: new manual skills are pre-answer candidates" || bad "${f##*/} lacks new manual skills as candidates"; done
grep -qiF 'manual skill is the only match' <<< "$(sed -n '/^## T9c /,$p' "$SC")" && ok "scenarios.md: T9c covers a new manual skill as the only match" || bad "scenarios.md: T9c lacks the manual case"
grep -q '^## T9d ' "$SC" && grep -qF '"Answer now"' <<< "$(sed -n '/^## T9d /,$p' "$SC")" && ok "scenarios.md: T9d (Answer now with a new manual skill)" || bad "scenarios.md lacks T9d"
# Round 3 E3-1: README describes the no-python3 mode honestly
! grep -qF 'everything else works' "$RD" && grep -qF 'installed_plugins.json' "$RD" && grep -qF 'exact plugin resolution' "$RD" && grep -qF 'may not match' "$RD" && ok "README.md: python3 is needed for exact plugin resolution; the degraded mode is described" || bad "README.md misdescribes the no-python3 mode"
# E2 r4: a plugin repository without marketplace.json never gets marketplace commands
S32="$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")"
# E2 r5: the install command is bound to the reviewed skill (plugins[].source inside the repo)
S32="$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")"
# E2 r6: outside queries carry only generic capability words
S32="$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")"
grep -qF 'Queries leave this machine' <<< "$S32" && grep -qF 'generic capability words' <<< "$S32" && ok "3.2: web queries use generic capability words only" || bad "3.2 lacks the query privacy rule"
grep -qF 'Privacy canary' "$SC" && ok "scenarios.md: privacy canary in outside queries" || bad "scenarios.md lacks the privacy canary"
# E2 r7: a skill's own procedure (commands it runs when invoked) is not injection
S5="$(sed -n '/^## 5. Safety/,$p' "$SAA")"
grep -qF 'aimed at whoever is choosing or reviewing skills' <<< "$S5" && grep -qF 'is not injection' <<< "$S5" && ok "5: injection = orders aimed at the router; a skill's own procedure is not" || bad "5 lacks the narrow injection definition"
grep -qF 'Clean control' <<< "$(sed -n '/^## T7b /,/^## T8 /p' "$SC")" && ok "scenarios.md: T7b clean control with commands stays eligible" || bad "scenarios.md lacks the T7b clean control"
grep -qF "a skill's own procedure (commands it runs once called) is not injection" "$SK" && grep -qF 'its own procedure (commands it runs once called) is not injection' "$HERE/../references/index.md" && ok "SKILL.md and index.md: a skill's own procedure is not injection" || bad "SKILL.md/index.md lack the narrow injection wording"
# E2 r8: no broad "instructions aimed at the assistant" / "tried to give orders" wording left anywhere
if grep -nE 'instructions aimed at the assistant|tried to give orders|tries to give orders' "$SAA" "$SK" "$HERE/../references/index.md" >/dev/null; then bad "broad injection wording still present: $(grep -nE 'instructions aimed at the assistant|tried to give orders|tries to give orders' "$SAA" "$SK" "$HERE/../references/index.md" | cut -c1-80 | tr '\n' ' ')"; else ok "no broad injection wording left"; fi
grep -qF 'contains injection (as defined in section 5' "$SAA" && ok "ranking rule 5 refers to the section 5 definition" || bad "ranking rule 5 lacks the section 5 definition"
grep -qF 'Competing clean skills' <<< "$(sed -n '/^## T7b /,/^## T8 /p' "$SC")" && ok "scenarios.md: T7b competing clean skills" || bad "scenarios.md lacks T7b competing clean skills"
# E2 r9: dangerous procedures are judged separately; plugin command only for <source>/skills/<name>/SKILL.md
S5="$(sed -n '/^## 5. Safety/,$p' "$SAA")"
grep -qF 'Dangerous procedure' <<< "$S5" && grep -qF 'credentials' <<< "$S5" && grep -qF 'never the top recommendation' <<< "$S5" && ok "5: dangerous procedures block the top recommendation" || bad "5 lacks the dangerous-procedure rule"
grep -qF 'Dangerous procedure' <<< "$(sed -n '/^## T7b /,/^## T8 /p' "$SC")" && ok "scenarios.md: dangerous procedure (T7b) case" || bad "scenarios.md lacks the r9 cases"
# E2 r10: referenced procedure files are read; destruction is dangerous unless the task asks for it
S5="$(sed -n '/^## 5. Safety/,$p' "$SAA")"
grep -qF 'files the SKILL.md tells you to run or load for setup or execution (for example `references/setup.md`, `scripts/sync.sh`): up to 3 documentation files, then up to 3 run targets' "$SAA" && ok "candidates: referenced procedure files are read too" || bad "lacks the referenced-files rule"
grep -qF 'irreversible' <<< "$S5" && grep -qF 'unless the task itself asks for exactly that' <<< "$S5" && ok "5: destructive steps are dangerous unless asked" || bad "5 lacks the destructive-step rule"
T7B="$(sed -n '/^## T7b /,/^## T8 /p' "$SC")"
grep -qF 'Hidden procedure' <<< "$T7B" && grep -qF 'Destructive procedure' <<< "$T7B" && ok "scenarios.md: hidden and destructive procedure cases" || bad "scenarios.md lacks the r10 cases"
# E2 r11: GitHub results get the same referenced-file check
S32="$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")"
grep -qF 'fetch the files that SKILL.md tells you to run or load for setup or execution: up to 3 documentation files, then up to 3 run targets' <<< "$S32" && ok "3.2: GitHub skills have referenced procedure files fetched and judged" || bad "3.2 lacks the GitHub referenced-file rule"
grep -qF 'Hidden script' <<< "$(sed -n '/^## T5 /,/^## T6 /p' "$SC")" && ok "scenarios.md: T5 hidden script case" || bad "scenarios.md lacks the T5 hidden script case"
# E2 r12: GitHub plugins never get a plugin command (hooks/MCP run on their own, unreviewed)
S32="$(sed -n '/^### 3.2/,/^## 4/p' "$SAA")"
grep -qF 'never give a plugin command' <<< "$S32" && grep -qF 'hooks, MCP servers' <<< "$S32" && ok "3.2: GitHub plugins get no plugin command" || bad "3.2 lacks the no-plugin-command rule"
if grep -qE 'claude plugin (install|marketplace add) <|--plugin-dir <' <<< "$S32"; then bad "3.2 still shows a plugin command for GitHub"; else ok "3.2 shows no plugin command template"; fi
grep -qF 'Plugin with hooks' <<< "$(sed -n '/^## T5 /,/^## T6 /p' "$SC")" && ok "scenarios.md: T5 plugin-with-hooks case" || bad "scenarios.md lacks the T5 plugin-with-hooks case"
# E2 r13: SKILL.md and scenarios agree: no plugin command for GitHub plugins
grep -qF 'GitHub repository that is a plugin never gets a plugin command' "$SK" && ok "SKILL.md: GitHub plugins get no plugin command" || bad "SKILL.md lacks the no-plugin-command rule"
if grep -qF 'plugin flow' "$SC" "$SK" "$SAA" "$RD"; then bad "'plugin flow' wording still present for GitHub"; else ok "no 'plugin flow' wording left"; fi
# Fable r1
S5="$(sed -n '/^## 5. Safety/,$p' "$SAA")"
grep -qF "that its stated job does not need" <<< "$S5" && grep -qF "its own service" <<< "$S5" && ok "F1: own-service keys and uploads are ordinary" || bad "F1: dangerous rule still bars own-service API skills"
grep -qF 'the covering plugin folder of its active copy' "$SAA" && grep -qF 'does not bar the skill by itself' "$SAA" && ok "F2: plugin skills read shared files inside the plugin folder" || bad "F2: procedure-file boundary bars plugin shared files"
grep -qF 'name before the `@`' "$SAA" && grep -qF 'already installed from' "$SAA" && ok "F3: catalog drops plugins installed from another marketplace" || bad "F3: catalog may suggest an installed plugin"
grep -qF "the session's primary working directory" "$HERE/../references/index.md" && ok "F4: index.md compares CWD with the session folder" || bad "F4: CWD drift not handled"
if grep -qF 'or plugin manifest was seen' "$RD" || grep -qF 'or a `.claude-plugin/plugin.json` or `.claude-plugin/marketplace.json` that lists skills' "$SAA"; then bad "F5: GitHub skill rule differs between files"; else ok "F5: GitHub skill rule is SKILL.md-only everywhere"; fi
# Fable r2
grep -qF "credentials or data its stated job does not need" "$SK" && ok "G1: SKILL.md dangerous rule matches section 5" || bad "G1: SKILL.md dangerous rule is unqualified"
grep -qF 'open it with Read only, never in a shell command' "$SAA" && grep -qF 'Referenced procedure files' "$HERE/../references/index.md" && ok "G2: referenced files: Read only, safe names, index.md exception" || bad "G2: referenced-file path rule missing"
grep -qF 'package manager' <<< "$(sed -n '/^## 5. Safety/,$p' "$SAA")" && ok "G3: package-manager installs are ordinary, curl|sh is not" || bad "G3: sudo/curl dependency installs ambiguous"
grep -qF 'opens only the few skill files that matter' "$RD" && ok "G4: README describes the read correctly" || bad "G4: README read claim"
# Fable r3
grep -qF 'join a relative reference to the reference base' "$SAA" && grep -qF 'the skill folder for a skill (not the plugin folder)' "$SAA" && grep -qF 'replace a leading `${CLAUDE_SKILL_DIR}`' "$SAA" && grep -qF "joined to the candidate's reference base, the skill folder" "$HERE/../references/index.md" && ok "H1: references resolve from the skill folder, variables first" || bad "H1: reference join base / variable forms"
if grep -qF 'with the system package manager' "$SAA"; then bad "H2: sudo wording differs between lists"; else ok "H2: one package-manager wording"; fi
grep -qF 'Plugin hidden procedure' "$SC" && ok "H1: T7b plugin and variable-form case" || bad "H1: T7b lacks the plugin case"
# Fable r4: referenced files never include secret-holding files
grep -qF 'not opened: may hold secrets' "$SAA" && grep -qF 'that holds, or is meant to hold, credentials or user data (see there)' "$HERE/../references/index.md" && ok "I1: secret-holding files are never opened as referenced files" || bad "I1: referenced-file rule may open secrets"
if [ "$BAD" -eq 0 ]; then echo "TEST CATALOG OK"; exit 0; else echo "TEST CATALOG FAILED ($BAD)"; exit 1; fi
