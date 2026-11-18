#!/usr/bin/env python3
"""Self-test for tests/check-index.sh (plain python3, no pytest).

  python3 -I tests/test_check_index.py

Writes small synthetic indexes into a private temp folder and checks the
verdict of check-index.sh on each. The focus is the session identity rule:
an `unverified` (or legacy `built-in`) card must not stay next to an
installed verified card of the same session skill. With --located, every
installed verified card in the session view must also point to a regular file
at a safe path (real files, a FIFO, a dangling symlink and an unsafe folder
are built in the temp folder).
Exit 0 = every case as expected, 1 = a case failed.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, 'check-index.sh')
HEADER = '<!-- which-skill index v1 · updated 2026-11-16 -->'


def card(source, name, status='installed', path=None, what='Does a thing.', invocation=None):
    if path is None:
        path = 'none' if source in ('unverified', 'built-in') else '/x/%s/SKILL.md' % name
    return '\n'.join([
        '## %s/%s' % (source, name), '', '```yaml',
        'name: %s' % name, 'source: %s' % source, 'path: %s' % path,
        'fingerprint: 123 45', 'status: %s' % status] + (['invocation: %s' % invocation] if invocation else []) + ['```', '',
        '**What it does:** %s' % what,
        '**Use when:** Testing.',
        "**Don't use when:** Not stated.",
        '**Depends on:** Nothing special.',
        '**Keywords:** test, card',
        '**Examples:**', '- "one"', '- "two"', ''])


def index(*cards):
    return HEADER + '\n\n' + '\n'.join(cards)


# (label, index text, extra args, expected exit)
CASES = [
    ('plugin card and unverified card of the same session skill',
     index(card('plugin:foo', 'review'), card('unverified', 'foo:review')), [], 1),
    ('legacy built-in card next to the located plugin card',
     index(card('built-in', 'foo:review'), card('plugin:foo', 'review')), [], 1),
    ('user card and unverified card with the same name',
     index(card('user', 'zz-guard'), card('unverified', 'zz-guard')), [], 1),
    ('claude.ai card and a prefixed unverified card',
     index(card('claude.ai', 'docs'), card('unverified', 'anthropic-skills:docs')), [], 1),
    ('claude.ai card and an unverified card under another prefix are different skills',
     index(card('claude.ai', 'docs'), card('unverified', 'foo:docs')), [], 0),
    ('claude.ai card and an unverified card under a look-alike prefix',
     index(card('claude.ai', 'docs'), card('unverified', 'anthropic-skills-x:docs')), [], 0),
    ('this project card and unverified card, root given',
     index(card('project:/home/me/proj', 'zz-guard'), card('unverified', 'zz-guard')), ['/home/me/proj'], 1),
    ('top folder and subfolder cards of one repository coexist',
     index(card('project:/home/me/repo', 'deploy'), card('project:/home/me/repo/app', 'deploy')), [], 0),
    ('top folder and subfolder cards coexist, both folders given',
     index(card('project:/home/me/repo', 'deploy'), card('project:/home/me/repo/app', 'deploy')),
     ['/home/me/repo', '/home/me/repo/app'], 0),
    ('subfolder card and unverified card, both folders given',
     index(card('project:/home/me/repo/app', 'deploy'), card('unverified', 'deploy')),
     ['/home/me/repo', '/home/me/repo/app'], 1),
    ('subfolder card and unverified card, only the top folder given',
     index(card('project:/home/me/repo/app', 'deploy'), card('unverified', 'deploy')), ['/home/me/repo'], 0),
    ('the unverified card replaced by the verified one',
     index(card('plugin:foo', 'review')), [], 0),
    ('unverified review and plugin foo:review are different skills',
     index(card('plugin:foo', 'review'), card('unverified', 'review')), [], 0),
    ('another project card and an unverified card, no root given',
     index(card('project:/home/me/other', 'deploy'), card('unverified', 'deploy')), [], 0),
    ('another project card and an unverified card, other root given',
     index(card('project:/home/me/other', 'deploy'), card('unverified', 'deploy')), ['/home/me/proj'], 0),
    ('verified card not installed, skill unverified again',
     index(card('plugin:foo', 'review', status='not installed'), card('unverified', 'foo:review')), [], 0),
    ('two different plugins, same skill name',
     index(card('plugin:foo', 'review'), card('plugin:bar', 'review')), [], 0),
]


def located_cases(work):
    """Cases for --located, with real files under `work` (HOME is `work`)."""
    def mk(rel, kind='file'):
        full = os.path.join(work, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if kind == 'file':
            with open(full, 'w') as fh:  # the frontmatter name is the folder name: the effective name
                fh.write('---\nname: %s\n---\nbody\n' % os.path.basename(os.path.dirname(full)))
        elif kind == 'fifo':
            os.mkfifo(full)
        elif kind == 'dangling':
            os.symlink(os.path.join(work, 'nowhere', 'SKILL.md'), full)
        return '~/' + rel
    ok_p = mk('.claude/skills/good/SKILL.md')
    fifo_p = mk('.claude/skills/fifo/SKILL.md', 'fifo')
    dang_p = mk('.claude/skills/dang/SKILL.md', 'dangling')
    unsafe_p = mk('.claude/skills/un;safe/SKILL.md')
    gone_p = '~/.claude/skills/gone/SKILL.md'
    proj = os.path.join(work, 'proj')
    proj_ok = mk('proj/.claude/skills/pk/SKILL.md')[2:]
    L = ['--located']
    return [
        ('--located: installed user card with a regular file',
         index(card('user', 'good', path=ok_p)), L, 0, None),
        ('--located: verified card whose file is a FIFO',
         index(card('user', 'fifo', path=fifo_p)), L, 1, 'not located'),
        ('--located: verified card whose file is a dangling symlink',
         index(card('user', 'dang', path=dang_p)), L, 1, 'not located'),
        ('--located: verified card whose file is gone',
         index(card('user', 'gone', path=gone_p)), L, 1, 'not located'),
        ('--located: verified card at a path with unsafe characters',
         index(card('user', 'unsafe', path=unsafe_p)), L, 1, 'not located'),
        ('--located: stale verified card (FIFO) next to the unverified card',
         index(card('user', 'fifo', path=fifo_p), card('unverified', 'fifo')), L, 1, 'not located'),
        ('--located: the downgraded card alone (unverified, path none)',
         index(card('unverified', 'fifo', what='Does a thing. Unverified: its file could not be read; '
                    'this card comes from the session description only. '
                    'Warning: its file is not a regular file; not read.')), L, 0, None),
        ('--located: not installed card whose file is gone',
         index(card('user', 'gone', status='not installed', path=gone_p)), L, 0, None),
        ('--located: another project card whose file is gone, its folder not given',
         index(card('project:/home/me/other', 'deploy', path='/home/me/other/.claude/skills/deploy/SKILL.md')), L, 0, None),
        ('--located: this project card with its file, folder given',
         index(card('project:' + proj, 'pk', path=os.path.join(work, proj_ok))), L + [proj], 0, None),
        ('--located: this project card whose file is gone, folder given',
         index(card('project:' + proj, 'pz', path=os.path.join(proj, '.claude/skills/pz/SKILL.md'))), L + [proj], 1, 'not located'),
        ('no --located: a missing file is not checked',
         index(card('user', 'gone', path=gone_p)), [], 0, None),
    ]


def source_cases(base):
    """--located with each source of the path table of index.md, every case in
    its own fake home (the CLAUDE_* variables of the caller removed), run from
    its project folder. Returns the number of cases not as expected."""
    def w(path, text=None):
        # default: the frontmatter name equals the folder name (a command file
        # is named by its file name), so the card key is the folder name
        if text is None:
            nm = os.path.basename(os.path.dirname(path)) if path.endswith('/SKILL.md') else os.path.basename(path)[:-3]
            text = '---\nname: %s\n---\nbody\n' % nm
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as fh:
            fh.write(text)
        return path
    def plug(folder, name, skill='rep', cmd=None):
        w(os.path.join(folder, '.claude-plugin', 'plugin.json'), '{"name": "%s"}\n' % name if name else '{}\n')
        f = w(os.path.join(folder, 'skills', skill, 'SKILL.md'))
        return f, (w(os.path.join(folder, 'commands', cmd + '.md')) if cmd else None)
    bad = 0
    ids = ['synced-two', 'synced-one', 'user', 'project', 'cache', 'cache-noname', 'synced-plugin', 'seed',
           'plugin-dir', 'unmapped', 'unmapped-plugin',
           'fm-user', 'fm-user-folderkey', 'fm-quoted', 'fm-project', 'fm-project-folderkey', 'fm-plugin',
           'fm-plugin-folderkey', 'fm-seed', 'fm-body-only', 'fm-empty',
           'px-cache', 'px-cache-doubled-key', 'px-seed', 'px-plugin-dir', 'px-foreign', 'px-twice', 'px-noname',
           'nm-leading-space', 'nm-leading-space-key', 'nm-angle', 'nm-angle-key', 'nm-quoted', 'nm-single-quoted',
           'nm-plain-comment', 'nm-nbsp', 'nm-double-space', 'nm-zero-width', 'nm-bidi', 'nm-control', 'nm-unterminated',
           'nm-trailing-junk', 'nm-flow', 'nm-reserved', 'nm-long', 'nm-words', 'nm-escape', 'nm-plugin-refused',
           'yb-broken', 'yb-broken-key', 'yb-colon', 'yb-dup', 'yb-tab', 'yb-clean', 'yb-plugin-broken',
           'yf-bracket', 'yf-brace', 'yf-comment', 'yf-inline', 'yd-space', 'yd-dq', 'yd-sq', 'yd-quoted-only',
           'yn-nested', 'yn-list', 'yn-mixed', 'yn-continuation', 'yn-dedent',
           'nt-true', 'nt-int', 'nt-date', 'nt-quoted-int', 'nt-indicator',
           'cmd-user', 'cmd-project', 'cmd-manual', 'cmd-manual-missing', 'cmd-under-skill']
    for cid in ids:
        h = os.path.join(base, 'src-' + cid); cfg = os.path.join(h, '.claude'); P = os.path.join(h, 'proj')
        os.makedirs(P); env = {k: v for k, v in os.environ.items() if not k.startswith('CLAUDE_') and k != 'WHICH_SKILL_INDEX'}
        env['HOME'] = h; cards = []; want, needle = 0, None
        if cid in ('synced-two', 'synced-one'):
            f1 = w(os.path.join(cfg, 'skills/synced/ID1/docs/SKILL.md'))
            if cid == 'synced-two':
                w(os.path.join(cfg, 'skills/synced/ID2/docs/SKILL.md')); want, needle = 1, '2 located files map to its key'
            cards.append(card('claude.ai', 'docs', path=f1))
        elif cid == 'user':
            cards.append(card('user', 'u', path=w(os.path.join(cfg, 'skills/u/SKILL.md'))))
        # deferred E1 r55: legacy command files are located and keyed by their file name
        # Codex adiados r2: a command that a same-name skill wins over maps to no key,
        # so it is not a second located file of the skill's card
        elif cid == 'cmd-under-skill':
            cards.append(card('user', 'foo', path=w(os.path.join(cfg, 'skills/foo/SKILL.md'))))
            w(os.path.join(cfg, 'commands/foo.md'))
        elif cid == 'cmd-user':
            cards.append(card('user', 'cu', path=w(os.path.join(cfg, 'commands/cu.md'))))
        elif cid == 'cmd-project':
            cards.append(card('project:' + P, 'cp', path=w(os.path.join(P, '.claude/commands/cp.md'))))
        elif cid in ('cmd-manual', 'cmd-manual-missing'):
            f = w(os.path.join(cfg, 'commands/cm.md'), '---\ndescription: x.\ndisable-model-invocation: true\n---\nbody\n')
            cards.append(card('user', 'cm', path=f, invocation='manual' if cid == 'cmd-manual' else None))
            if cid == 'cmd-manual-missing': want, needle = 1, 'lacks invocation: manual'
        elif cid == 'project':
            cards.append(card('project:' + P, 'pk', path=w(os.path.join(P, '.claude/skills/pk/SKILL.md'))))
        elif cid in ('cache', 'cache-noname'):
            c = os.path.join(cfg, 'plugins/cache/mkt/pl/1.0.0')
            f, cm = plug(c, 'pl' if cid == 'cache' else None, cmd='cmd')
            w(os.path.join(cfg, 'plugins/installed_plugins.json'),
              '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' % c)
            cards += [card('plugin:pl', 'rep', path=f), card('plugin:pl', 'cmd', path=cm)]
        elif cid == 'synced-plugin':
            f, _ = plug(os.path.join(cfg, 'plugins/synced/ID/sb~g2'), 'sb', skill='inv')
            cards.append(card('plugin:sb', 'inv', path=f))
        elif cid == 'seed':
            f, _ = plug(os.path.join(h, 'seed/sp'), 'sp', skill='rs'); env['CLAUDE_CODE_PLUGIN_SEED_DIR'] = os.path.join(h, 'seed')
            cards.append(card('plugin:sp', 'rs', path=f))
        elif cid == 'plugin-dir':
            f, _ = plug(os.path.join(h, 'ext/e1'), 'px', skill='rx'); env['CLAUDE_CODE_PLUGIN_DIRS'] = os.path.join(h, 'ext/e1')
            cards.append(card('plugin:px', 'rx', path=f))
        elif cid == 'unmapped':
            cards.append(card('user', 'u', path=w(os.path.join(cfg, 'skills/u/SKILL.md'))))
            w(os.path.join(cfg, 'skills/SKILL.md')); want, needle = 1, 'maps to no source'  # depth 1: walked, but no row of the path table
        elif cid == 'unmapped-plugin':
            f, _ = plug(os.path.join(h, 'ext/e1'), 'px', skill='rx'); env['CLAUDE_CODE_PLUGIN_DIRS'] = os.path.join(h, 'ext/e1')
            w(os.path.join(h, 'ext/e1/skills/rx/nested/SKILL.md')); want, needle = 1, 'maps to no source'
            cards.append(card('plugin:px', 'rx', path=f))
        # Round 46: the effective name is the frontmatter `name` (the first
        # frontmatter block, a top-level `name:` line), else the folder name.
        elif cid in ('fm-user', 'fm-user-folderkey'):
            f = w(os.path.join(cfg, 'skills/review/SKILL.md'), '---\nname: code-review\ndescription: x\n---\nbody\n')
            if cid == 'fm-user':
                cards.append(card('user', 'code-review', path=f))
            else:
                cards.append(card('user', 'review', path=f)); want, needle = 1, 'maps to the key user/code-review'
        elif cid == 'fm-quoted':
            f = w(os.path.join(cfg, 'skills/review/SKILL.md'), '---\r\ndescription: x\r\nname: "code-review"\r\n---\r\nbody\r\n')
            cards.append(card('user', 'code-review', path=f))
        elif cid in ('fm-project', 'fm-project-folderkey'):
            f = w(os.path.join(P, '.claude/skills/deploy-staging/SKILL.md'), '---\nname: deploy\n---\nbody\n')
            if cid == 'fm-project':
                cards.append(card('project:' + P, 'deploy', path=f))
            else:
                cards.append(card('project:' + P, 'deploy-staging', path=f)); want, needle = 1, 'maps to the key project:%s/deploy' % P
        elif cid in ('fm-plugin', 'fm-plugin-folderkey'):
            c = os.path.join(cfg, 'plugins/cache/mkt/pl/1.0.0')
            w(os.path.join(c, '.claude-plugin', 'plugin.json'), '{"name": "pl"}\n')
            f = w(os.path.join(c, 'skills/rep/SKILL.md'), '---\nname: report\n---\nbody\n')
            w(os.path.join(cfg, 'plugins/installed_plugins.json'),
              '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' % c)
            if cid == 'fm-plugin':
                cards.append(card('plugin:pl', 'report', path=f))
            else:
                cards.append(card('plugin:pl', 'rep', path=f)); want, needle = 1, 'maps to the key plugin:pl/report'
        elif cid == 'fm-seed':
            w(os.path.join(h, 'seed/sp/.claude-plugin/plugin.json'), '{"name": "sp"}\n')
            f = w(os.path.join(h, 'seed/sp/skills/rs/SKILL.md'), "---\nname: 'read-sheet'\n---\nbody\n")
            env['CLAUDE_CODE_PLUGIN_SEED_DIR'] = os.path.join(h, 'seed')
            cards.append(card('plugin:sp', 'read-sheet', path=f))
        elif cid == 'fm-body-only':
            # no top-level name in the first block: a nested `name:` and one in
            # a later block do not count, so the folder name is the name
            f = w(os.path.join(cfg, 'skills/u/SKILL.md'), '---\nmetadata:\n  name: nested\n---\nbody\n---\nname: later\n---\n')
            cards.append(card('user', 'u', path=f))
        elif cid == 'fm-empty':
            f = w(os.path.join(cfg, 'skills/u/SKILL.md'), '---\nname:\ndescription: x\n---\nbody\n')
            cards.append(card('user', 'u', path=f))
        # Round 47: a plugin skill whose frontmatter `name` already starts with
        # the plugin's own prefix is not prefixed again (Claude Code v2.1.246+):
        # exactly one `<plugin>:` is stripped; a foreign prefix is kept.
        elif cid.startswith('px-'):
            nm = {'px-foreign': 'other:report', 'px-twice': 'pl:pl:report'}.get(cid, 'pl:report')
            key = {'px-foreign': 'other:report', 'px-twice': 'pl:report', 'px-cache-doubled-key': 'pl:report'}.get(cid, 'report')
            if cid in ('px-seed',):
                c = os.path.join(h, 'seed/cache/mkt/pl/1.0.0'); env['CLAUDE_CODE_PLUGIN_SEED_DIR'] = os.path.join(h, 'seed')
            elif cid == 'px-plugin-dir':
                c = os.path.join(h, 'ext/pl'); env['CLAUDE_CODE_PLUGIN_DIRS'] = c
            else:
                c = os.path.join(cfg, 'plugins/cache/mkt/pl/1.0.0')
                w(os.path.join(cfg, 'plugins/installed_plugins.json'),
                  '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' % c)
            w(os.path.join(c, '.claude-plugin', 'plugin.json'), '{}\n' if cid == 'px-noname' else '{"name": "pl"}\n')
            f = w(os.path.join(c, 'skills/rep/SKILL.md'), '---\nname: %s\n---\nbody\n' % nm)
            cards.append(card('plugin:pl', key, path=f))
            if cid == 'px-cache-doubled-key':
                want, needle = 1, 'maps to the key plugin:pl/report'
        # Round 48: a frontmatter name Claude Code refuses (docs: "Characters a
        # skill name can't hold": control, zero-width or other format, private-use
        # or unassigned characters, any blank but one plain space between words,
        # `<` or `>`; outside a plugin, the reserved anthropic-skills prefix) or
        # that is not a valid YAML scalar gives no name: the key is the folder.
        # The docs set no length limit, so a long name stays valid.
        elif cid.startswith('nm-') and cid != 'nm-plugin-refused':
            NM = {'nm-leading-space': '" deploy"', 'nm-leading-space-key': '" deploy"', 'nm-angle': 'bad<name',
                  'nm-angle-key': 'bad<name', 'nm-quoted': '"deploy"', 'nm-single-quoted': "'it''s-deploy'",
                  'nm-plain-comment': '   deploy   # the deploy skill', 'nm-nbsp': '"de\\u00a0ploy"',
                  'nm-double-space': '"de  ploy"', 'nm-zero-width': 'de\u200bploy', 'nm-bidi': 'de\u202eploy',
                  'nm-control': '"de\\tploy"', 'nm-unterminated': '"deploy', 'nm-trailing-junk': '"deploy" x',
                  'nm-flow': '[deploy]', 'nm-reserved': 'anthropic-skills:deploy', 'nm-long': 'd' * 200,
                  'nm-words': 'deploy app', 'nm-escape': '"de\\x2dploy"'}[cid]
            KEY = {'nm-quoted': 'deploy', 'nm-single-quoted': "it's-deploy", 'nm-plain-comment': 'deploy',
                   'nm-long': 'd' * 200, 'nm-words': 'deploy app', 'nm-escape': 'de-ploy',
                   'nm-leading-space-key': ' deploy', 'nm-angle-key': 'bad<name'}.get(cid, 'release')
            f = w(os.path.join(cfg, 'skills/release/SKILL.md'), '---\nname: %s\ndescription: x\n---\nbody\n' % NM)
            cards.append(card('user', KEY, path=f))
            if cid.endswith('-key'):
                want, needle = 1, 'maps to the key user/release'
        elif cid == 'nm-plugin-refused':
            c = os.path.join(cfg, 'plugins/cache/mkt/pl/1.0.0')
            w(os.path.join(c, '.claude-plugin', 'plugin.json'), '{"name": "pl"}\n')
            f = w(os.path.join(c, 'skills/rep/SKILL.md'), '---\nname: "pl: report"\n---\nbody\n')
            w(os.path.join(cfg, 'plugins/installed_plugins.json'),
              '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' % c)
            cards.append(card('plugin:pl', 'rep', path=f))
        # Round 49: a first frontmatter block that is not certainly valid YAML
        # (Claude Code would then drop every field) is `uncertain`: its `name`
        # is not used, and the key is the folder name.
        elif cid[:3] in ('yb-', 'yf-', 'yd-', 'yn-', 'nt-') and cid != 'yb-plugin-broken':
            FM = {'yb-broken': 'name: deploy\ndescription: [unclosed\n',
                  'yb-broken-key': 'name: deploy\ndescription: [unclosed\n',
                  'yb-colon': 'name: deploy\ndescription: Use when: deploying\n',
                  'yb-dup': 'name: deploy\nname: other\n',
                  'yb-tab': 'name: deploy\nmetadata:\n\tteam: ops\n',
                  # Round 49 review: in the fallback any flow collection, and any
                  # quoted or spaced top-level key, is uncertain; a duplicate
                  # normalized key is never ok
                  'yf-bracket': 'name: deploy\nallowed-tools: [Read}\n',
                  'yf-brace': 'name: deploy\nmetadata: {team: ops]\n',
                  'yf-comment': 'name: deploy\nallowed-tools: [Read # ]\n',
                  'yf-inline': 'name: deploy\ndescription: Use x {a} here\n',
                  'yd-space': 'name: deploy\nname : other\n',
                  'yd-dq': 'name: deploy\n"name": other\n',
                  'yd-sq': "name: deploy\n'name': other\n",
                  'yd-quoted-only': '"name": deploy\n',
                  # Round 50: without PyYAML only flat blocks are ok
                  'yn-nested': 'name: deploy\nmetadata:\n  team: ops\n',
                  'yn-list': 'name: deploy\ntags:\n  - a\n',
                  'yn-mixed': 'name: deploy\nmetadata:\n  x: y\n  - bad\n',
                  'yn-continuation': 'name: deploy\ndescription: one\n  two\n',
                  # Round 52: a block scalar body with an invalid dedent is uncertain
                  'yn-dedent': 'name: deploy\ndescription: |\n  first\n second\n',
                  # Round 51: typed plain names are refused; an indicator value is uncertain
                  'nt-true': 'name: true\n', 'nt-int': 'name: 123\n', 'nt-date': 'name: 2026-01-01\n',
                  'nt-quoted-int': 'name: "123"\n', 'nt-indicator': 'name: deploy\nallowed-tools: - Read\n',
                  'yb-clean': '# a comment\nname: "deploy"\ndescription: >-\n  Deploys: the app,\n  [and more]\n'
                              'allowed-tools: Read, Grep\nteam: ops\ntag: "b: c [d]"\n\n'
                              'when_to_use: |\n  - anything: goes\n'}[cid]
            f = w(os.path.join(cfg, 'skills/release/SKILL.md'), '---\n' + FM + '---\nbody\n')
            cards.append(card('user', {'yb-clean': 'deploy', 'yb-broken-key': 'deploy', 'nt-quoted-int': '123'}.get(cid, 'release'), path=f))
            if cid == 'yb-broken-key':
                want, needle = 1, 'maps to the key user/release'
        elif cid == 'yb-plugin-broken':
            c = os.path.join(cfg, 'plugins/cache/mkt/pl/1.0.0')
            w(os.path.join(c, '.claude-plugin', 'plugin.json'), '{"name": "pl"}\n')
            f = w(os.path.join(c, 'skills/rep/SKILL.md'), '---\nname: report\ndescription: "unterminated\n---\nbody\n')
            w(os.path.join(cfg, 'plugins/installed_plugins.json'),
              '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' % c)
            cards.append(card('plugin:pl', 'rep', path=f))
        idx = os.path.join(h, 'index.md')
        with open(idx, 'w') as fh:
            fh.write(index(*cards))
        for sh in ('bash', 'zsh'):
            if not shutil.which(sh):
                continue
            env['CHECK_SH'] = sh
            r = subprocess.run(['bash', CHECK, '--located', idx, P], cwd=P, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, universal_newlines=True)
            label = '--located source %s (%s)' % (cid, sh)
            if r.returncode != want or (needle and needle not in r.stdout) or (want == 0 and 'INDEX OK' not in r.stdout):
                bad += 1
                print('NOT OK %s: exit %d, expected %d%s\n  %s' % (label, r.returncode, want,
                      (' with "%s"' % needle) if needle else '', r.stdout.strip().replace('\n', '\n  ')))
            else:
                print('ok     %s' % label)
    return bad, 2 * len(ids)


def r53_cases(base):
    """Round 53, --located, every case in its own fake home, run from the
    working folder given first:
      manual skills: a user or project card of a local skill whose first
        frontmatter block is `ok` and has `disable-model-invocation: true`
        carries `invocation: manual`; the field is refused on any other source
        and on a card whose located file is not such a skill (no flag, an
        `uncertain` block, `user-invocable: false`), and a flagged local file
        whose card lacks it fails;
      project roots from the working folder up to the git top folder: a card
        of an intermediate folder is located and keyed by that folder."""
    def w(path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as fh:
            fh.write(text)
        return path
    FLAG = 'disable-model-invocation: true\n'
    bad = 0
    ids = ['mn-user', 'mn-project', 'mn-static-plugin', 'mn-static-value', 'mn-plugin', 'mn-noflag',
           'mn-uncertain', 'mn-noinvoke', 'mn-missing', 'mn-quoted-flag',
           'ch-intermediate', 'ch-clash', 'ch-wrongkey', 'ch-sibling', 'ch-gone',
           'ov-off', 'ov-off-plain', 'ov-broken', 'ov-uio-only', 'ov-uio-missing']
    for cid in ids:
        h = os.path.join(base, 'r53-' + cid); cfg = os.path.join(h, '.claude'); R = os.path.join(h, 'repo')
        S = os.path.join(R, 'apps', 'web', 'src'); os.makedirs(S)
        subprocess.run(['git', 'init', '-q', R], check=True)
        env = {k: v for k, v in os.environ.items() if not k.startswith('CLAUDE_') and k != 'WHICH_SKILL_INDEX'}
        env['HOME'] = h; env['GIT_CEILING_DIRECTORIES'] = base; cards = []; want, needle = 0, None; located = True
        us = os.path.join(cfg, 'skills/ship/SKILL.md')
        if cid == 'mn-user':
            cards.append(card('user', 'ship', path=w(us, '---\nname: ship\n' + FLAG + '---\n'), invocation='manual'))
        elif cid == 'mn-project':
            f = w(os.path.join(R, '.claude/skills/ship/SKILL.md'), '---\nname: ship\n' + FLAG + '---\n')
            cards.append(card('project:' + R, 'ship', path=f, invocation='manual'))
        elif cid in ('mn-static-plugin', 'mn-static-value'):
            located = False; want = 1; needle = 'invocation'
            cards.append(card('plugin:pl', 'ship', invocation='manual') if cid == 'mn-static-plugin'
                         else card('user', 'ship', invocation='auto'))
        elif cid == 'mn-plugin':
            c = os.path.join(cfg, 'plugins/cache/mkt/pl/1.0.0')
            w(os.path.join(c, '.claude-plugin/plugin.json'), '{"name": "pl"}\n')
            f = w(os.path.join(c, 'skills/ship/SKILL.md'), '---\nname: ship\n' + FLAG + '---\n')
            w(os.path.join(cfg, 'plugins/installed_plugins.json'),
              '{"version": 2, "plugins": {"pl@mkt": [{"scope": "user", "installPath": "%s"}]}}\n' % c)
            cards.append(card('plugin:pl', 'ship', path=f, invocation='manual')); want, needle = 1, 'invocation'
        elif cid in ('mn-noflag', 'mn-uncertain', 'mn-noinvoke', 'mn-quoted-flag'):
            fm = {'mn-noflag': '', 'mn-uncertain': FLAG + 'argument-hint: [unclosed\n',
                  'mn-noinvoke': FLAG + 'user-invocable: false\n',
                  'mn-quoted-flag': 'disable-model-invocation: "true"\n'}[cid]
            cards.append(card('user', 'ship', path=w(us, '---\nname: ship\n' + fm + '---\n'), invocation='manual'))
            want, needle = 1, 'not a manual skill'
        elif cid == 'mn-missing':
            cards.append(card('user', 'ship', path=w(us, '---\nname: ship\n' + FLAG + '---\n')))
            want, needle = 1, 'invocation: manual'
        elif cid in ('ch-intermediate', 'ch-clash', 'ch-wrongkey'):
            f = w(os.path.join(R, 'apps/.claude/skills/deploy/SKILL.md'), '---\nname: deploy\n---\n')
            if cid == 'ch-clash':
                t = w(os.path.join(R, '.claude/skills/deploy/SKILL.md'), '---\nname: deploy\n---\n')
                cards.append(card('project:' + R, 'deploy', path=t))
            if cid == 'ch-wrongkey':
                cards.append(card('project:' + R, 'deploy', path=f)); want, needle = 1, 'maps to the key project:%s/apps/deploy' % R
            else:
                cards.append(card('project:' + os.path.join(R, 'apps'), 'deploy', path=f))
        elif cid == 'ch-gone':  # an intermediate folder's card is in view: its missing file fails
            cards.append(card('project:' + os.path.join(R, 'apps'), 'gone', path=os.path.join(R, 'apps/.claude/skills/gone/SKILL.md')))
            want, needle = 1, 'not located'
        # Round 54: skillOverrides decide too (the overrides block of index.md)
        elif cid in ('ov-off', 'ov-off-plain'):
            w(os.path.join(R, '.claude/settings.local.json'), '{"skillOverrides": {"ship": "off"}}\n')
            if cid == 'ov-off':
                cards.append(card('user', 'ship', path=w(us, '---\nname: ship\n' + FLAG + '---\n'), invocation='manual'))
                want, needle = 1, 'not a manual skill'
            else:
                cards.append(card('user', 'ship', path=w(us, '---\nname: ship\n' + FLAG + '---\n')))
        elif cid == 'ov-broken':
            w(os.path.join(S, '.claude/settings.json'), '{"skillOverrides": {},}\n')
            cards.append(card('user', 'ship', path=w(us, '---\nname: ship\n' + FLAG + '---\n'), invocation='manual'))
            want, needle = 1, 'not a manual skill'
        elif cid in ('ov-uio-only', 'ov-uio-missing'):
            w(os.path.join(cfg, 'settings.json'), '{"skillOverrides": {"ship": "user-invocable-only"}}\n')
            f = w(us, '---\nname: ship\n---\n')
            if cid == 'ov-uio-only':
                cards.append(card('user', 'ship', path=f, invocation='manual'))
            else:
                cards.append(card('user', 'ship', path=f)); want, needle = 1, 'lacks invocation: manual'
        elif cid == 'ch-sibling':
            f = w(os.path.join(R, 'other/.claude/skills/x/SKILL.md'), '---\nname: x\n---\n')
            cards.append(card('project:' + os.path.join(R, 'other'), 'x', path=f))  # another folder's card: not in view
        idx = os.path.join(h, 'index.md')
        with open(idx, 'w') as fh:
            fh.write(index(*cards))
        for sh in ('bash', 'zsh'):
            if not shutil.which(sh):
                continue
            env['CHECK_SH'] = sh
            argv = ['bash', CHECK] + (['--located'] if located else []) + [idx, S]
            r = subprocess.run(argv, cwd=S, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
            label = 'r53 %s (%s)' % (cid, sh)
            if r.returncode != want or (needle and needle not in r.stdout) or (want == 0 and 'INDEX OK' not in r.stdout):
                bad += 1
                print('NOT OK %s: exit %d, expected %d%s\n  %s' % (label, r.returncode, want,
                      (' with "%s"' % needle) if needle else '', r.stdout.strip().replace('\n', '\n  ')))
            else:
                print('ok     %s' % label)
    return bad, 2 * len(ids)


# Round 51: (status, name) of a block. A plain value that YAML reads as a
# bool, null, number or date is no name; quoted values stay strings; a value
# starting with an indicator makes the block uncertain.
NAME_UNITS = (
    (['name: true'], ('ok', None)), (['name: Off'], ('ok', None)), (['name: 123'], ('ok', None)),
    (['name: 0x1F'], ('ok', None)), (['name: .inf'], ('ok', None)), (['name: 1.5e3'], ('ok', None)),
    (['name: 2026-01-01'], ('ok', None)), (['name: null'], ('ok', None)),
    (['name: "123"'], ('ok', '123')), (["name: 'true'"], ('ok', 'true')), (['name: deploy'], ('ok', 'deploy')),
    (['name: deploy', 'allowed-tools: - Read'], ('uncertain', 'deploy')),
    (['name: deploy', 'allowed-tools: Read, Grep'], ('ok', 'deploy')),
    # Round 52: YAML 1.2 Core types any [-+]?[0-9]+ as an int
    (['name: 0128'], ('ok', None)), (['name: +0128'], ('ok', None)), (['name: -0009'], ('ok', None)),
    (['name: "0128"'], ('ok', '0128')),
)


def name_units(ns, label):
    bad = 0
    for lines, want in NAME_UNITS:
        got = ns['block_info'](lines)
        if got != want:
            bad += 1; print('NOT OK %s name %r: %r, expected %r' % (label, lines, got, want))
        else:
            print('ok     %s name %r: %r' % (label, lines, want))
    return bad


def real_pyyaml():
    """With a real PyYAML (run this file with --units under an interpreter
    that has it): the same units and the duplicate-key loader."""
    try:
        import yaml  # noqa: F401
    except Exception:
        print('SKIP   real PyYAML not importable here'); return 0, 0
    ns = {}
    exec(compile(open(os.path.join(HERE, 'frontmatter-name.py')).read(), 'frontmatter-name.py', 'exec'), ns)
    bad = name_units(ns, 'real pyyaml')
    for lines, want in ((['name: deploy', 'meta:', '  a: 1', '  a: 2'], 'uncertain'),
                        (['name: deploy', 'meta:', '  x: y', '  - bad'], 'uncertain'),
                        (['name: deploy', 'meta:', '  team: ops', 'tags: [a, b]'], 'ok'),
                        (['name: deploy', 'x: [Read}'], 'uncertain')):
        got = ns['block_status'](lines)
        if got != want:
            bad += 1; print('NOT OK real pyyaml %r: %s, expected %s' % (lines, got, want))
        else:
            print('ok     real pyyaml %r: %s' % (lines, want))
    return bad, len(NAME_UNITS) + 4


def pyyaml_branch():
    """frontmatter-name.py with a stub `yaml` module: a mapping is `ok`, a
    parse error or a non-mapping is `uncertain`; a duplicate key stays
    `uncertain` even when the parser accepts it. Returns failures."""
    import types
    stub = types.ModuleType('yaml')
    class YE(Exception):
        pass
    def safe_load(t):
        if 'BROKEN' in t:
            raise YE('bad')
        if 'LIST' in t:
            return ['x']
        d = {}
        for l in t.splitlines():  # a naive stand-in for YAML typing
            if ': ' not in l or l[:1] in ' "\'':
                continue
            k, v = l.split(': ', 1)
            if v[:2] in ('- ', '? '):
                raise YE('indicator')
            if v[:1] in '"\'':
                v = v[1:-1]
            elif v.lower() in ('true', 'false', 'on', 'off', 'yes', 'no'):
                v = v.lower() in ('true', 'on', 'yes')
            elif v.lower() in ('null', '~'):
                v = None
            elif v[:1].isdigit() or v[:1] in '.-+':
                v = 1.0
            d[k] = v
        return d
    class SafeLoader(object):
        def construct_mapping(self, node, deep=False):
            return {}
    def load(t, Loader=None):
        return safe_load(t)
    stub.safe_load, stub.YAMLError, stub.SafeLoader, stub.load = safe_load, YE, SafeLoader, load
    saved = sys.modules.get('yaml'); sys.modules['yaml'] = stub
    try:
        ns = {}
        exec(compile(open(os.path.join(HERE, 'frontmatter-name.py')).read(), 'frontmatter-name.py', 'exec'), ns)
    finally:
        if saved is None:
            sys.modules.pop('yaml', None)
        else:
            sys.modules['yaml'] = saved
    bad = 0
    CASES = ((['name: deploy', 'x: [a, b]'], 'ok'), (['name: deploy', 'BROKEN'], 'uncertain'),
             (['LIST'], 'uncertain'), (['name: a', 'name: b'], 'uncertain'),
             (['name: deploy', 'name : other'], 'uncertain'), (['name: deploy', '"name": other'], 'uncertain'),
             (['name: deploy', "'name': other"], 'uncertain'), (['"name": deploy'], 'uncertain'),
             (['name: deploy', 'description: x'], 'ok'))
    bad += name_units(ns, 'pyyaml stub')
    for lines, want in CASES:
        got = ns['block_status'](lines)
        if got != want:
            bad += 1; print('NOT OK pyyaml branch %r: %s, expected %s' % (lines, got, want))
        else:
            print('ok     pyyaml branch %r: %s' % (lines, want))
    # the fallback (no PyYAML): flow collections and quoted or spaced keys are uncertain
    ns2 = {}
    exec(compile(open(os.path.join(HERE, 'frontmatter-name.py')).read(), 'frontmatter-name.py', 'exec'), ns2)
    ns2['_yaml'] = None
    bad += name_units(ns2, 'fallback')
    for lines, want in ((['name: deploy', 'allowed-tools: [Read}'], 'uncertain'),
                        (['name: deploy', 'metadata: {team: ops]'], 'uncertain'),
                        (['name: deploy', 'allowed-tools: [Read # ]'], 'uncertain'),
                        (['name: deploy', 'allowed-tools: [Read, Grep]'], 'uncertain'),
                        (['name: deploy', 'name : other'], 'uncertain'), (['name: deploy', '"name": other'], 'uncertain'),
                        (['name: deploy', "'name': other"], 'uncertain'), (['"x": 1'], 'uncertain'),
                        (['name: deploy', 'description: "has [brackets]"', 'k: |', '  {raw}'], 'ok'),
                        (['name: deploy', 'metadata:', '  x: y', '  - bad'], 'uncertain'),
                        (['name: deploy', 'tags:', '  - a', '  b: c'], 'uncertain'),
                        (['name: deploy', 'metadata:', '  team: ops'], 'uncertain'),
                        (['name: deploy', 'tags:', '- a'], 'uncertain'),
                        (['name: deploy', 'tags:', '  - a'], 'uncertain'),
                        (['name: deploy', 'description: one', '  two'], 'uncertain'),
                        (['name: deploy', 'description: |', '  line one', '', '  - looks: nested', 'k: v'], 'ok'),
                        (['name: deploy', 'description: |', '  line one', '', '    - looks: nested', 'k: v'], 'uncertain'),
                        (['name: deploy', 'description: >-', '  folded', 'when_to_use: |+', '  kept'], 'ok'),
                        # Round 52: a block scalar header has no indentation digit, and
                        # every body line has the indentation of the first one
                        (['name: deploy', 'when_to_use: |2+', '  kept'], 'uncertain'),
                        (['name: deploy', 'description: |12', '  x'], 'uncertain'),
                        (['name: deploy', 'description: |', '  first', ' second'], 'uncertain'),
                        (['name: deploy', 'description: |', '  first', '   deeper'], 'uncertain'),
                        (['name: deploy', 'description: |', '\tfirst'], 'uncertain'),
                        (['name: deploy', 'description: |', '  first', '  \tsecond'], 'ok'),
                        (['name: deploy', 'description: |', '  first', '\t', '  second'], 'uncertain'),
                        (['name: deploy', 'description: |', '  first', '', '  second', 'k: v'], 'ok'),
                        (['name: deploy', 'description: >-', '    a', '    b'], 'ok')):
        got = ns2['block_status'](lines)
        if got != want:
            bad += 1; print('NOT OK fallback %r: %s, expected %s' % (lines, got, want))
        else:
            print('ok     fallback %r: %s' % (lines, want))
    return bad


def main():
    work = os.path.realpath(tempfile.mkdtemp(prefix='which-skill-index-test-'))  # physical, as discovery's pwd -P
    bad = 0
    env = dict(os.environ, HOME=work)
    cases = [c + (None,) for c in CASES] + located_cases(work)
    try:
        for n, (label, text, args, want, needle) in enumerate(cases, 1):
            path = os.path.join(work, 'index-%d.md' % n)
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(text)
            if args[:1] == ['--located']:
                argv = ['bash', CHECK, '--located', path] + args[1:]
            else:
                argv = ['bash', CHECK, path] + args
            p = subprocess.run(argv, stdout=subprocess.PIPE, env=env,
                               stderr=subprocess.STDOUT, universal_newlines=True)
            if p.returncode != want or (needle and needle not in p.stdout):
                bad += 1
                print('NOT OK %s: exit %d, expected %d%s\n  %s' % (
                    label, p.returncode, want, (' with "%s"' % needle) if needle else '', p.stdout.strip().replace('\n', '\n  ')))
            else:
                print('ok     %s' % label)
        sb, sn = source_cases(work)
        rb, rn = r53_cases(work)
        bad += sb + rb + pyyaml_branch(); sn += rn + 36 + 2 * len(NAME_UNITS)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print('%d cases, %d not as expected' % (len(cases) + sn, bad))
    if bad:
        print('TEST CHECK-INDEX FAILED')
        return 1
    print('TEST CHECK-INDEX OK')
    return 0


if __name__ == '__main__':
    if sys.argv[1:] == ['--units']:
        b, n = real_pyyaml(); b += pyyaml_branch()
        print('units: %d not as expected' % b); sys.exit(1 if b else 0)
    sys.exit(main())
