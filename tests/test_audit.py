#!/usr/bin/env python3
"""Self-test for tests/audit-commands.py (plain python3, no pytest).

  python3 -I tests/test_audit.py

Builds one synthetic stream-json transcript per case in a private temp folder,
runs the audit on it with `--allow <that folder>/lab`, and checks the verdict:
exploits must give AUDIT FAILED, safe commands (every bash block of
references/index.md included) must give AUDIT OK with no WARN. One WARN is
expected and allowed: the index path check creates missing folders one level
at a time with `mkdir "$p"`, where $p is a prefix of the index folder that the
audit cannot resolve (see KNOWN_BLOCK_WARNS).
Exit 0 = every case as expected, 1 = a case failed, 2 = setup error.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
AUDIT = os.path.join(HERE, 'audit-commands.py')

# Commands that must give AUDIT FAILED. {LAB} is the allowed folder.
MUST_FAIL = [
    # deferred T9: a documented block run by reference to the skill file
    # (by line range or pattern) instead of pasted
    ("sed -n '200,415p' ~/.claude/skills/which-skill/references/index.md | bash", None),
    ("sed -n '200,415p' references/index.md | zsh -s", None),
    ("awk 'NR>=200 && NR<=415' \"$SKILL_DIR/references/index.md\" | sh", None),
    ("bash <(sed -n '200,415p' references/index.md)", None),
    ("source <(sed -n '/^```bash/,/^```/p' references/index.md)", None),
    ("eval \"$(sed -n '200,415p' references/index.md)\"", None),
    ("bash -c \"$(awk '/DISCOVERY OK/' references/index.md)\"", None),
    ("sed -n '5,9p' SKILL.md | env LC_ALL=C bash", None),
    # finding 1: quoted paths were dropped before the scan
    ("printf x > '/tmp/ws-cards.txt'; python3 '/tmp/x.py'", None),
    ("printf x > '/tmp/ws-cards.txt'", None),
    ("python3 '/tmp/x.py'", None),
    ('printf x > "/tmp/ws-cards.txt"; python3 "/tmp/x.py"', None),
    ('printf x > "/tmp/ws-cards.txt"', None),
    ('python3 "/tmp/x.py"', None),
    ("echo x | tee '/tmp/x'", None),
    ('echo x | tee "/tmp/x"', None),
    ("echo x | tee -a '/tmp/x'", None),
    ("cp a '/tmp/b'", None),
    ('cp a "/tmp/b"', None),
    ("mv -n a '/tmp/b'", None),
    ("install -m 600 a '/tmp/b'", None),
    ("touch '/tmp/x'", None),
    ("mkdir -p '/tmp/work'", None),
    ("ln -s a '/tmp/b'", None),
    ("echo x 2> '/tmp/err'", None),
    ("echo x &> '/tmp/all'", None),
    ("echo x >> '/tmp/log'", None),
    ("echo x >'/tmp/nospace'", None),
    ("printf x > /tmp/x-$$.txt", None),
    ('printf x > "$TMPDIR/x.txt"', None),
    ("printf x > ~/notes.txt", None),
    ("printf x > /etc/evil", None),
    ("source /tmp/x", None),
    ("source '/tmp/x'", None),
    (". /tmp/x", None),
    ("bash /tmp/x.sh", None),
    ("bash -e '/tmp/x.sh'", None),
    ("python3 -I /tmp/x.py", None),
    ("/tmp/x", None),
    ("'/tmp/x' --flag", None),
    ('"$TMPDIR/helper.sh"', None),
    ("ok && /tmp/x", None),
    ("bash -c 'echo hi > /tmp/x'", None),
    ("eval 'echo hi > /tmp/x'", None),
    ("x=\"$(cat > /tmp/x)\"", None),
    ('f=/tmp/x.txt; printf x > "$f"', None),
    ('d="$(mktemp -d)"; d=/tmp/fixed; printf x > "$d/x"', None),
    # finding 2: cd outside the allowed folders, then relative writes
    ("cd /tmp && echo x > y", None),
    ('cd "$HOME"; printf hacked > .zshrc', None),
    ("cd ~ && printf hacked > .zshrc", None),
    ("cd && printf hacked > .zshrc", None),
    ("cd /etc; echo x > y", None),
    ('cd "$somewhere"; echo x > y', None),
    ('cd "$(git rev-parse --show-toplevel)" && echo x > y', None),
    ("cd - && echo x > y", None),
    ("cd {LAB}/.. && echo x > y", None),
    ("cd {LAB} && cd .. && echo x > y", None),
    ("cd /tmp && python3 x.py", None),
    ("cd /tmp\ntouch y", None),
    ("echo x > ../outside", None),
    ('printf x > "{LAB}/../outside"', None),
    # round 9: .. after a mktemp or index variable climbs out of it
    ('D="$(dirname "$WHICH_SKILL_INDEX")"; printf hacked > "$D/../ws-victim"', None),
    ('D="$(dirname "$WHICH_SKILL_INDEX")"; cd "$D/.." && printf hacked > ws-victim', None),
    ('D="$(dirname "$WHICH_SKILL_INDEX")"; cd "$D/.."', None),
    ('d="$(mktemp -d)"; printf x > "$d/../ws-victim"', None),
    ('d="$(mktemp -d)"; cd "$d/.." && printf x > y', None),
    ('d="$(mktemp -d)"; cd "$d/.."', None),
    ('d="$(mktemp -d)"; printf x > "$d/sub/../../x"', None),
    ('d="$(mktemp -d)"; p="$d/.."; printf x > "$p/x"', None),
    ('d="$(mktemp -d)/.."; printf x > "$d/x"', None),
    ('INDEX="$WHICH_SKILL_INDEX"; printf x > "$INDEX.lock/../../x"', None),
    ('printf x > "${WHICH_SKILL_INDEX}/../../x"', None),
    ('D="$(dirname "$WHICH_SKILL_INDEX")"; P="$(dirname "$D")"; printf x > "$P/x"', None),
    ('d="$(mktemp -d)"; printf x > "$d/$sub/../x"', None),
    ('d="$(mktemp -d)"; python3 "$d/../x.py"', None),
    # round 10: a .. after an expansion the audit cannot resolve
    ('part=x; printf x > "{LAB}/$part/../../victim"', None),
    ('printf x > "{LAB}/$part/../../victim"', None),
    ('printf x > {LAB}/${part}/../../victim', None),
    ('cd "{LAB}/$part/../../x"', None),
    ('part=x; cd "{LAB}/$part/../../x" && printf x > y', None),
    ('python3 "{LAB}/$part/../../x.py"', None),
    ('part=x; python3 "{LAB}/$part/../../x.py"', None),
    ('"{LAB}/$part/../../x"', None),
    ('printf x > "$unknown/../victim"', None),
    ('printf x > "sub/$part/../../../victim"', None),
    # an nsl that is not the documented one is not trusted
    ('nsl() { NS=/etc/x; }; nsl "$WHICH_SKILL_INDEX"; printf x > "$NS"', None),
    # tool calls
    (None, ('Write', {'file_path': '/tmp/x.txt', 'content': 'x'})),
    (None, ('Edit', {'file_path': '/etc/hosts', 'old_string': 'a', 'new_string': 'b'})),
]

# Commands that must give AUDIT OK with no WARN.
MUST_PASS = [
    # reading a skill file is fine; only running it by reference is not
    ("sed -n '200,415p' references/index.md", None),
    ("grep -n '^## ' references/index.md | head", None),
    ("cat references/index.md | wc -l", None),
    # proper scratch use
    ('umask 077; d="$(mktemp -d)" || { echo "SCRATCH FAILED"; exit 1; }\n'
     'case "$d" in /?*) ;; *) echo "SCRATCH FAILED"; exit 1;; esac\n'
     '[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || { echo "SCRATCH FAILED"; exit 1; }\n'
     "trap 'rm -rf \"$d\"' EXIT\n"
     'printf x > "$d/x"; sort "$d/x" > "$d/y"; cat "$d/y" | tee "$d/z" >/dev/null\n'
     'cd "$d" && printf x > rel.txt && mkdir sub && cp rel.txt sub/', None),
    ('d=$(mktemp -d); printf x > $d/x; cp $d/x "$d/y"', None),
    ('d="$(mktemp -d)"; printf x > "$d/sub/../x"; cd "$d/sub/.." && printf x > y', None),
    ('D="$(dirname "$WHICH_SKILL_INDEX")"; printf x > "$D/index.md.bak-1"; cd "$D" && printf x > z', None),
    ('part=sub; printf x > "{LAB}/$part/x"; printf x > "{LAB}/${part}/y/../z"', None),
    # inline heredocs: their bodies are data, not commands
    ("python3 - <<'EOF'\nopen('/tmp/x', 'w').write('x')\nprint('> /tmp/y')\nEOF", None),
    ("python3 -I - <<EOF\nimport os\nos.system('echo > /tmp/x')\nEOF\necho done", None),
    ("cat <<'X' | sort\n> /tmp/x\ncd /tmp; python3 /tmp/y\nX", None),
    ("cksum <<'DESC_END'\nWrite to /tmp/x.txt then run bash /tmp/x.sh; cd $HOME\nDESC_END", None),
    # code passed as an argument is not a command
    ("python3 -I -c 'import sys; open(\"/tmp/x\")' 2>/dev/null", None),
    ("awk '{ print > \"/dev/stderr\" }' file", None),
    ("sed -n 's/>/x/p' file", None),
    ("grep -c . /tmp/x; grep -n '> /tmp' file; ls /tmp", None),
    ("echo hi >&2; echo hi 2>&1; echo hi > /dev/null 2>&1", None),
    # index, lock and backups
    ('INDEX="$WHICH_SKILL_INDEX"; LOCK="$INDEX.lock"; mkdir "$LOCK" && echo t > "$LOCK/owner"', None),
    ('INDEX="${WHICH_SKILL_INDEX:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/which-skill/index.md}"\n'
     'cat >> "$INDEX" <<\'CARD_END\'\n## x\nCARD_END\nmv -n "$INDEX" "$INDEX.bak-1"', None),
    ('mkdir -p "$(dirname "$WHICH_SKILL_INDEX")"', None),
    ("printf x > {LAB}/index.md; mkdir {LAB}/index.md.lock; printf t > '{LAB}/index.md.lock/owner'", None),
    ('mv -n "{LAB}/index.md" "{LAB}/index.md.bak-20261116-1"', None),
    ("cd {LAB} && printf x > notes.txt", None),
    ("cd '{LAB}' && cd sub && printf x > notes.txt", None),
    ("cd {LAB}; (cd /etc && ls); printf x > rel.txt", None),
    (None, ('Edit', {'file_path': '{LAB}/index.md', 'old_string': 'a', 'new_string': 'b'})),
]


# WARN lines allowed in an index.md block (exact text after "WARN line N Bash: ",
# up to the two spaces before the command excerpt), keyed by a marker that
# identifies the block. Anything else is still a failure.
KNOWN_BLOCK_WARNS = {
    'has() {': {'write to an unresolved variable: $p'},
}


def unexpected_warn(cmd, out):
    allowed = set()
    for marker, texts in KNOWN_BLOCK_WARNS.items():
        if cmd and marker in cmd:
            allowed |= texts
    for m in re.finditer(r'^WARN line \d+ \w+: (.*?)  \[', out, re.M):
        if m.group(1) not in allowed:
            return True
    return re.search(r'^WARN (?!line \d+ \w+: .*?  \[)', out, re.M) is not None


def index_blocks():
    """Every ```bash block of references/index.md (indented ones too)."""
    blocks = []
    for name in ('index.md', 'search-and-answer.md'):
        path = os.path.join(SKILL, 'references', name)
        with open(path, encoding='utf-8') as fh:
            lines = fh.read().split('\n')
        i = 0
        while i < len(lines):
            m = re.match(r'^( *)```bash\s*$', lines[i])
            if not m:
                i += 1
                continue
            ind, body = len(m.group(1)), []
            i += 1
            while i < len(lines) and lines[i].strip() != '```':
                body.append(lines[i][ind:] if lines[i][:ind].strip() == '' else lines[i])
                i += 1
            blocks.append(('%s block %d' % (name, len(blocks) + 1), '\n'.join(body)))
            i += 1
    return blocks


