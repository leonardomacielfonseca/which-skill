# Sourced (after r32-fixture.sh) by test-active-copy.sh and test-shortlist-copy.sh
# (round 33). r33fix <case> <folder> builds the r32 "noname" fixture (a refused
# plugin dir entry, an unlisted leftover qq@mkt/1.0 that the card points at,
# a seed plugin), then:
#   link-root  <plugins>/cache is a symlink to the real cache folder
#   link-mkt   <plugins>/cache/mkt is a symlink
#   link-key   <plugins>/cache/mkt/qq is a symlink
# Expected as in r32check: the NOTE, AMBIGUOUS-ACTIVE qq@mkt, no ACTIVE or
# NOCARD for the leftover, the seed STALE-COPY, the card GONE, unverified.
# The invariant cases use no plugin dir entry (R32_DIRS empty) and a discovery
# block with the key enumeration artificially skipped:
#   skip-cache   every cached key is dropped before the walk (IP emptied):
#                the leftover must print UNKEYED, not NOCARD
#   skip-synced  every synced key is dropped: a synced plugin's file is UNKEYED
#   seed-nokey   a seed skill under no manifest (nothing to key it): UNKEYED
R33_LINK='link-root link-mkt link-key'
R33_INV='skip-cache skip-synced seed-nokey'
r33fix() {
  local id="$1" X="$2" PL="$2/cfg/plugins"
  r32fix noname "$X"
  case "$id" in
    link-root) mv "$PL/cache" "$X/real-cache"; ln -s "$X/real-cache" "$PL/cache";;
    link-mkt) mv "$PL/cache/mkt" "$X/real-mkt"; ln -s "$X/real-mkt" "$PL/cache/mkt";;
    link-key) mv "$PL/cache/mkt/qq" "$X/real-qq"; ln -s "$X/real-qq" "$PL/cache/mkt/qq";;
    skip-cache) R32_DIRS="";;
    skip-synced) R32_DIRS=""; r32pl "$PL/synced/ID/sb" sb rq;;
    seed-nokey) R32_DIRS=""; mkdir -p "$X/seed/loose/skills/rl"; printf -- '---\nname: rl\ndescription: x.\n---\n' > "$X/seed/loose/skills/rl/SKILL.md";;
  esac
}
# r33script <case>: the discovery block for that case (artificial skips)
r33script() {
  case "$1" in
    skip-cache) printf '%s' "$DISC" | sed 's|^SY="\$PLUG/synced"$|IP=""; SY="$PLUG/synced"|';;
    skip-synced) printf '%s' "$DISC" | sed 's|^stale() {|IP="$(printf "%s\\n" "$IP" \| grep -v " synced/")"; stale() {|';;
    *) printf '%s' "$DISC";;
  esac
}
r33disc() { local sc; sc="$(r33script "$1")"; (cd "$3/A" && exec env HOME="$R32_HOME" CLAUDE_CONFIG_DIR="$3/cfg" WHICH_SKILL_INDEX="$3/idx/index.md" \
  CLAUDE_CODE_PLUGIN_DIRS="$R32_DIRS" CLAUDE_CODE_PLUGIN_SEED_DIR="$3/seed" "$2" -c "$sc") > "$4" 2>&1; echo "rc=$?"; }
# r33inv <case> <folder> <out>: prints the failures of an invariant case
r33inv() {
  local o="$3" f
  case "$1" in
    skip-cache) f="$2/cfg/plugins/cache/mkt/qq/1.0/skills/rq/SKILL.md"
      if grep -qx ROOTS-INCOMPLETE "$o"; then grep -q '^UNKNOWN plugin:qq/rq ' "$o" && ! grep -q '^GONE ' "$o" || echo "the card is not UNKNOWN (a root was refused)"; else grep -q '^GONE plugin:qq/rq ' "$o" || echo "the card is not GONE"; fi;;
    skip-synced) f="$2/cfg/plugins/synced/ID/sb/skills/rq/SKILL.md";;
    seed-nokey) f="$2/seed/loose/skills/rl/SKILL.md";;
  esac
  grep -qxF "UNKEYED $f" "$o" || echo "no UNKEYED line for ${f#$2/}"
  ! grep -qF " $f" <<< "$(grep '^NOCARD ' "$o")" || echo "residual NOCARD for ${f#$2/}"
}
