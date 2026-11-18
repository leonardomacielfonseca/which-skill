# Sourced by test-active-copy.sh and test-shortlist-copy.sh (round 32).
# r32fix <case> <folder>: a config folder <folder>/cfg (safe, CLAUDE_CONFIG_DIR)
# whose cache holds an unlisted leftover qq@mkt/1.0 (manifest qq, skill rq;
# the card plugin:qq/rq points at it), a seed plugin <folder>/seed/ss, and one
# CLAUDE_CODE_PLUGIN_DIRS entry R32_DIRS that is refused:
#   tilde      HOME is "<folder>/P (l)" (unsafe) and the entry is "~/pl" (a
#              plugin whose manifest is named qq): the text "~/pl" looks safe,
#              the expanded root is UNSAFE-ROOT
#   rejected   a safe entry <folder>/ext/pl whose manifest links outside the
#              skill folders (its real name, qq, cannot be read)
#   noname     a safe entry <folder>/ext/pl whose manifest has no usable name
#   unsafepath a safe entry <folder>/ext/pl holding a nested plugin folder
#              "q;q" (its manifest is an UNSAFE-PATH, so its name is unknown)
# Every case requires the refused NOTE, AMBIGUOUS-ACTIVE qq@mkt, no ACTIVE or
# NOCARD for the leftover, the seed copy STALE-COPY and, at shortlist, unverified.
R32_CASES='tilde rejected noname unsafepath'
r32pl() { mkdir -p "$1/.claude-plugin" "$1/skills/$3"; printf '{"name": "%s"}\n' "$2" > "$1/.claude-plugin/plugin.json"
  printf -- '---\nname: %s\ndescription: x.\n---\nbody of %s\n' "$3" "$1" > "$1/skills/$3/SKILL.md"; }
r32fix() {
  local id="$1" X="$2" PL="$2/cfg/plugins" f
  mkdir -p "$X/A" "$X/idx" "$X/ext" "$PL"; R32_HOME="$X/home"; mkdir -p "$R32_HOME"
  r32pl "$PL/cache/mkt/qq/1.0" qq rq; r32pl "$X/seed/ss" ss rs; f="$PL/cache/mkt/qq/1.0/skills/rq/SKILL.md"
  printf '%s\n\n## plugin:qq/rq\n\n```yaml\nname: rq\nsource: plugin:qq\npath: %s\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** x.\n**Use when:** x.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** x\n**Examples:**\n- "a"\n- "b"\n' \
    '<!-- which-skill index v1 · updated 2026-11-16 -->' "$f" "$(cksum < "$f" | cut -d' ' -f1-2)" > "$X/idx/index.md"
  printf '{"version": 2, "plugins": {"zz@mkt": [{"scope": "user", "installPath": "/nowhere/zz"}]}}\n' > "$PL/installed_plugins.json"
  case "$id" in
    tilde) R32_HOME="$X/P (l)"; r32pl "$R32_HOME/pl" qq rq; R32_DIRS="~/pl";;
    rejected) r32pl "$X/ext/pl" qq rq; printf '{"name": "qq"}\n' > "$X/secret.json"; rm "$X/ext/pl/.claude-plugin/plugin.json"
      ln -s "$X/secret.json" "$X/ext/pl/.claude-plugin/plugin.json"; R32_DIRS="$X/ext/pl";;
    unsafepath) r32pl "$X/ext/pl/q;q" qq rq; R32_DIRS="$X/ext/pl";;
    noname) r32pl "$X/ext/pl" qq rq; printf '{"version": "1"}\n' > "$X/ext/pl/.claude-plugin/plugin.json"; R32_DIRS="$X/ext/pl";;
  esac
}
# r32disc <shell> <folder> <out>: discovery with that fixture's variables
r32disc() { (cd "$2/A" && exec env HOME="$R32_HOME" CLAUDE_CONFIG_DIR="$2/cfg" WHICH_SKILL_INDEX="$2/idx/index.md" \
  CLAUDE_CODE_PLUGIN_DIRS="$R32_DIRS" CLAUDE_CODE_PLUGIN_SEED_DIR="$2/seed" "$1" -c "$DISC") > "$3" 2>&1; echo "rc=$?"; }
# r32check <case> <folder> <out>: prints the failures (nothing when all pass)
r32check() {
  local o="$3"
  grep -q '^NOTE a CLAUDE_CODE_PLUGIN_DIRS entry was refused' "$o" || echo "no refused NOTE"
  grep -qx 'AMBIGUOUS-ACTIVE qq@mkt' "$o" || echo "qq@mkt not AMBIGUOUS-ACTIVE"
  ! grep -q '^ACTIVE qq@mkt ' "$o" || echo "residual ACTIVE qq@mkt"
  ! grep -q '^NOCARD .*/cache/mkt/qq/' "$o" || echo "residual NOCARD for the leftover"
  grep -qxF "STALE-COPY $2/seed/ss/skills/rs/SKILL.md" "$o" || echo "the seed copy is still located"
  if grep -qx ROOTS-INCOMPLETE "$o"; then grep -q '^UNKNOWN plugin:qq/rq ' "$o" && ! grep -q '^GONE ' "$o" || echo "the card is not UNKNOWN (a root was refused)"; else grep -q '^GONE plugin:qq/rq ' "$o" || echo "the card is not GONE"; fi
  [ "$1" != tilde ] || grep -q '^UNSAFE-ROOT .*/P ?l?/pl$' "$o" || echo "no UNSAFE-ROOT for the expanded entry"
}
