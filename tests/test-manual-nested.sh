#!/usr/bin/env bash
# Sandbox test of round 53 (no claude run), under bash and zsh, with the
# discovery block extracted verbatim from index.md:
#   A. project roots from the working folder up to the git top folder: a
#      session started in <repo>/apps/web/src searches <D>/.claude/skills for
#      every D from there up to <repo> (code.claude.com/docs/en/skills, "Load
#      skills in monorepos and subdirectories"), so <repo>/apps/.claude/skills
#      is a ROOT_DIR and its files are located; a sibling folder
#      (<repo>/other) and a folder below the working folder are never
#      searched; outside a git repository only the working folder is;
#   B. the shortlist rule of index.md and search-and-answer.md, as this test
#      reads it (ELIG_PY, like SHADOW_PY in test-shortlist-copy.sh: the
#      model's reading, not its behavior): a folder-name clash between the top
#      folder and an intermediate one gives `/deploy` to the top folder and
#      `/apps:deploy` to the other; a local (user or project) skill whose first
#      frontmatter block is `ok` and has `disable-model-invocation: true` is a
#      session skill although the session does not list it (a manual card,
#      callable only by the user), and it shadows like any personal skill; the
#      flag in an `uncertain` block, the flag with `user-invocable: false`, and
#      a plugin skill with the flag add nothing;
#   C. the three files state both rules with the same words;
#   D. round 54: skillOverrides (code.claude.com/docs/en/skills, "Override
#      skill visibility from settings"), read by the overrides block of
#      index.md from the user settings, the project and local settings of
#      every project folder and the managed files: "off" (or a value that is
#      not one of the four states) for a skill's name or folder name keeps it
#      from being manual; "user-invocable-only" makes a local skill manual even
#      without the frontmatter flag; "on" and "name-only" leave the flag in
#      charge; a settings file that exists but cannot be read or parsed makes
#      no skill manual in that run; a manual skill can be the top
#      recommendation; no sentence of the three files excludes unlisted skills
#      without the manual exception.
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
OVR="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"OVERRIDES OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$OVR" ] && ok "index.md has the overrides block" || bad "index.md has no overrides block (ending OVERRIDES OK)"
command -v python3 >/dev/null 2>&1 || { echo "ABORT: python3 not found"; exit 2; }
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
ovr() { # ovr <shell> <cwd> <out> <home>: the overrides block of index.md
  (cd "$2" && env HOME="$4" GIT_CEILING_DIRECTORIES="$d" "$1" -c "$OVR") > "$3" 2>&1; }
cmdf() { # cmdf <commands folder> <name> [extra frontmatter lines, printf %b]
  mkdir -p "$1"; printf -- '---\ndescription: %s command.\n%b---\nbody\n' "$2" "${3:-}" > "$1/$2.md"; }