INIT = json.dumps({'type': 'system', 'subtype': 'init'})
RESULT = json.dumps({'type': 'result', 'subtype': 'success', 'result': 'done'})


def tool_event(name, inp):
    return json.dumps({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'tool_use', 'id': 't1', 'name': name, 'input': inp}]}})


def transcript(path, cmd, tool):
    if tool is None:
        tool = ('Bash', {'command': cmd})
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join([INIT, tool_event(tool[0], tool[1]), RESULT]) + '\n')


BASH_OK = tool_event('Bash', {'command': 'ls'})
READ_ONLY = tool_event('Read', {'file_path': '/etc/hosts'})
# Transcripts that are not usable as evidence: (label, content or None for
# /dev/null, extra args, expected exit). content may hold {LAB}.
RAW = [
    ('/dev/null', None, [], 1),
    ('empty file', '', [], 1),
    ('not JSON', '{not-json}\n', [], 1),
    ('truncated last line', INIT + '\n' + BASH_OK + '\n' + RESULT[:20], [], 1),
    ('a bad line in the middle', INIT + '\n' + BASH_OK + '\n{oops\n' + RESULT + '\n', [], 1),
    ('unknown schema', '{"foo": 1}\n{"bar": [2]}\n', [], 1),
    ('a JSON line that is not an object', INIT + '\n[1, 2]\n' + BASH_OK + '\n' + RESULT + '\n', [], 1),
    ('no result event', INIT + '\n' + BASH_OK + '\n', [], 1),
    ('--require-bash with no Bash call', INIT + '\n' + READ_ONLY + '\n' + RESULT + '\n', ['--require-bash'], 1),
    ('no Bash call, flag not given', INIT + '\n' + READ_ONLY + '\n' + RESULT + '\n', [], 0),
    ('--require-bash with a Bash call', INIT + '\n' + BASH_OK + '\n' + RESULT + '\n', ['--require-bash'], 0),
    ('blank lines are fine', '\n' + INIT + '\n\n' + BASH_OK + '\n' + RESULT + '\n\n', [], 0),
]


