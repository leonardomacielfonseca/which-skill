#!/usr/bin/env bash
# Stateful sandbox test of the "downgraded" transition (no claude run), under
# bash and zsh, with the discovery block extracted verbatim from index.md.
# Each case starts from an index holding a verified, installed card for the
# user skill zz-guard (plus an untouched card for `good`), with zz-guard still
# in the simulated session, and then:
#   fifo      its SKILL.md becomes a FIFO;
#   dangling  its SKILL.md becomes a dangling symlink;
#   unsafe    its folder is renamed to "zz;guard" (unsafe characters);
#   pair      fifo, and the index also holds an older unverified card for it.
# For each case it checks:
#   1. discovery lines: SKIPPED-NONREGULAR or UNSAFE-PATH, GONE for the card,
#      DISCOVERY OK, never a hang (10 s watchdog);
#   2. the plan rules of index.md, encoded below (PLAN_PY), classify the card
#      `downgraded` and replace it in place by one `unverified` card built from
#      the session description, with the specific warning; `good` stays
#      byte-identical; in the pair case the stale verified card is removed and
#      the unverified card kept;
#   3. check-index.sh --located: INDEX OK on the result; it rejects the stale
#      index (verified card without a located file) and an index where the
#      stale verified card stays next to the unverified one;
#   4. a second discovery and plan on the result change nothing (NOFILE line,
#      no GONE line for zz-guard);
#   5. the skill text states the rule (index.md plan, transition and supersede
#      rule; search-and-answer.md ranking; SKILL.md summary).
# Exit 0 = every check as expected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"; DOC="$HERE/../references/index.md"
SAA="$HERE/../references/search-and-answer.md"; SK="$HERE/../SKILL.md"; CHECK="$HERE/check-index.sh"
umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 2; }
case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 2;; esac
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 2; }
d="$(cd -P "$d" && pwd -P)"
PIDS=""; trap 'for p in $PIDS; do kill -9 -- -"$p" 2>/dev/null; done; rm -rf "$d"' EXIT
BAD=0; ok() { echo "ok     $1"; }; bad() { BAD=$((BAD+1)); echo "NOT OK $1"; }
DISC="$(awk '/^```bash$/{b="";f=1;next} f&&/^```$/{f=0; if (index(b,"DISCOVERY OK")) {printf "%s",b; exit}} f{b=b $0 "\n"}' "$DOC")"
[ -n "$DISC" ] || { echo "ABORT: discovery block not found"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ABORT: python3 not found"; exit 2; }
unset CLAUDE_CODE_PLUGIN_CACHE_DIR CLAUDE_CODE_PLUGIN_DIRS CLAUDE_CODE_PLUGIN_SEED_DIR

W_NONREG='Warning: its file is not a regular file; not read.'
W_UNSAFE='Warning: path contains unsafe characters; not read.'
U_NOTE='Unverified: its file could not be read; this card comes from the session description only.'
DESC_G='Guards a demo folder against accidental edits.'
DESC_OK='Formats demo notes.'

# The plan rules of index.md ("Building and updating"), as this test reads
# them, for the cases above. Args: index, discovery output, session list
# (name<TAB>description), project folders (":"-separated), output index.
# Prints one "<CLASS> <key>" line per card in the session view.
PLAN_PY='
import fnmatch, os, re, subprocess, sys
idx, disc_f, sess_f, roots, out = sys.argv[1:6]
home = os.environ["HOME"]
text = open(idx).read()
parts = re.split(r"(?m)^(?=## )", text); pre, blocks = parts[0], parts[1:]
disc = open(disc_f).read().splitlines()
sess = dict(l.split("\t", 1) for l in open(sess_f).read().splitlines() if l)
roots = set(r for r in roots.split(":") if r)
gone = set(l[5:].split(" | ")[0] for l in disc if l.startswith("GONE "))
skipped = set(l[19:] for l in disc if l.startswith("SKIPPED-NONREGULAR "))
unsafe = [l[12:] for l in disc if l.startswith("UNSAFE-PATH ")]
nocard = [l.split(" ", 3)[3] for l in disc if l.startswith("NOCARD ")]
def fld(b, f):
    m = re.search(r"(?m)^%s: (.*)$" % f, b); return m.group(1) if m else ""
def ident(src, nm): return src[7:] + ":" + nm if src.startswith("plugin:") else nm
def in_view(src): return not src.startswith("project") or src[8:] in roots
def verified(src): return src not in ("unverified", "built-in")
def ck(desc):
    return " ".join(subprocess.run(["cksum"], input=desc + "\n", stdout=subprocess.PIPE,
                                   universal_newlines=True).stdout.split()[:2])
def unverified_card(name, warn, tail):
    desc = sess[name]
    what = desc + " " + "Unverified: its file could not be read; this card comes from the session description only."
    if warn: what += " " + warn
    return "\n".join(["## unverified/" + name, "", "```yaml", "name: " + name, "source: unverified",
        "path: none", "fingerprint: " + ck(desc), "status: installed", "```", "",
        "**What it does:** " + what, "**Use when:** " + desc, "**Don\x27t use when:** Not stated.",
        "**Depends on:** Nothing special.", "**Keywords:** " + name, "**Examples:**",
        "- \"Use " + name + "\"", "- \"Run " + name + " on this\""]) + tail
cards = []
for b in blocks:
    cards.append(dict(b=b, key=b.split("\n", 1)[0][3:], src=fld(b, "source"), nm=fld(b, "name"),
                      st=fld(b, "status"), path=fld(b, "path"), fp=fld(b, "fingerprint")))
uv = {}
for i, c in enumerate(cards):
    if not verified(c["src"]): uv[c["nm"]] = i
new = [c["b"] for c in cards]; cls = {}
for i, c in enumerate(cards):
    if not in_view(c["src"]): continue
    tail = "\n\n" if c["b"].endswith("\n\n") else "\n"
    if not verified(c["src"]):
        if c["nm"] in sess and c["fp"] != ck(sess[c["nm"]]): cls[c["key"]] = "CHANGED"
        else: cls.setdefault(c["key"], "UNCHANGED")
        continue
    name = ident(c["src"], c["nm"])
    located = c["key"] not in gone or any(p.endswith("/" + c["nm"] + "/SKILL.md") for p in nocard)
    if c["st"] == "installed" and name in sess and not located:
        p = c["path"]; p = home + p[1:] if p.startswith("~/") else p
        if p in skipped: warn = "Warning: its file is not a regular file; not read."
        elif any(fnmatch.fnmatchcase(c["nm"], os.path.basename(os.path.dirname(u))) for u in unsafe):
            warn = "Warning: path contains unsafe characters; not read."
        else: warn = ""
        cls[c["key"]] = "DOWNGRADED"
        if name in uv:            # supersede rule: the stale verified card goes
            j = uv[name]; new[j] = unverified_card(name, warn, "\n\n" if cards[j]["b"].endswith("\n\n") else "\n")
            new[i] = ""; cls[cards[j]["key"]] = "KEPT"
        else:                     # replaced in place
            new[i] = unverified_card(name, warn, tail)
    else:
        cls[c["key"]] = "UNCHANGED"
open(out, "w").write(pre + "".join(new))
for k in sorted(cls): print(cls[k], k)
'

# disc <shell> <outfile>: discovery in the case sandbox, 10 s watchdog.
disc() {
  local sh="$1" out="$2"
  set -m; (cd "$P" && exec env HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" WHICH_SKILL_INDEX="$I" "$sh" -c "$DISC") > "$out" 2>&1 & local pid=$!; set +m
  PIDS="$PIDS $pid"; local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "rc=TIMEOUT"; return; fi
  wait "$pid"; echo "rc=$?"
}
vcard() { # vcard <name> <description>: a verified user card for the file on disk
  printf '## user/%s\n\n```yaml\nname: %s\nsource: user\npath: ~/.claude/skills/%s/SKILL.md\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** %s\n**Use when:** %s\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** %s, demo\n**Examples:**\n- "Use %s"\n- "Run %s on this"\n' \
    "$1" "$1" "$1" "$(cksum < "$H/.claude/skills/$1/SKILL.md" | cut -d' ' -f1-2)" "$2" "$2" "$1" "$1" "$1"
}
ucard() { # ucard <name> <description>: an older unverified card (pair case)
  printf '## unverified/%s\n\n```yaml\nname: %s\nsource: unverified\npath: none\nfingerprint: 1 2\nstatus: installed\n```\n\n**What it does:** An old description. %s\n**Use when:** Old.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** %s\n**Examples:**\n- "Use %s"\n- "Run %s"\n' \
    "$1" "$1" "$U_NOTE" "$1" "$1" "$1"
}
block_of() { awk -v k="## $2" '$0 == k {f=1; print; next} f && /^## /{exit} f{print}' "$1"; }

for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "SKIP   $sh not found"; continue; }
  for c in fifo dangling unsafe pair; do
    C="$d/$sh-$c"; H="$C/home"; P="$C/proj"; I="$C/idx/index.md"; S="$H/.claude/skills"
    mkdir -p "$S/zz-guard" "$S/good" "$P" "$C/idx"
    printf -- '---\nname: zz-guard\ndescription: %s\n---\nbody\n' "$DESC_G" > "$S/zz-guard/SKILL.md"
    printf -- '---\nname: good\ndescription: %s\n---\nbody\n' "$DESC_OK" > "$S/good/SKILL.md"
    printf 'zz-guard\t%s\ngood\t%s\n' "$DESC_G" "$DESC_OK" > "$C/session.tsv"
    { printf '%s\n\n' '<!-- which-skill index v1 · updated 2026-11-16 -->'; vcard zz-guard "$DESC_G"; echo
      if [ "$c" = pair ]; then ucard zz-guard; echo; fi; vcard good "$DESC_OK"; } > "$I"
    r="$(disc "$sh" "$C/d0")"
    [ "$r" = rc=0 ] && grep -qx "UNCHANGED 2" "$C/d0" && grep -qx "DISCOVERY OK 2" "$C/d0" && ok "$sh $c: start, both cards UNCHANGED" || bad "$sh $c: start $r, $(tail -2 "$C/d0" | tr '\n' ' ')"

    G="$S/zz-guard/SKILL.md"
    case "$c" in
      fifo|pair) rm "$G"; mkfifo "$G";;
      dangling) rm "$G"; ln -s "$C/nowhere/SKILL.md" "$G";;
      unsafe) mv "$S/zz-guard" "$S/zz;guard";;
    esac
    cp "$I" "$C/stale.md"
    r="$(disc "$sh" "$C/d1")"
    [ "$r" = rc=0 ] && grep -qx "DISCOVERY OK 1" "$C/d1" && ok "$sh $c: discovery finished, DISCOVERY OK 1" || bad "$sh $c: discovery $r, $(tail -2 "$C/d1" | tr '\n' ' ')"
    grep -qxF "GONE user/zz-guard | $G | installed" "$C/d1" && ok "$sh $c: GONE line for the verified card" || bad "$sh $c: no GONE line: $(grep '^GONE' "$C/d1")"
    case "$c" in
      unsafe) grep -qxF "UNSAFE-PATH $S/zz?guard/SKILL.md" "$C/d1" && ok "$sh $c: UNSAFE-PATH line" || bad "$sh $c: no UNSAFE-PATH line";;
      *) grep -qxF "SKIPPED-NONREGULAR $G" "$C/d1" && ok "$sh $c: SKIPPED-NONREGULAR line" || bad "$sh $c: no SKIPPED-NONREGULAR line";;
    esac

    plan="$(HOME="$H" python3 -I -c "$PLAN_PY" "$I" "$C/d1" "$C/session.tsv" "$P" "$C/new.md")" || bad "$sh $c: plan encoder failed"
    grep -qx "DOWNGRADED user/zz-guard" <<< "$plan" && ok "$sh $c: plan classifies the card downgraded" || bad "$sh $c: plan: $(tr '\n' ' ' <<< "$plan")"
    heads="$(grep '^## ' "$C/new.md" | tr '\n' '|')"
    [ "$heads" = "## unverified/zz-guard|## user/good|" ] && ok "$sh $c: one unverified card, in place, before good" || bad "$sh $c: headings $heads"
    nb="$(block_of "$C/new.md" unverified/zz-guard)"
    case "$c" in unsafe) w="$W_UNSAFE";; *) w="$W_NONREG";; esac
    grep -qF "**What it does:** $DESC_G $U_NOTE $w" <<< "$nb" && ok "$sh $c: built from the session description, specific warning" || bad "$sh $c: card text: $(grep 'What it does' <<< "$nb")"
    grep -qxF "fingerprint: $(cksum <<'DESC_END' | cut -d' ' -f1-2