sk() { # sk <skills folder> <folder> [extra frontmatter lines, printf %b]
  mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: %s skill.\n%b---\nbody\n' "$2" "$2" "${3:-}" > "$1/$2/SKILL.md"; }

# The rule as this test reads it. Keys: the path table of index.md, with a
# project row for every folder D from the working folder up to the top folder.
# In the session: a plugin key listed as <plugin>:<name>; a user or project
# key listed by one of its names, or a manual skill (manual_ok of
# tests/frontmatter-name.py: its first block `ok`, `disable-model-invocation:
# true`, never `user-invocable: false`; plugin skills never). Calls: a bare
# name reaches a card when no other card answers to it with a higher
# precedence (personal over project), or, between project cards of different
# folders, from a folder nearer the top; a project card below the top whose
# folder name another card answers to is also reached as /<D relative to the
# top>:<folder>. A card with no call is shadowed.
ELIG_PY='
import os, re, sys
disc = open(sys.argv[1]).read().splitlines(); listed = set(sys.argv[2].split()); root, cwd = sys.argv[3], sys.argv[4]
ov = parse_overrides(open(sys.argv[5]).read()); task = sys.argv[6] if len(sys.argv) > 6 else ""
home = os.environ["HOME"]; cfg = home + "/.claude"
chain = [cwd]
while chain[-1] != root and chain[-1].startswith(root + "/"): chain.append(chain[-1].rsplit("/", 1)[0])
plugins = [l.split(" ", 2)[1:] for l in disc if l.startswith("PLUGIN ")]
def keyof(p):
    for r in chain:
        m = re.fullmatch(re.escape(r) + r"/\.claude/skills/([^/]+)/SKILL\.md", p)
        if m: return ("project:" + r, ename(p, m.group(1)))
    m = re.fullmatch(re.escape(cfg) + r"/skills/([^/]+)/SKILL\.md", p)
    if m: return ("user", ename(p, m.group(1)))
    for r in chain:  # legacy command files (deferred E1 r55), named by their file name
        m = re.fullmatch(re.escape(r) + r"/\.claude/commands/([^/]+)\.md", p)
        if m: return ("project:" + r, m.group(1))
    m = re.fullmatch(re.escape(cfg) + r"/commands/([^/]+)\.md", p)
    if m: return ("user", m.group(1))
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
    if k: keys.add(k + (p.split("/")[-2] if p.endswith("/SKILL.md") else p.rsplit("/", 1)[-1][:-3], p))
inv = lambda k: aliases(k[3], k[2])[0]
pos = lambda k: aliases(k[3], k[2])[1]
rank = lambda k: 1 if k[0] == "user" else 2
depth = lambda k: 0 if k[0] == "project:" + root else len(k[0][8 + len(root):].strip("/").split("/"))
iscmd = lambda k: not k[3].endswith("/SKILL.md")
# a command that a personal or project skill answers to gets no card (the skill takes precedence)
sk_bare = [k for k in keys if not k[0].startswith("plugin:") and not iscmd(k)]
keys = set(k for k in keys if not (iscmd(k) and any(k[2] in pos(o) for o in sk_bare)))
bare = [k for k in keys if not k[0].startswith("plugin:")]
def wins(k, o):  # k keeps a bare name that o also answers to
    if rank(k) != rank(o): return rank(k) < rank(o)
    return k[0] != o[0] and k[0].startswith("project:") and depth(k) < depth(o)
out = []
for k in sorted(keys):
    s, n = k[0], k[1]
    if s.startswith("plugin:"):
        if s[7:] + ":" + n in listed: out.append("ELIGIBLE %s/%s CALL /%s:%s" % (s, n, s[7:], n))
        continue
    man = manual_ok(k[3], k[2], ov)
    calls = sorted("/" + x for x in inv(k) if all(wins(k, o) for o in bare if o != k and x in pos(o) and not (iscmd(o) and not iscmd(k))))
    if not iscmd(k) and s.startswith("project:") and depth(k) > 0 and any(k[2] in pos(o) for o in bare if o != k):
        calls.append("/%s:%s" % (s[9 + len(root):], k[2]))
    if not (inv(k) & listed or set(c[1:] for c in calls) & listed or man): continue
    out.append(("ELIGIBLE %s/%s %sCALL " % (s, n, "MANUAL " if man else "") + " ".join(calls)) if calls else "SHADOWED %s/%s" % (s, n))
out = sorted(out)
# Round 54: the top recommendation for a one-word task is the eligible card
# whose name is that word, manual or not.
top = [l for l in out if l.startswith("ELIGIBLE ") and l.split()[1].rsplit("/", 1)[1] == task]
if task: out.append("RECOMMEND " + (top[0][len("ELIGIBLE "):] if top else "nothing"))
print("\n".join(out))
'
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP   $sh not found"; continue; }
  # A. the chain of project roots
  X="$d/$sh-chain"; H="$X/home"; R="$X/repo"; S="$R/apps/web/src"; mkdir -p "$H/idx" "$S/deep/.claude/skills" "$R/other"
  git init -q "$R" || { bad "$sh: git init"; continue; }
  sk "$R/.claude/skills" deploy; sk "$R/apps/.claude/skills" deploy; sk "$R/apps/.claude/skills" lint
  sk "$S/.claude/skills" fmt; sk "$R/other/.claude/skills" sib; sk "$S/deep/.claude/skills" below
  L="$sh A chain"; r="$(disc "$sh" "$S" "$X/out" "$H")"
  [ "$r" = rc=0 ] && tail -1 "$X/out" | grep -q '^DISCOVERY OK 4$' && ok "$L: DISCOVERY OK 4" || bad "$L: $r $(tail -1 "$X/out")"
  got="$(sed -n 's/^ROOT_DIR //p' "$X/out" | LC_ALL=C sort | tr '\n' ';')"
  want="$(printf '%s\n' "$R/.claude/skills" "$R/apps/.claude/skills" "$S/.claude/skills" | LC_ALL=C sort | tr '\n' ';')"
  [ "$got" = "$want" ] && ok "$L: ROOT_DIR for the working folder, the intermediate folder and the top" || bad "$L: ROOT_DIR '$(sed "s|$X/||g" <<< "$got")'"
  for f in "$R/.claude/skills/deploy" "$R/apps/.claude/skills/deploy" "$R/apps/.claude/skills/lint" "$S/.claude/skills/fmt"; do
    grep -qxF "NOCARD $(cksum "$f/SKILL.md")" "$X/out" && ok "$L: located ${f#$X/}" || bad "$L: not located ${f#$X/}"
  done
  ! grep -qE '/(sib|below)/SKILL\.md' "$X/out" && ok "$L: a sibling folder and a folder below the working folder are not searched" || bad "$L: searched outside the chain"
  # outside a git repository: only the working folder
  N="$X/plain/a/b"; mkdir -p "$N"; sk "$X/plain/.claude/skills" up; sk "$N/.claude/skills" here
  L="$sh A no git"; r="$(disc "$sh" "$N" "$X/out2" "$H")"
  [ "$r" = rc=0 ] && grep -q '/here/SKILL.md$' "$X/out2" && ! grep -q '/up/SKILL.md$' "$X/out2" && ok "$L: only the working folder" || bad "$L: $r $(grep -E 'ROOT_DIR|NOCARD' "$X/out2" | sed "s|$X/||g" | tr '\n' ';')"
  # B. eligibility
  for id in chain manual-user manual-uncertain manual-noinvoke manual-plugin manual-shadow \
      ov-local-off ov-user-off ov-folder-off ov-broken ov-unreadable ov-badtype ov-invalid ov-uio ov-uio-only ov-name-only ov-on ov-top \
      cmd-manual cmd-plain cmd-off cmd-skill-wins cmd-clash cmd-top cmd-fmname; do
    Y="$d/$sh-elig-$id"; H="$Y/home"; R="$Y/repo"; S="$R/apps/web/src"; mkdir -p "$H/idx" "$S"
    git init -q "$R"; sk "$R/.claude/skills" deploy; sk "$R/apps/.claude/skills" deploy; sk "$R/apps/.claude/skills" lint
    LIST="deploy lint apps:deploy"; TASK=""
    want="ELIGIBLE project:$R/apps/deploy CALL /apps:deploy
ELIGIBLE project:$R/apps/lint CALL /lint
ELIGIBLE project:$R/deploy CALL /deploy"
    case "$id" in
      manual-user) sk "$H/.claude/skills" ship 'disable-model-invocation: true\n'
        want="$want
