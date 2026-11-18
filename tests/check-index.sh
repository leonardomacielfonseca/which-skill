#!/usr/bin/env bash
# Checks an index file: header, card count, duplicate headings, every card has
# every field, and every heading equals "## <source>/<name>" (project sources
# are "project:<absolute root>"; legacy "## project/<name>" keys are noted),
# and no unverified (or legacy built-in) card stays next to an installed
# verified card of the same session skill. Exit 0 only when everything passes.
#   tests/check-index.sh [--located] [index-path [project-folder...]]   (default: the lab index)
# --located also checks, on disk, that every installed verified card in the
# session view (user, claude.ai and plugin cards, and project cards of the
# folders given) points to a regular file at a safe path (`~` is $HOME): a
# verified card is authoritative only while its file is located, regular and
# safe, and, when its path involves a symlink, whose canonical target passes
# the outside-root rule of index.md, and is not under a plugin folder whose
# manifest is rejected (not a regular file, or fails that rule); otherwise it should have been downgraded
# to an unverified card. --located also runs the discovery block of
# index.md itself (from the first project folder given, else the current
# folder; shell $CHECK_SH, default bash; the same environment, with
# WHICH_SKILL_INDEX set to the index checked), requires DISCOVERY OK, and
# requires that each such card is located in that run as index.md defines it:
# exactly one located file maps to its key, and it is the card's own path on a
# LOCATED line of that key. A card on a regular file that discovery does not
# locate (a STALE-COPY of an older version, for example) fails, even when a
# NOCARD file (the active copy) maps to its key: a refreshed index has the card
# on that file.
# Located files are keyed by the path table of index.md with the effective
# name (the frontmatter `name` of the first frontmatter block, else the folder
# name; a command file by its file name).
# Session identity (the name as the session lists it): an unverified card's
# `name`; `<plugin>:<name>` for a plugin:<plugin> card; `<name>` for a user or
# claude.ai card (a claude.ai card also matches `anthropic-skills:<name>`, the
# one prefix observed for synced skills; any other prefix is another skill);
# `<name>` for a
# project:<folder> card, only when that folder is given (the session's top
# folder and working folder; other folders' cards belong to other sessions).
# Round 53: the first folder given is the working folder; every folder from it
# up to its git top folder is added to the folders given (index.md: project
# skills load from the working folder and every parent up to the top). A card
# may carry `invocation: manual` only on a user or project source, and with
# --located only when its file is a manual skill (manual_ok of
# tests/frontmatter-name.py); a located user or project file that is one needs it.
# Round 54: whether a file is a manual skill also depends on skillOverrides,
# read by the overrides block of index.md (run from the same folder, same
# shell); OVERRIDES FAILED makes no file manual.
LOCATED=0; if [ "${1:-}" = --located ]; then LOCATED=1; shift; fi
ROOTS_ARG="$(shift 2>/dev/null; printf '%s\n' "$@")"
# Round 53: the first folder given is the working folder; every folder from it
# up to its git top folder (physical paths) is a project folder of the view too,
# as in the discovery block of index.md.
F1="$(sed -n 1p <<< "$ROOTS_ARG")"
if [ -n "$F1" ] && [ -d "$F1" ]; then
  CH="$(cd "$F1" && WC_="$(pwd -P)" && WR_="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" && python3 -I -c 'import sys
c, r = sys.argv[1], sys.argv[2]; o = [c]
while o[-1] != r and o[-1].startswith(r + "/"): o.append(o[-1].rsplit("/", 1)[0])
print("\n".join(o[1:]))' "$WC_" "$WR_")"
  [ -z "$CH" ] || ROOTS_ARG="$ROOTS_ARG
$CH"
fi
if [ -n "${1:-}" ]; then INDEX="$1"; else
  BASE="${TMPDIR:-/tmp}"; BASE="$(cd -P "$BASE" 2>/dev/null && pwd -P)" || { echo "FAIL: temp folder ${TMPDIR:-/tmp} not found"; exit 1; }
  INDEX="${BASE%/}/which-skill-lab-$(id -u)/index.md"