Guards a demo folder against accidental edits.
DESC_END
)" <<< "$nb" && ok "$sh $c: description fingerprint" || bad "$sh $c: fingerprint $(grep fingerprint <<< "$nb")"
    [ "$(block_of "$C/new.md" user/good)" = "$(block_of "$C/stale.md" user/good)" ] && ok "$sh $c: good card byte-identical" || bad "$sh $c: good card changed"

    out="$(HOME="$H" bash "$CHECK" --located "$C/new.md" "$P" 2>&1)" && grep -qx "INDEX OK" <<< "$out" && ok "$sh $c: check-index --located: INDEX OK on the result" || bad "$sh $c: check-index on the result: $(grep -v '^ok' <<< "$out" | tr '\n' ' ')"
    out="$(HOME="$H" bash "$CHECK" --located "$C/stale.md" "$P" 2>&1)"
    [ $? -ne 0 ] && grep -q "FAIL card ## user/zz-guard: .*not located" <<< "$out" && ok "$sh $c: check-index rejects the stale verified card" || bad "$sh $c: stale index not rejected: $(tr '\n' ' ' <<< "$out")"
    if [ "$c" = pair ]; then
      out="$(HOME="$H" bash "$CHECK" --located "$C/stale.md" "$P" 2>&1)"
      grep -q "FAIL card ## unverified/zz-guard" <<< "$out" && grep -q "not located" <<< "$out" && ok "$sh $c: check-index rejects the pair, names the verified card stale" || bad "$sh $c: pair: $(tr '\n' ' ' <<< "$out")"
    fi

    cp "$C/new.md" "$I"
    r="$(disc "$sh" "$C/d2")"
    { [ "$r" = rc=0 ] && grep -q "^NOFILE unverified/zz-guard | " "$C/d2" && ! grep -q "^GONE user/zz-guard" "$C/d2" && grep -qx "UNCHANGED 1" "$C/d2"; } && ok "$sh $c: next discovery: NOFILE, no GONE" || bad "$sh $c: next discovery $r: $(grep -E '^(NOFILE|GONE|UNCHANGED)' "$C/d2" | tr '\n' ' ')"
    plan="$(HOME="$H" python3 -I -c "$PLAN_PY" "$I" "$C/d2" "$C/session.tsv" "$P" "$C/new2.md")"
    cmp -s "$I" "$C/new2.md" && ! grep -qv '^UNCHANGED ' <<< "$plan" && ok "$sh $c: second run changes nothing" || bad "$sh $c: second run: $(tr '\n' ' ' <<< "$plan")"
  done
