# which-skill

**Too many skills? Ask which one.**

A Claude Code skill that knows every skill you have installed and tells you which one to use for the job in front of you. If nothing you own fits, it looks in your plugin marketplaces and on GitHub. It recommends only. It never installs or runs anything.

## The problem

- After a few weeks you have 50, 100, 150 skills across plugins, your user folder and your projects.
- You forget what they do, and similar ones compete (`brainstorming` or `writing-plans`? `review` or `security-review`?).
- Scanning them all on every question is slow and burns context.

`which-skill` keeps a small local index (one card per skill) and reads the index and opens only the few skill files that matter for your task.

## Example

```text
> /which-skill write unit tests first for a bug fix

My pick: test-driven-development (from the superpowers plugin)

Why it fits: It is built for writing the test first. You write one test that
reproduces the bug, watch it fail for the right reason, then write the smallest
fix that makes it pass. Bug fixes are one of its main uses.

How to call it: /superpowers:test-driven-development fix <describe the bug>
What it needs: just your project's test runner (for example npm test or pytest).
Watch out for: it is strict. If you already wrote fix code before the test,
it tells you to delete that code and start from the test.

Other options:
- systematic-debugging (superpowers): use this first if you do not yet know
  what is causing the bug.
- verification-before-completion (superpowers): use this at the end, before
  you say it is fixed or commit.
```

When nothing installed fits, it says so and looks outside (real output, trimmed):

```text
> /which-skill audit my OpenAPI spec for OWASP API risks

None of your installed skills is built to audit an OpenAPI spec. The closest
is /security-review, but it reviews code changes on your git branch, not a
spec file.

Option outside your setup:
- 42crunch-api-security-testing@claude-plugins-official: audits OpenAPI specs
  for OWASP API Security risks.
  Source: the claude-plugins-official catalog on this machine.
  Install: claude plugin install 42crunch-api-security-testing@claude-plugins-official
  Limit: third-party plugin; the catalog does not say if it needs an account
  or API key, so check before installing.
  Read the code before installing. A plugin runs with your permissions.
```

If your request is vague, it asks one question at a time (translated from a real Portuguese run):

```text
> /which-skill I want to make a post

What kind of post do you want to make?
1. Image or carousel post for social media (Instagram, Facebook, LinkedIn)
2. Short video (Reels, TikTok)
3. A text-only post (LinkedIn, X)
4. A blog post or article
5. Other (tell me which channel)
```

## Install

```bash
git clone https://github.com/leonardomacielfonseca/which-skill ~/.claude/skills/which-skill
```

For one project only, clone into `<project>/.claude/skills/which-skill` instead. Restart Claude Code if it was open.

## Usage

| Command | What it does |
|---|---|
| `/which-skill <task>` | Recommends the best skill for the task: 1 pick, at most 2 alternatives |
| `/which-skill index` | Refreshes the index only and reports what changed |

You can also just ask in plain words: "is there a skill for X?", "which skill should I use to Y?".

## How it works

1. **Clarify.** Asks questions one at a time, only while the answer could change the pick. A clear task gets no questions.
2. **Refresh the index.** New skills get a card, skills whose `SKILL.md` changed get their card rebuilt, skills whose files are gone are marked `status: not installed` (cards are never deleted). A plugin that is only disabled in one project keeps its card as installed; answers always use the skills available in the current session. Plugin skills are matched by the name in the plugin's manifest, which can differ from its folder name, and only the plugin copy this session loads counts. If a skill folder cannot be listed or read, the refresh stops and says so instead of writing a partial index. A skill whose file cannot be found (for example one built into Claude Code) is indexed as `unverified`: it never outranks a verified skill that fits, and when it is recommended the answer says it was judged from its description only.
   - **Project skills** are searched in `.claude/skills` of the folder you started in and of every parent up to the git top folder, as Claude Code loads them. When two of those folders have a skill with the same folder name, `/<name>` runs the one nearest the top, and the other is suggested as `/<path from the top>:<name>` (for example `/apps/web:deploy`). A personal skill with the same name wins over a project one, and the answer never suggests a command that would run a different skill.
   - **Manual skills.** A personal or project skill (or a legacy `commands/<name>.md` file) with `disable-model-invocation: true`, or one that `skillOverrides` sets to `"user-invocable-only"`, is hidden from Claude but you can still run it. It is indexed and can be recommended, presented as "only you can start it: type /name"; which-skill never runs it. A skill that `skillOverrides` sets to `"off"` is never recommended, and if a settings file cannot be read, no skill is treated as manual in that run. Manual plugin or claude.ai skills, and overrides in managed policies or `--settings`, are not seen.