ELIGIBLE user/ship MANUAL CALL /ship";;
      manual-uncertain) sk "$H/.claude/skills" ship 'disable-model-invocation: true\nargument-hint: [unclosed\n';;
      manual-noinvoke) sk "$H/.claude/skills" ship 'disable-model-invocation: true\nuser-invocable: false\n';;
      manual-plugin) c="$H/.claude/plugins/cache/mkt/pl/1.0.0"; mkdir -p "$c/.claude-plugin"; printf '{"name": "pl"}\n' > "$c/.claude-plugin/plugin.json"
        sk "$c/skills" ship 'disable-model-invocation: true\n'
        printf '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' "$c" > "$H/.claude/plugins/installed_plugins.json";;
      manual-shadow) sk "$H/.claude/skills" deploy 'disable-model-invocation: true\n'
        want="ELIGIBLE project:$R/apps/deploy CALL /apps:deploy
ELIGIBLE project:$R/apps/lint CALL /lint
ELIGIBLE user/deploy MANUAL CALL /deploy
SHADOWED project:$R/deploy";;
      cmd-manual) cmdf "$H/.claude/commands" ship 'disable-model-invocation: true\n'
        want="$want
ELIGIBLE user/ship MANUAL CALL /ship";;
      cmd-fmname) cmdf "$H/.claude/commands" ship 'name: release\ndisable-model-invocation: true\n'; cmdf "$R/.claude/commands" release 'disable-model-invocation: true\n'
        want="ELIGIBLE project:$R/apps/deploy CALL /apps:deploy