done

# 5. the skill text states the rule
PLAN_TXT="$(awk '/^## Building and updating/{f=1} /^## The lock/{f=0} f' "$DOC")"
DG="$(awk '/^   - \*\*downgraded\*\*/{f=1;print;next} f&&/^   - \*\*/{exit} f{print}' <<< "$PLAN_TXT")"
for want in GONE SKIPPED-NONREGULAR UNSAFE-PATH "in place" "session description" "$W_NONREG" "$W_UNSAFE"; do
  grep -qF -- "$want" <<< "$DG" || { bad "index.md plan has no **downgraded** step naming '$want'"; continue; }
done
[ -n "$DG" ] && ok "index.md: **downgraded** plan step present"
grep -qF "located, regular and safe" <<< "$(awk '/^### Unverified skills/{f=1;next} f&&/^### /{exit} f' "$DOC")" && ok "index.md: supersede rule needs a located, regular and safe file" || bad "index.md: supersede rule does not require a located, regular and safe file"
grep -q "downgraded" <<< "$(awk '/^3\. If nothing is new/' "$DOC")" && ok "index.md: step 3 lists downgraded" || bad "index.md: step 3 does not list downgraded"
grep -qi "stale verified card" "$SAA" && ok "search-and-answer.md: stale verified card rule" || bad "search-and-answer.md: no stale verified card rule"
grep -qi "downgrad" "$SK" && ok "SKILL.md: downgrade in the summary" || bad "SKILL.md: no downgrade in the summary"

if [ "$BAD" -eq 0 ]; then echo "TEST DOWNGRADE OK"; exit 0; else echo "TEST DOWNGRADE FAILED ($BAD)"; exit 1; fi