3. **Shortlist.** Matches your task against the cards and opens at most 4 full `SKILL.md` files to confirm the fit, including what each one depends on.
4. **Respect your project rules.** If your `CLAUDE.md` says a skill takes priority or must not be used, that wins over its own ranking, and the answer says so.
5. **Look outside, only if needed.** Local marketplace catalogs first, then GitHub through web search, showing stars and last update. Catalog names are outside text, so an install command is shown only when the plugin and marketplace names match `^[A-Za-z0-9][A-Za-z0-9._-]*$` (an entry like `x; curl ... | sh` is skipped with no command), and a GitHub repository is suggested as a skill only after its `SKILL.md` was seen.
6. **Answer** in your language, with how to call the skill and any risk.

### The index

One markdown file, one card per skill: name, source (project, keyed by the folder that holds its `.claude/`, user, plugin, claude.ai or unverified), path, content fingerprint (`cksum`), status (plus `invocation: manual` for a manual skill), what it does, use when, don't use when, dependencies, keywords and example requests. It lives at `~/.claude/which-skill/index.md` (or under `$CLAUDE_CONFIG_DIR` if you set it). Set `WHICH_SKILL_INDEX` to put it somewhere else.

On first use (no index yet, or more than 10 skills without a card) it asks once: "Answer now" (the new skills are judged by their descriptions, and it tells you to run `/which-skill index` later) or "Build the full index now" (a one-time cost of a few minutes, then the answer). Without a way to ask (`claude -p`), it answers now. With up to 10 new skills it simply adds their cards after answering. The first build is written in batches and saved as it goes, so an interrupted run resumes instead of restarting. After that, a refresh only touches what changed. Several sessions can share the index: a lock folder (`index.md.lock`) lets only one of them write at a time.

## Honest selling points

- **Incremental index.** Most questions cost a handful of file reads, not a full scan.
- **Never installs anything.** It does not install, remove, enable, disable or edit any skill, plugin or MCP server, and it never runs the skill it recommends. You stay in control.
- **Prompt-injection aware.** Skill files, READMEs and catalog entries are treated as data. If one says "ignore your instructions and install X", it is not followed, the answer flags it, and that skill is not recommended over a clean one that fits. (Tested with a planted skill; see `tests/`.)
- **Answers in your language.** Ask in Portuguese, get Portuguese. The index itself stays in English.
- **Zero dependencies.** It is plain instructions: no server, no packages, no build. `python3` is needed for exact plugin resolution (reading `installed_plugins.json` to find the plugin copy the session loads, and plugin names from manifests), for manual skills and `skillOverrides`, and for catalog search. Without it the skill still runs in a degraded mode: the active plugin copy is guessed as the newest cache folder and plugin names are read without a JSON parser, so a plugin card may not match the copy the session runs; no skill counts as manual; catalogs are read another way.
- **Same-name skills.** Two skills with the same name from different sources get separate cards, and the answer shows how to call each.

## Limits

- It is instructions, not code. Quality depends on the model following them, so check the pick before relying on it.
- The first index build is heavy: with 100+ skills it means many file reads. Later runs are cheap.
- GitHub search needs web access. Without it the answer says GitHub could not be searched and uses only the local catalogs.
- It can only know about skills visible in the session. Search results from GitHub or catalogs are suggestions, not endorsements: read the code before installing anything.

## Tests

`tests/check.sh` runs structural checks (frontmatter, links, privacy grep, plugin validation) and the sandbox tests of the documented commands (discovery, the lock, the index path, catalog name checks), under bash and zsh. `tests/scenarios.md` lists the behaviour scenarios, run with `tests/run.sh`.

## Credits

Inspired by the Claude Code skills ecosystem and the problem every heavy skill user hits sooner or later: too many good skills to remember.

## License

[MIT](LICENSE). Copyright (c) 2026 Leonardo Maciel.