ELIGIBLE project:$R/apps/lint CALL /lint
ELIGIBLE project:$R/deploy CALL /deploy
ELIGIBLE project:$R/release MANUAL CALL /release
ELIGIBLE user/ship MANUAL CALL /ship";;
      cmd-plain) cmdf "$H/.claude/commands" ship;;
      cmd-off) cmdf "$H/.claude/commands" ship 'disable-model-invocation: true\n'; mkdir -p "$R/.claude"
        printf '{"skillOverrides": {"ship": "off"}}\n' > "$R/.claude/settings.json";;
      cmd-skill-wins) cmdf "$R/.claude/commands" lint 'disable-model-invocation: true\n'; cmdf "$H/.claude/commands" deploy 'disable-model-invocation: true\n';;
      cmd-clash) cmdf "$R/apps/.claude/commands" rel 'disable-model-invocation: true\n'; cmdf "$H/.claude/commands" rel 'disable-model-invocation: true\n'
        want="$want
ELIGIBLE user/rel MANUAL CALL /rel
SHADOWED project:$R/apps/rel";;
      cmd-top) cmdf "$R/apps/.claude/commands" ship 'disable-model-invocation: true\n'; TASK=ship
        want="ELIGIBLE project:$R/apps/deploy CALL /apps:deploy
ELIGIBLE project:$R/apps/lint CALL /lint
ELIGIBLE project:$R/apps/ship MANUAL CALL /ship
ELIGIBLE project:$R/deploy CALL /deploy
RECOMMEND project:$R/apps/ship MANUAL CALL /ship";;
      ov-*) MAN="ELIGIBLE user/ship MANUAL CALL /ship"; flag='disable-model-invocation: true\n'
        case "$id" in ov-uio-only) flag='';; esac
        sk "$H/.claude/skills" ship "$flag"; mkdir -p "$H/.claude" "$R/.claude" "$S/.claude"
        case "$id" in
          ov-local-off) printf '{"skillOverrides": {"ship": "off"}}\n' > "$R/.claude/settings.local.json"; MAN="";;
          ov-user-off) printf '{"model": "x", "skillOverrides": {"ship": "off"}}\n' > "$H/.claude/settings.json"; MAN="";;
          ov-folder-off) printf -- '---\nname: release\ndescription: x.\n%b---\n' "$flag" > "$H/.claude/skills/ship/SKILL.md"
            printf '{"skillOverrides": {"ship": "off"}}\n' > "$S/.claude/settings.json"; MAN="";;
          ov-broken) printf '{"skillOverrides": {"other": "off"},}\n' > "$S/.claude/settings.json"; MAN="";;
          ov-unreadable) printf '{}\n' > "$R/.claude/settings.local.json"; chmod 000 "$R/.claude/settings.local.json"; MAN="";;
          ov-badtype) printf '{"skillOverrides": ["ship"]}\n' > "$H/.claude/settings.json"; MAN="";;
          ov-invalid) printf '{"skillOverrides": {"ship": "hidden"}}\n' > "$R/.claude/settings.json"; MAN="";;
          ov-uio|ov-uio-only) printf '{"skillOverrides": {"ship": "user-invocable-only"}}\n' > "$R/.claude/settings.local.json";;
          ov-name-only) printf '{"skillOverrides": {"ship": "name-only"}}\n' > "$H/.claude/settings.json";;
          ov-on) printf '{"skillOverrides": {"ship": "on", "deploy": "off"}}\n' > "$H/.claude/settings.json";;
          ov-top) TASK=ship;;
        esac
        [ -n "$MAN" ] && want="$want
$MAN"
        [ -n "$TASK" ] && want="$want
RECOMMEND user/ship MANUAL CALL /ship";;
    esac
    L="$sh B $id"; r="$(disc "$sh" "$S" "$Y/out" "$H")"
    [ "$r" = rc=0 ] && tail -1 "$Y/out" | grep -q '^DISCOVERY OK' && ok "$L: DISCOVERY OK" || { bad "$L: $r $(tail -1 "$Y/out")"; continue; }
    ovr "$sh" "$S" "$Y/ovr" "$H"
    case "$id" in ov-broken|ov-unreadable|ov-badtype) tail -1 "$Y/ovr" | grep -q '^OVERRIDES FAILED' && ok "$L: OVERRIDES FAILED" || bad "$L: overrides block: $(tail -1 "$Y/ovr")";;
      *) tail -1 "$Y/ovr" | grep -qx 'OVERRIDES OK' && ok "$L: OVERRIDES OK" || bad "$L: overrides block: $(tail -1 "$Y/ovr")";; esac
    got="$(HOME="$H" python3 -I -c "$(cat "$HERE/frontmatter-name.py")