fi
[ -f "$INDEX" ] || { echo "FAIL: no index at $INDEX"; exit 1; }
FAILS=0; TAB="$(printf '\t')"
umask 077; OUT_TMP="$(mktemp)" || { echo "FAIL: mktemp"; exit 1; }; trap 'rm -f "$OUT_TMP"' EXIT
if head -1 "$INDEX" | grep -qE '^<!-- which-skill index v1 · updated [0-9]{4}-[0-9]{2}-[0-9]{2} -->$'; then
  echo "ok:   header"
else
  echo "FAIL: header line"; FAILS=$((FAILS+1))
fi
echo "cards: $(grep -c '^## ' "$INDEX")"
DUPS=$(grep '^## ' "$INDEX" | sort | uniq -d)
if [ -z "$DUPS" ]; then echo "ok:   no duplicate card headings"; else
  echo "FAIL: duplicate card headings:"; echo "$DUPS"; FAILS=$((FAILS+1))
fi
WS_ROOTS="$ROOTS_ARG" awk '
BEGIN { nr = split(ENVIRON["WS_ROOTS"], ra, "\n"); for (i = 1; i <= nr; i++) if (ra[i] != "") roots[ra[i]] = 1 }
function check() {
  if (key == "") return
  miss = ""
  if (body !~ /\nname: /) miss = miss " name"
  if (body !~ /\nsource: /) miss = miss " source"
  if (body !~ /\npath: /) miss = miss " path"
  if (body !~ /\nfingerprint: ([0-9]+ [0-9]+)\n/) miss = miss " fingerprint"
  if (body !~ /\nstatus: (installed|not installed)\n/) miss = miss " status"
  if (body !~ /```yaml\n/) miss = miss " yaml-open"
  if (gsub(/\n```/, "&", body) < 2) miss = miss " fence-close"
  if (index(body, "**What it does:**") == 0) miss = miss " what"
  if (index(body, "**Use when:**") == 0) miss = miss " use"
  if (index(body, "**Don'"'"'t use when:**") == 0) miss = miss " dont"
  if (index(body, "**Depends on:**") == 0) miss = miss " depends"
  if (index(body, "**Keywords:**") == 0) miss = miss " keywords"
  if (index(body, "**Examples:**") == 0) miss = miss " examples"
  ex = body; sub(/.*\*\*Examples:\*\*/, "", ex); ne = gsub(/\n- /, "", ex)
  if (ne < 2 || ne > 3) miss = miss " examples-count(" ne ")"
  # The key: "## <source>/<name>", built from the two fields. A project
  # source is "project:<absolute root>". A legacy "## project/<name>" card
  # (source: project) is reported, not failed: it may belong to a project
  # that no session has refreshed since the key changed.
  nm = body; if (sub(/.*\nname: /, "", nm)) sub(/\n.*/, "", nm); else nm = ""
  sr = body; if (sub(/.*\nsource: /, "", sr)) sub(/\n.*/, "", sr); else sr = ""
  if (nm != "" && sr != "") {
    if (key != "## " sr "/" nm) miss = miss " key-mismatch(source=" sr " name=" nm ")"
    if (sr == "project") { legacy++; print "note: legacy key " key }
    else if (sr ~ /^project/ && sr !~ /^project:\/./) miss = miss " project-source-not-absolute"
    else if (sr !~ /^(project:\/.+|user|claude\.ai|unverified|built-in|plugin:[^\/]+)$/) miss = miss " bad-source(" sr ")"
    if (nm ~ /\//) miss = miss " slash-in-name"
  }
  # Round 53: the optional field `invocation: manual` (a manual skill, see
  # index.md) is valid only on a user or project card.
  iv = body; if (sub(/.*\ninvocation: /, "", iv)) { sub(/\n.*/, "", iv)
    if (iv != "manual") miss = miss " invocation(" iv ")"
    else if (sr != "user" && sr !~ /^project:\//) miss = miss " invocation-on-" sr } else iv = ""
  if (miss != "") { bad++; print "FAIL card " key ":" miss }
  st = body; if (sub(/.*\nstatus: /, "", st)) sub(/\n.*/, "", st); else st = ""
  if (nm != "" && sr != "") {
    pa = body; if (sub(/.*\npath: /, "", pa)) sub(/\n.*/, "", pa); else pa = ""
    nc++; ck[nc] = key; cs[nc] = sr; cn[nc] = nm; ct[nc] = st; cp[nc] = pa; ci[nc] = iv
  }
}
/^## / { check(); key = $0; body = "\n"; next }
{ if (key != "") body = body $0 "\n" }
END { check()
  # verified identities of installed cards
  for (i = 1; i <= nc; i++) {
    if (ct[i] != "installed") continue
    if (cs[i] ~ /^plugin:/) id[substr(cs[i], 8) ":" cn[i]] = ck[i]
    else if (cs[i] == "user") id[cn[i]] = ck[i]
    else if (cs[i] == "claude.ai") { id[cn[i]] = ck[i]; ca[cn[i]] = ck[i] }
    else if (cs[i] ~ /^project:/ && (substr(cs[i], 9) in roots)) id[cn[i]] = ck[i]
  }
  for (i = 1; i <= nc; i++) {
    if (cs[i] != "unverified" && cs[i] != "built-in") continue
    other = ""
    if (cn[i] in id) other = id[cn[i]]
    else if (index(cn[i], "anthropic-skills:") == 1 && substr(cn[i], 18) in ca) other = ca[substr(cn[i], 18)]
    if (other != "") { bad++; print "FAIL card " ck[i] ": the same session skill also has the installed verified card " other " (one session skill, one card: keep the verified card only while its file is located, regular and safe, else the unverified card)" }
  }
  # --located: installed verified cards in the session view, for the file test below
  for (i = 1; i <= nc; i++) {
    if (ct[i] != "installed" || cs[i] == "unverified" || cs[i] == "built-in" || cs[i] == "project") continue
    if (cs[i] ~ /^project:/ && !(substr(cs[i], 9) in roots)) continue
    print "LOCATE\t" ck[i] "\t" cp[i] "\t" ci[i]
  }
  if (legacy) print "legacy project keys: " legacy; if (bad) { print bad " card(s) incomplete or mis-keyed"; exit 1 } else print "ok:   every card has all fields and a consistent key" }
' "$INDEX" > "$OUT_TMP"; RC=$?
grep -v "^LOCATE$TAB" "$OUT_TMP"; [ "$RC" -eq 0 ] || FAILS=$((FAILS+1))
# The rule of index.md for a located file whose path involves a symlink: its
# canonical target must lie inside a canonical discovery root, or be named
# SKILL.md (a command: *.md; a manifest: plugin.json) in a folder named like
# the located file's folder. Roots: <config>/skills, <plugins>/cache,
# <plugins>/synced, the plugin folder variables, <folder>/.claude/skills.
INSIDE_PY='import os, sys
cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ["HOME"], ".claude")
plug = os.environ.get("CLAUDE_CODE_PLUGIN_CACHE_DIR") or os.path.join(cfg, "plugins")
roots = [os.path.join(cfg, "skills"), os.path.join(plug, "cache"), os.path.join(plug, "synced")]
for v in ("CLAUDE_CODE_PLUGIN_DIRS", "CLAUDE_CODE_PLUGIN_SEED_DIR"):
    roots += [os.path.expanduser(e) for e in os.environ.get(v, "").split(":") if e.startswith(("/", "~"))]
roots += [os.path.join(r, ".claude", t) for r in os.environ.get("WS_ROOTS", "").split("\n") if r for t in ("skills", "commands")]
roots += [os.path.join(cfg, "commands")]
croots = [os.path.realpath(r) for r in roots if os.path.isdir(r)]
def ok(f, kind):
    c = os.path.realpath(f)
    if c == f: return True
    b = os.path.basename(c)  # Codex adiados r10: the expected name first, also inside a root
    if not (b == "plugin.json" if kind == "M" else b == "SKILL.md" if (f.endswith("/SKILL.md") and (f.endswith("/skills/commands/SKILL.md") or not f.endswith("/commands/SKILL.md"))) else (b.endswith(".md") and os.path.basename(os.path.dirname(c)) == "commands")): return False
    if any(c.startswith(r + "/") for r in croots): return True
    if kind != "M" and (not f.endswith("/SKILL.md") or (f.endswith("/commands/SKILL.md") and not f.endswith("/skills/commands/SKILL.md"))): return False  # Codex adiados r13/r15: a command stays inside a root
    return os.path.basename(os.path.dirname(c)) == os.path.basename(os.path.dirname(f))
f = sys.argv[1]
# a plugin manifest (in any folder above the file) that exists but is not a regular file
# (FIFO, dangling symlink, folder) or points outside rejects the whole plugin folder
d = os.path.dirname(f)
while d not in ("/", ""):
    m = os.path.join(d, ".claude-plugin", "plugin.json")
    if os.path.lexists(m) and not (os.path.isfile(m) and ok(m, "M")): sys.exit(2)
    d = os.path.dirname(d)
sys.exit(0 if ok(f, "F") else 1)'
if [ "$LOCATED" -eq 1 ]; then
  NL=0
  while IFS="$TAB" read -r tag k p iv_; do
    case "$p" in "~/"*) f="$HOME/${p#\~/}";; *) f="$p";; esac
    case "$f" in /*) ;; *) f="";; esac
    case "$f" in *[!A-Za-z0-9._/@+:~\ -]*) f="";; esac
    if [ -z "$f" ] || [ ! -f "$f" ]; then NL=$((NL+1)); echo "FAIL card $k: installed and verified, but its file is not located (not a regular file at a safe path: $p); it should be downgraded to an unverified card"
    else WS_ROOTS="$ROOTS_ARG" python3 -I -c "$INSIDE_PY" "$f"; irc=$?
      if [ "$irc" -eq 1 ]; then NL=$((NL+1)); echo "FAIL card $k: installed and verified, but its file is not located (a symlink whose target is outside the skill folders: $p); it should be downgraded to an unverified card"
      elif [ "$irc" -ne 0 ]; then NL=$((NL+1)); echo "FAIL card $k: installed and verified, but its file is not located (its plugin manifest is rejected: not a regular file, or outside the skill folders: $p); it should be downgraded to an unverified card"; fi; fi
  done < <(grep "^LOCATE$TAB" "$OUT_TMP")
  # The same run's discovery, the documented block, verbatim.
  HERE="$(cd "$(dirname "$0")" && pwd -P)"
  DISC="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"DISCOVERY OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$HERE/../references/index.md")"
  DCWD="$(sed -n 1p <<< "$ROOTS_ARG")"; [ -n "$DCWD" ] || DCWD="$(pwd -P)"
  DOUT="$(cd "$DCWD" 2>/dev/null && WHICH_SKILL_INDEX="$INDEX" "${CHECK_SH:-bash}" -c "$DISC" 2>&1)"; DRC=$?
  if [ -z "$DISC" ] || [ "$DRC" -ne 0 ] || [ "$(tail -1 <<< "$DOUT" | cut -d' ' -f1-2)" != "DISCOVERY OK" ]; then
    NL=$((NL+1)); echo "FAIL: discovery did not end with DISCOVERY OK (rc=$DRC): $(tail -1 <<< "$DOUT")"
  else
    LOC_PY='import os, re, sys
disc = sys.stdin.read().splitlines(); home = os.environ["HOME"]
N = lambda x: re.sub("/+", "/", x).rstrip("/") or "/"
cfg = N(os.environ.get("CLAUDE_CONFIG_DIR") or home + "/.claude")
plug = N(os.environ.get("CLAUDE_CODE_PLUGIN_CACHE_DIR") or cfg + "/plugins")
def ex(e): return N(home + e[1:]) if e == "~" or e.startswith("~/") else (N(e) if e.startswith("/") else None)
xdirs = [x for x in map(ex, os.environ.get("CLAUDE_CODE_PLUGIN_DIRS", "").split(":")) if x]
seeds = [x for x in map(ex, os.environ.get("CLAUDE_CODE_PLUGIN_SEED_DIR", "").split(":")) if x]
# Round 53: a project row for every folder from the working folder up to the top
projs = [N(os.environ["WS_CWD"])]
while projs[-1] != N(os.environ["WS_ROOT"]) and projs[-1].startswith(N(os.environ["WS_ROOT"]) + "/"): projs.append(projs[-1].rsplit("/", 1)[0])
if N(os.environ["WS_ROOT"]) not in projs: projs.append(N(os.environ["WS_ROOT"]))
plugins = [l.split(" ", 2)[1:] for l in disc if l.startswith("PLUGIN ")]
noname = [l[len("PLUGIN_NONAME "):] for l in disc if l.startswith("PLUGIN_NONAME ")]
SK = r"(?:skills/([^/]+)/SKILL\.md|commands/([^/]+)\.md)"
# The effective name of index.md ("Effective name"): ename(path, folder,
# plugin) from tests/frontmatter-name.py, prepended to this program (the YAML
# scalar of the first `name:` line of the first frontmatter block, only when
# Claude Code accepts it, else the folder name; a plugin skill then loses one
# own "<plugin>:" prefix). A command file is named by its file name.
def inplugin(rest):  # <plugin folder>/skills/<name>/SKILL.md or <plugin folder>/commands/<name>.md
    m = re.fullmatch(SK, rest); return (m.group(1), m.group(2)) if m else None
def pkey(plugin, p, sf, cmd):
    return "plugin:%s/%s" % (plugin, ename(p, sf, plugin) if sf else cmd)
# The path table of index.md ("Map each path to a source"), in its order; total:
# a path that matches no row returns None, and the caller FAILs on it.
def keyof(p):
    for r in projs:
        m = re.fullmatch(re.escape(r) + r"/\.claude/skills/([^/]+)/SKILL\.md", p)
        if m: return "project:%s/%s" % (r, ename(p, m.group(1)))
    m = re.fullmatch(re.escape(cfg) + r"/skills/synced/[^/]+/([^/]+)/SKILL\.md", p)
    if m: return "claude.ai/" + ename(p, m.group(1))
    m = re.fullmatch(re.escape(cfg) + r"/skills/([^/]+)/SKILL\.md", p)
    if m: return "user/" + ename(p, m.group(1))
    # legacy command files, one level deep, named by their file name
    for r in projs:
        m = re.fullmatch(re.escape(r) + r"/\.claude/commands/([^/]+)\.md", p)
        if m: return "project:%s/%s" % (r, m.group(1))
    m = re.fullmatch(re.escape(cfg) + r"/commands/([^/]+)\.md", p)
    if m: return "user/" + m.group(1)
    # plugin files: the manifest name of the longest PLUGIN folder, else the folder name of the table
    cov = [(f, n) for n, f in plugins if p.startswith(f + "/")] + [(f, None) for f in noname if p.startswith(f + "/")]
    if cov:
        f, n = max(cov, key=lambda x: len(x[0])); sk = inplugin(p[len(f) + 1:])
        if sk is None: return None
        if n is not None: return pkey(n, p, *sk)
    for base in [plug] + seeds:
        m = re.fullmatch(re.escape(base) + r"/cache/[^/]+/([^/]+)/[^/]+/" + SK, p)
        if m: return pkey(m.group(1), p, m.group(2), m.group(3))
    m = re.fullmatch(re.escape(plug) + r"/synced/[^/]+/([^/]+)/" + SK, p)
    if m:
        return pkey(re.sub(r"~g[^/]*$", "", m.group(1)), p, m.group(2), m.group(3))
    for x in xdirs:
        if p.startswith(x + "/"):
            sk = inplugin(p[len(x) + 1:])
            if sk: return pkey(x.rsplit("/", 1)[-1], p, *sk)
    return None
loc = []
for l in disc:
    if l.startswith("LOCATED "):
        k, f, p = l[len("LOCATED "):].split(" | ", 2); t = "L"
    elif l.startswith("NOCARD "):
        p = l.split(" ", 3)[3]; k = None; t = "N"
    else: continue
    km = keyof(p)
    if km is None:
        print("FAIL located file maps to no source of the path table in index.md: %s" % p); continue
    if t == "L" and km != k:
        print("FAIL card ## %s: its LOCATED file maps to the key %s by the path table: %s" % (k, km, p))
    loc.append((t, km if t == "N" else k, p))
# Codex adiados r2: a legacy command whose name a located personal or project
# skill answers to (its possible invocable names) maps to no key.
sknames = set()
for t, k, p in loc:
    if p.endswith("/SKILL.md") and (k.startswith("user/") or k.startswith("project:")):
        sknames |= aliases(p, p.rsplit("/", 2)[-2])[1]
iscmdp = lambda p: not p.endswith("/SKILL.md") and (re.fullmatch(re.escape(cfg) + r"/commands/[^/]+\.md", p) or any(re.fullmatch(re.escape(r) + r"/\.claude/commands/[^/]+\.md", p) for r in projs))
loc = [x for x in loc if not (iscmdp(x[2]) and x[2].rsplit("/", 1)[-1][:-3] in sknames)]
for line in os.environ["WS_LOC"].splitlines():
    k, p, iv = (line.rstrip("\n").split("\t") + [""])[1:4]; k = k[3:]
    if p.startswith("~/"): p = home + p[1:]
    p = N(p)
    # Round 53: a located user or project file that is a manual skill
    # (manual_ok of tests/frontmatter-name.py) has a card with
    # `invocation: manual`, and only such a card has it.
    if (k.startswith("user/") or k.startswith("project:")) and os.path.isfile(p):
        mk = manual_ok(p, p.rsplit("/", 2)[-2] if p.endswith("/SKILL.md") else p.rsplit("/", 1)[-1][:-3], parse_overrides(os.environ.get("WS_OV", "")))
        if iv == "manual" and not mk:
            print("FAIL card ## %s: marked invocation: manual, but its file is not a manual skill (no plain disable-model-invocation: true in an ok first frontmatter block, or user-invocable is not true): %s" % (k, p))
        elif iv != "manual" and mk:
            print("FAIL card ## %s: its file is a manual skill (disable-model-invocation: true in an ok first frontmatter block), but the card lacks invocation: manual: %s" % (k, p))
    own = [x for x in loc if x[0] == "L" and x[1] == k]
    hits = own + [x for x in loc if x[0] == "N" and x[1] == k]
    if len(hits) == 1 and hits[0][0] == "L" and hits[0][2] == p: continue
    why = "no located file maps to its key" if not hits else ("%d located files map to its key" % len(hits) if len(hits) > 1 else "its only located file is a NOCARD file, not the card path: the card is stale" if hits[0][0] == "N" else "the located file is not the card path")
    print("FAIL card ## %s: installed and verified, but its file is not located in this run (%s; card path %s); discovery prints no LOCATED line for it (a stale copy?), so it should be rebuilt or downgraded" % (k, why, p))'
    WR="$(cd "$DCWD" && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; })"; WC="$(cd "$DCWD" && pwd -P)"
    # Round 54: the overrides block of index.md, run the same way, decides
    # (with the frontmatter) whether a located file is a manual skill.
    OVR="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"OVERRIDES OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$HERE/../references/index.md")"
    OV="$(cd "$DCWD" 2>/dev/null && "${CHECK_SH:-bash}" -c "$OVR" 2>&1)"
    LF="$(WS_OV="$OV" WS_ROOT="$WR" WS_CWD="$WC" WS_LOC="$(grep "^LOCATE$TAB" "$OUT_TMP")" python3 -I -c "$(cat "$HERE/frontmatter-name.py")
$LOC_PY" <<< "$DOUT")"
    if [ -n "$LF" ]; then printf '%s\n' "$LF"; NL=$((NL+$(grep -c '^FAIL' <<< "$LF"))); fi
  fi
  if [ "$NL" -eq 0 ]; then echo "ok:   every installed verified card in view has its file located"; else FAILS=$((FAILS+1)); fi
fi
rm -f "$OUT_TMP"
if [ "$FAILS" -eq 0 ]; then echo "INDEX OK"; exit 0; else echo "$FAILS check(s) failed"; exit 1; fi
