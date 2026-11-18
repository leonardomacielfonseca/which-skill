# Sourced by test-active-copy.sh and test-shortlist-copy.sh (round 30).
# r30fix <case> <folder>: a fake home <folder>/home whose listed plugin LK
# (pl@mk2, or pl2@mk2 for rejected-renamed) has an active copy that does not
# end up cleanly ACTIVE, next to a leftover unlisted cache copy pl@mkt/1.0.0
# (manifest `pl`, skill `rep`). The index <folder>/idx/index.md holds the card
# plugin:pl/rep pointing at the leftover, with its fingerprint. Cases:
#   unsafe            LK's install path has a `;` (UNSAFE-ACTIVE pl@mk2)
#   ambiguous         two user records for LK (AMBIGUOUS-ACTIVE pl@mk2)
#   rejected          LK's active manifest links outside the skill folders
#   missing           LK's install path does not exist
#   fifo              LK's active SKILL.md is a FIFO
#   outside           LK's active SKILL.md links outside the skill folders
#   rejected-renamed  pl2@mk2: active copy 2.0 rejected, old copy 1.0 named pl
# Sets R30_LK to the listed key. Expected: SUPERSEDED pl@mkt by $R30_LK, no
# ACTIVE pl@mkt line, no NOCARD, the card GONE, the skill unverified.
R30_CASES='unsafe ambiguous rejected missing fifo outside rejected-renamed'
r30pl() { mkdir -p "$1/.claude-plugin" "$1/skills/rep"; printf '{"name": "pl"}\n' > "$1/.claude-plugin/plugin.json"
  printf -- '---\nname: rep\ndescription: Reports.\n---\nbody of %s\n' "$1" > "$1/skills/rep/SKILL.md"; }
r30rec() { printf '{"scope": "user", "installPath": "%s"}' "$1"; }
r30fix() {
  local id="$1" X="$2" PL="$2/home/.claude/plugins" A B f
  mkdir -p "$X/A" "$X/idx" "$X/ext" "$PL"
  r30pl "$PL/cache/mkt/pl/1.0.0"; f="$PL/cache/mkt/pl/1.0.0/skills/rep/SKILL.md"
  printf '%s\n\n## plugin:pl/rep\n\n```yaml\nname: rep\nsource: plugin:pl\npath: %s\nfingerprint: %s\nstatus: installed\n```\n\n**What it does:** Reports.\n**Use when:** Reports.\n**Don'"'"'t use when:** Not stated.\n**Depends on:** Nothing special.\n**Keywords:** report\n**Examples:**\n- "a"\n- "b"\n' \
    '<!-- which-skill index v1 · updated 2026-11-16 -->' "$f" "$(cksum < "$f" | cut -d' ' -f1-2)" > "$X/idx/index.md"
  R30_LK=pl@mk2; A="$PL/cache/mk2/pl/2.0"; B=""
  case "$id" in
    unsafe) A="$PL/cache/mk2/pl/2;0"; r30pl "$A";;
    ambiguous) r30pl "$A"; B="$PL/cache/mk2/pl/3.0"; r30pl "$B";;
    rejected) r30pl "$A"; printf '{"name": "pl"}\n' > "$X/ext/secret.json"; rm "$A/.claude-plugin/plugin.json"; ln -s "$X/ext/secret.json" "$A/.claude-plugin/plugin.json";;
    missing) ;;
    fifo) r30pl "$A"; rm "$A/skills/rep/SKILL.md"; mkfifo "$A/skills/rep/SKILL.md";;
    outside) r30pl "$A"; mv "$A/skills/rep/SKILL.md" "$X/ext/secret.txt"; ln -s "$X/ext/secret.txt" "$A/skills/rep/SKILL.md";;
    rejected-renamed) R30_LK=pl2@mk2; A="$PL/cache/mk2/pl2/2.0"; r30pl "$A"; r30pl "$PL/cache/mk2/pl2/1.0"
      printf '{"name": "pl"}\n' > "$X/ext/secret.json"; rm "$A/.claude-plugin/plugin.json"; ln -s "$X/ext/secret.json" "$A/.claude-plugin/plugin.json";;
  esac
  printf '{"version": 2, "plugins": {"%s": [%s%s]}}\n' "$R30_LK" "$(r30rec "$A")" "$( [ -z "$B" ] || printf ', %s' "$(r30rec "$B")" )" > "$PL/installed_plugins.json"
}
# r30check <out>: prints the failures, one per line (nothing when all pass)
r30check() {
  grep -qx "SUPERSEDED pl@mkt by $R30_LK" "$1" || echo "no 'SUPERSEDED pl@mkt by $R30_LK'"
  ! grep -q '^ACTIVE pl@mkt ' "$1" || echo "residual ACTIVE pl@mkt"
  ! grep -q '^NOCARD ' "$1" || echo "residual NOCARD: $(grep '^NOCARD ' "$1" | sed 's|.*/plugins/||' | tr '\n' ' ')"
  if grep -qx ROOTS-INCOMPLETE "$1"; then grep -q '^UNKNOWN plugin:pl/rep ' "$1" && ! grep -q '^GONE ' "$1" || echo "the card is not UNKNOWN (a root was refused)"; else grep -q '^GONE plugin:pl/rep ' "$1" || echo "the card is not GONE"; fi
}