$ELIG_PY" "$Y/out" "$LIST" "$R" "$S" "$Y/ovr" "$TASK" 2>&1)"
    [ "$id" = ov-unreadable ] && chmod 600 "$R/.claude/settings.local.json"
    [ "$got" = "$want" ] && ok "$L: $(tr '\n' ';' <<< "$got" | sed "s|$R|<repo>|g")" || bad "$L: got '$(tr '\n' ';' <<< "$got" | sed "s|$R|<repo>|g")', expected '$(tr '\n' ';' <<< "$want" | sed "s|$R|<repo>|g")'"
  done
done
# C. text consistency
TWO='`project:<ROOT>` or `project:<CWD>`'
for fl in "$DOC" "$SAA" "$SK"; do ! grep -qF "$TWO" "$fl" && ok "${fl##*/}: no rule limited to the two folders ROOT and CWD" || bad "${fl##*/}: still names only $TWO"; done
grep -qF 'every folder from the working directory up to' "$DOC" && grep -qF 'every folder from the working directory up to' "$SK" && ok "index.md and SKILL.md: project roots from the working directory up to the top folder" || bad "the chain of project roots is not stated"
grep -q 'root s "\$CWD/.claude/skills"; root s "\$ROOT/.claude/skills"' "$DOC" && bad "index.md discovery still searches only CWD and ROOT" || ok "index.md discovery walks the chain"
grep -qF '<D relative to the top folder>:<folder name>' "$DOC" && grep -qF '<D relative to the top folder>:<folder name>' "$SAA" && ok "index.md and search-and-answer.md: /<D relative to the top folder>:<folder name>" || bad "the qualified nested name is not stated"
[ "$(grep -c '^- \*\*Manual skills\*\*' "$DOC")" = 1 ] && M="$(grep '^- \*\*Manual skills\*\*' "$DOC")" && grep -qF 'disable-model-invocation: true' <<< "$M" && grep -qF '`ok`' <<< "$M" && grep -qF 'plugin' <<< "$M" && grep -qF 'claude.ai' <<< "$M" && ok "index.md defines Manual skills once (ok block, the flag, plugin and claude.ai left out)" || bad "index.md lacks a single Manual skills definition"
for fl in "$DOC" "$SAA" "$SK"; do grep -qF 'invocation: manual' "$fl" && ok "${fl##*/}: invocation: manual" || bad "${fl##*/} lacks invocation: manual"; done
for fl in "$SAA" "$SK"; do grep -qF 'only you can start it' "$fl" && ok "${fl##*/}: a manual skill is presented as one only the user can start" || bad "${fl##*/} lacks 'only you can start it'"; done
grep -qF 'manual skill' <<< "$(grep -F 'not installed' "$DOC")" && ok "index.md: the not-installed rule names manual skills" || bad "index.md: the not-installed rule ignores manual skills"
# D. round 54 text: no sentence that keeps unlisted skills out (never
# recommended, only skills in the list) omits the manual exception.
for fl in "$DOC" "$SAA" "$SK"; do
  h="$(python3 -I - "$fl" <<'PYEOF'
import re, sys
for i, l in enumerate(open(sys.argv[1]), 1):
    for s in re.split(r"(?<=[.;:])\s+", l):
        if re.search(r"(does not list|not in the session|skill list|session list|session lists it|lacks the skill|leaves the session)", s) \
           and re.search(r"\b(never|only)\b", s) and "manual" not in s.lower():
            print("%d: %s" % (i, s.strip()[:140]))
PYEOF
)"
  [ -z "$h" ] && ok "${fl##*/}: every rule that excludes unlisted skills names the manual exception" || bad "${fl##*/}: categorical exclusion without the manual exception: $(tr '\n' ';' <<< "$h")"
done
grep -qF 'skillOverrides' "$DOC" && grep -qF 'skillOverrides' "$SAA" && grep -qF 'skillOverrides' "$SK" && ok "the three files name skillOverrides" || bad "skillOverrides is missing in a file"
M="$(grep '^- \*\*Manual skills\*\*' "$DOC")"; grep -qF '"off"' <<< "$M" && grep -qF 'user-invocable-only' <<< "$M" && grep -qF 'OVERRIDES OK' <<< "$M" && ok "index.md: Manual skills names off, user-invocable-only and OVERRIDES OK" || bad "index.md: Manual skills lacks the override rule"
if [ "$BAD" -eq 0 ]; then echo "TEST MANUAL-NESTED OK"; exit 0; else echo "TEST MANUAL-NESTED FAILED ($BAD)"; exit 1; fi