def run_raw(work, lab, n, content, args):
    if content is None:
        path = os.devnull
    else:
        path = os.path.join(work, 'raw-%d.jsonl' % n)
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(content.replace('{LAB}', lab))
    p = subprocess.run([sys.executable, '-I', AUDIT, path, '--allow', lab] + args,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    return p.returncode, p.stdout


def run(work, lab, n, cmd, tool):
    sub = lambda s: s.replace('{LAB}', lab) if isinstance(s, str) else s
    cmd = sub(cmd)
    if tool:
        tool = (tool[0], {k: sub(v) for k, v in tool[1].items()})
    path = os.path.join(work, 'case-%d.jsonl' % n)
    transcript(path, cmd, tool)
    p = subprocess.run([sys.executable, '-I', AUDIT, path, '--allow', lab],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    return p.returncode, p.stdout


def main():
    work = tempfile.mkdtemp(prefix='which-skill-audit-test-')
    try:
        lab = os.path.join(work, 'lab')
        os.mkdir(lab, 0o700)
        bad, n = 0, 0
        blocks = index_blocks()
        if len(blocks) < 10:
            print('SETUP ERROR: only %d bash blocks found in references/' % len(blocks))
            return 2
        cases = [('must fail', c, t, 1) for c, t in MUST_FAIL]
        cases += [('must pass', c, t, 0) for c, t in MUST_PASS]
        cases += [('must pass (%s)' % name, c, None, 0) for name, c in blocks]
        for kind, cmd, tool, want in cases:
            n += 1
            rc, out = run(work, lab, n, cmd, tool)
            label = (cmd if cmd is not None else '%s %s' % (tool[0], tool[1].get('file_path')))
            label = label.replace('\n', '\\n')[:90]
            warn = (unexpected_warn(cmd, out) if kind.startswith('must pass (')
                    else re.search(r'^WARN ', out, re.M) is not None)
            ok = rc == want and not (want == 0 and warn)
            if not ok:
                bad += 1
                print('NOT OK %s: %s\n  exit %d, expected %d%s\n  %s' % (
                    kind, label, rc, want, ' (has WARN)' if warn else '',
                    out.strip().replace('\n', '\n  ')))
            else:
                print('ok     %s: %s' % (kind, label))
        for label, content, args, want in RAW:
            n += 1
            rc, out = run_raw(work, lab, n, content, args)
            if rc != want:
                bad += 1
                print('NOT OK input (%s): exit %d, expected %d\n  %s' % (
                    label, rc, want, out.strip().replace('\n', '\n  ')))
            else:
                print('ok     input: %s' % label)
        print('%d cases, %d not as expected' % (n, bad))
        if bad:
            print('TEST AUDIT FAILED')
            return 1
        print('TEST AUDIT OK')
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
