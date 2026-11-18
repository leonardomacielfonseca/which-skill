# Sourced by test-active-copy.sh and test-shortlist-copy.sh (round 31).
# r31fix <case> <folder>: a fake home with an unlisted cache leftover pl@mkt/1.0.0
# (manifest pl, skill rep; the card plugin:pl/rep points at it), an unlisted
# qq@mkt/1.0 (manifest qq) and a listed ok@mkt/1.0 (manifest ok). Sets R31_DIRS,
# the CLAUDE_CODE_PLUGIN_DIRS value. Cases:
#   paren   the entry "<folder>/P (l)/pl" has an unsafe ancestor: UNSAFE-ROOT,
#           never searched, but its basename pl is reserved: SUPERSEDED pl@mkt
#           by plugin-dir/pl; qq@mkt is AMBIGUOUS-ACTIVE (an entry was refused)
#   badbase the entry "<folder>/ext/p;l" has an unsafe basename: nothing is
#           reserved, but pl@mkt and qq@mkt are both AMBIGUOUS-ACTIVE
#   safe    the entry "<folder>/ext/e1" (a real plugin pl): ACTIVE plugin-dir/pl,
#           pl@mkt SUPERSEDED, qq@mkt ACTIVE as before, no refused NOTE
# The listed ok@mkt stays ACTIVE in every case.
R31_CASES='paren badbase safe'
r31pl() { mkdir -p "$1/.claude-plugin" "$1/skills/$3"; printf '{"name": "%s"}\n' "$2" > "$1/.claude-plugin/plugin.json"
  printf -- '---\nname: %s\ndescription: x.\n---\nbody of %s\n' "$3" "$1" > "$1/skills/$3/SKILL.md"; }
r31fix() {
  local id="$1" X="$2" PL="$2/home/.claude/plugins" f
  mkdir -p "$X/A" "$X/idx" "$PL"
  r31pl "$PL/cache/mkt/pl/1.0.0" pl rep; r31pl "$PL/cache/mkt/qq/1.0" qq rq; r31pl "$PL/cache/mkt/ok/1.0" ok ro
  f="$PL/cache/mkt/pl/1.0.0/skills/rep/SKILL.md"
  printf '%s\n\n## plugin:pl/rep\n\n```yaml\nname: rep\nsource: plugin:pl\npath: %s\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Reports.\n**Use when:** Reports.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** report\n**Examples:**\n- "a"\n- "b"\n' \
    '<!-- which-skill index v1 · updated 2026-11-16 -->' "$f" "$(cksum < "$f" | cut -d' ' -f1-2)" > "$X/idx/index.md"
  printf '{"version": 2, "plugins": {"ok@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' "$PL/cache/mkt/ok/1.0" > "$PL/installed_plugins.json"
  case "$id" in
    paren) R31_DIRS="$X/P (l)/pl"; r31pl "$R31_DIRS" pl rep;;
    badbase) R31_DIRS="$X/ext/p;l"; r31pl "$R31_DIRS" pl rep;;
    safe) R31_DIRS="$X/ext/e1"; r31pl "$R31_DIRS" pl rep;;
  esac
}
# r31check <case> <out>: prints the failures (nothing when all pass)
r31check() {
  local o="$2" N='NOTE a CLAUDE_CODE_PLUGIN_DIRS entry was refused (unsafe path or folder name): no unlisted cached plugin and no seed copy is trusted'
  grep -q "^ACTIVE ok@mkt " "$o" || echo "the listed ok@mkt is not ACTIVE"
  ! grep -q '^ACTIVE pl@mkt ' "$o" || echo "residual ACTIVE pl@mkt"
  ! grep -q '^NOCARD .*/pl/1.0.0/' "$o" || echo "residual NOCARD for the pl leftover"
  if grep -qx ROOTS-INCOMPLETE "$o"; then grep -q '^UNKNOWN plugin:pl/rep ' "$o" && ! grep -q '^GONE ' "$o" || echo "the card is not UNKNOWN (a root was refused)"; else grep -q '^GONE plugin:pl/rep ' "$o" || echo "the card is not GONE"; fi
  case "$1" in
    paren) grep -q '^UNSAFE-ROOT ' "$o" || echo "no UNSAFE-ROOT"
      grep -qx 'SUPERSEDED pl@mkt by plugin-dir/pl' "$o" || echo "no SUPERSEDED pl@mkt by plugin-dir/pl"
      grep -qx 'AMBIGUOUS-ACTIVE qq@mkt' "$o" || echo "qq@mkt not AMBIGUOUS-ACTIVE"
      grep -qxF "$N" "$o" || echo "no refused NOTE";;
    badbase) grep -qx 'AMBIGUOUS-ACTIVE pl@mkt' "$o" || echo "pl@mkt not AMBIGUOUS-ACTIVE"
      grep -qx 'AMBIGUOUS-ACTIVE qq@mkt' "$o" || echo "qq@mkt not AMBIGUOUS-ACTIVE"
      ! grep -q '^NOCARD .*/qq/' "$o" || echo "residual NOCARD for qq"
      grep -qxF "$N" "$o" || echo "no refused NOTE";;
    safe) grep -q '^ACTIVE plugin-dir/pl ' "$o" || echo "no ACTIVE plugin-dir/pl"
      grep -q '^ACTIVE qq@mkt ' "$o" || echo "qq@mkt is not ACTIVE"
      ! grep -q '^NOTE a CLAUDE_CODE_PLUGIN_DIRS entry was refused' "$o" || echo "refused NOTE printed for a safe entry";;
  esac
}
