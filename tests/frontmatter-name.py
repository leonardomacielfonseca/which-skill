# The effective-name rule of references/index.md ("Effective name"), shared by
# tests/check-index.sh (prepended to its LOC_PY) and tests/test-shortlist-copy.sh
# (prepended to SHADOW_PY), so both read a name the same way. Plain python3,
# no PyYAML: a minimal reader of one YAML scalar, enough for a `name:` line.
#   fm_name(path)   -> the accepted frontmatter name of a SKILL.md, or None
#   ename(path, folder, plugin=None) -> the effective name: fm_name, else folder;
#       for a plugin skill, exactly one own plugin prefix "<plugin>:" is then
#       removed (a foreign prefix is kept)
# A located file is only read as text (at most 64 KiB), never run.
import re as _re
import unicodedata as _ud
try:  # optional: PyYAML, when importable, decides whether the block parses
    import yaml as _yaml
except Exception:
    _yaml = None
_Strict = None
if _yaml is not None:
    try:
        class _Strict(_yaml.SafeLoader):
            """SafeLoader that refuses a repeated key in any mapping."""
            def construct_mapping(self, node, deep=False):
                seen = set()
                for kn, _vn in getattr(node, "value", []):
                    k = self.construct_object(kn, deep=deep)
                    k = k.strip() if isinstance(k, str) else k
                    try:
                        if k in seen:
                            raise ValueError("duplicate key %r" % (k,))
                        seen.add(k)
                    except TypeError:
                        raise ValueError("unhashable key")
                return _yaml.SafeLoader.construct_mapping(self, node, deep=deep)
    except Exception:
        _Strict = None

_ESC = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f",
        "r": "\r", "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85",
        "_": "\xa0", "L": " ", "P": " "}


def _rest_ok(rest):
    rest = rest.strip(" \t")
    return rest == "" or rest.startswith("#")


def yaml_scalar(raw):
    """The value of one `key: value` line. None: no value (empty, ~, null).
    False: not a single-line string scalar YAML would accept (a malformed or
    unterminated quoted scalar, a flow collection, an anchor, a tag, a block
    scalar, junk after a closing quote, `: ` inside a plain scalar)."""
    s = raw.strip(" \t")
    if s == "" or s.startswith("#"):
        return None
    if s[0] == '"':
        out, i = [], 1
        while i < len(s):
            c = s[i]
            if c == "\\":
                i += 1
                if i >= len(s):
                    return False
                e = s[i]
                if e in _ESC:
                    out.append(_ESC[e])
                elif e in "xuU":
                    n = {"x": 2, "u": 4, "U": 8}[e]
                    h = s[i + 1:i + 1 + n]
                    if len(h) != n or not all(ch in "0123456789abcdefABCDEF" for ch in h):
                        return False
                    cp = int(h, 16)
                    if cp > 0x10FFFF:
                        return False
                    out.append(chr(cp))
                    i += n
                else:
                    return False
            elif c == '"':
                return "".join(out) if _rest_ok(s[i + 1:]) else False
            else:
                out.append(c)
            i += 1
        return False
    if s[0] == "'":
        out, i = [], 1
        while i < len(s):
            if s[i] == "'":
                if s[i + 1:i + 2] == "'":
                    out.append("'")
                    i += 2
                    continue
                return "".join(out) if _rest_ok(s[i + 1:]) else False
            out.append(s[i])
            i += 1
        return False
    if s[0] in "[]{}&*!|>%@`," or s in ("-", "?", ":") or s[:2] in ("- ", "? ", ": "):
        return False
    m = _re.search(r"[ \t]#", s)
    v = (s[:m.start()] if m else s).rstrip(" \t")
    if ": " in v or v.endswith(":") or "\t" in v:
        return False
    if v in ("~", "null", "Null", "NULL"):
        return None
    if _TYPED.fullmatch(v):
        return Typed(v)
    return v


class Typed(object):
    """A plain value YAML may read as a bool, null, number or date: valid
    YAML, but never a string, so never a name."""
    def __init__(self, v):
        self.v = v


# Conservative patterns for plain values YAML (1.1 or 1.2) may resolve to a
# non-string: bools and nulls (any case), ints (any [-+]?[0-9]+ as in YAML 1.2
# Core, leading zeros included; binary, octal, hex, sexagesimal), floats (with
# a dot or an exponent, .inf, .nan) and dates.
_TYPED = _re.compile(r"""(?ix)
    (?: true|false|yes|no|on|off|y|n|null|~
      | [-+]?[0-9]+ | [-+]?(?:0|[1-9][0-9_]*)
      | [-+]?0b[01_]+ | [-+]?0x[0-9a-f_]+ | [-+]?0o?[0-7_]+
      | [-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+(?:\.[0-9_]*)?
      | [-+]?[0-9][0-9_]*\.[0-9_]*(?:e[-+]?[0-9]+)?
      | [-+]?\.[0-9][0-9_]*(?:e[-+]?[0-9]+)?
      | [-+]?[0-9][0-9_]*\.?(?:e[-+]?[0-9]+)
      | [-+]?\.inf | \.nan
      | [0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[t\x20].*)?
    )""")


def name_ok(v, plugin=False):
    """Claude Code's refusal list for a command or frontmatter name (docs:
    "Characters a skill name can't hold"), plus the reserved synced prefix
    outside a plugin. The docs set no length limit."""
    if not v:
        return False
    if v[0] == " " or v[-1] == " " or "  " in v:
        return False
    for ch in v:
        if ch in "<>":
            return False
        if ch == " ":
            continue
        cat = _ud.category(ch)
        if cat in ("Cc", "Cf", "Co", "Cn", "Cs", "Zs", "Zl", "Zp"):
            return False
    if not plugin and (v == "anthropic-skills" or v.startswith("anthropic-skills:")):
        return False
    return True


_KEY = _re.compile(r"([A-Za-z0-9_][A-Za-z0-9_.-]*):(?:[ \t]+(.*))?$")
_BLOCK = _re.compile(r"[|>][+-]?")  # no indentation digit, no comment


def _has_flow(v):
    """`[`, `]`, `{` or `}` outside quotes (a flow collection, or text YAML may
    read as one): the simple subset never accepts it."""
    q = None
    for i, c in enumerate(v):
        if q:
            if c == q:
                q = None
        elif c in "\"'" and (i == 0 or v[i - 1] in " \t"):
            q = c
        elif c in "[]{}":
            return True
    return False


def _value_ok(v):
    """A value after `key:` on one line: "block" for a block scalar header,
    True for a scalar (no flow collection) or nothing, else False."""
    v = v.strip(" \t")
    if v == "" or v.startswith("#"):
        return True
    if _BLOCK.fullmatch(v):
        return "block"
    if _has_flow(v):
        return False
    return yaml_scalar(v) is not False


def _simple_ok(lines):
    """The fallback without PyYAML: only a flat block can be `ok`. Every line
    is a top-level plain `key: value` (a scalar without a flow collection, a
    block scalar header `|` or `>` with at most one `-` or `+`, or nothing), a
    blank line of spaces, a comment, or a block scalar body line (after a header, until
    the next column-0 line) indented by exactly the spaces of the first
    non-empty body line. Any other indented line (a nested mapping, a sequence
    item, a continuation, a tab or a different indentation) or `- x` fails."""
    in_block, ind = False, None
    for l in lines:
        if l.strip(" ") == "":  # a blank line holds no tab
            continue
        if l[0] in " \t":
            if not in_block:
                return False
            n = len(l) - len(l.lstrip(" "))
            if ind is None:
                ind = n
            if n == 0 or n != ind:
                return False
            continue
        if l.startswith("#"):
            in_block = False
            continue
        m = _KEY.match(l)
        if not m:
            return False
        r = _value_ok(m.group(2) or "")
        if r is False:
            return False
        in_block, ind = r == "block", None
    return True


def _top_key(l):
    """The normalized top-level key of a column-0 line (quotes and blanks
    around it removed), its form ("plain" for `key:` with no blank before the
    colon, else "other"), or (None, None) for a line that is not a key."""
    if not l or l[0] in " \t#-":
        return None, None
    if l[0] in "\"'":
        j = l.find(l[0], 1)
        if j < 0:
            return None, None
        rest = l[j + 1:].lstrip(" \t")
        return (l[1:j].strip(), "other") if rest.startswith(":") else (None, None)
    m = _re.match(r"([^:]*?)([ \t]*):(?:[ \t]|$)", l)
    if not m:
        return None, None
    return m.group(1).strip().strip("\"'").strip(), ("plain" if m.group(2) == "" else "other")


def _keys_ok(lines):
    """No repeated normalized top-level key, and `name` is either absent or
    exactly one plain `name:` line."""
    seen, names = set(), []
    for l in lines:
        k, form = _top_key(l)
        if k is None:
            continue
        if k in seen:
            return False
        seen.add(k)
        if k == "name":
            names.append(form)
    return names in ([], ["plain"])


def _line_name(lines, plugin=False):
    """The value of the plain `name:` line, read from the text: a string
    Claude Code would accept, else None (a typed plain value such as `true`
    or `123` is no name; a quoted value stays a string)."""
    for l in lines:
        m = _re.match(r"name:(?:[ \t](.*))?$", l)
        if m:
            v = yaml_scalar(m.group(1) or "")
            return v if isinstance(v, str) and name_ok(v, plugin) else None
    return None


def block_info(lines, plugin=False):
    """(status, name) of a first frontmatter block. status: `ok` when it is
    certainly a YAML mapping (PyYAML, when importable, loads it as a mapping
    with no repeated key; without PyYAML, every line passes _simple_ok); a
    repeated normalized top-level key, or a `name` key that is not one plain
    `name:` line, is never `ok`; anything else is `uncertain` (Claude Code may
    have dropped every field). name: with PyYAML and an `ok` block, the loaded
    `name` only when it is a string Claude Code accepts and its text is not a
    plain value YAML may type; otherwise the value of
    the `name:` line read as text (for an `uncertain` block, the would-be
    name)."""
    text_name = _line_name(lines, plugin)
    if not _keys_ok(lines):
        return "uncertain", text_name
    if _yaml is not None and _Strict is not None:
        try:
            data = _yaml.load("\n".join(lines) + "\n", Loader=_Strict)
        except Exception:
            return "uncertain", text_name
        if not isinstance(data, dict):
            return "uncertain", text_name
        # the loaded value must be a string, and the text must not be a plain
        # value another YAML version may type (PyYAML reads YAML 1.1, so
        # `1.5e3` stays a string there but is a number in YAML 1.2)
        v = data.get("name")
        return "ok", (v if isinstance(v, str) and name_ok(v, plugin) and text_name is not None else None)
    return ("ok" if _simple_ok(lines) else "uncertain"), text_name


def block_status(lines):
    return block_info(lines)[0]


def fm_lines(p):
    """The lines of the first frontmatter block of a SKILL.md, or None
    without a closed block."""
    try:
        with open(p, "rb") as fh:
            lines = fh.read(65536).decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    if not lines or lines[0].rstrip() != "---":
        return None
    for i, l in enumerate(lines[1:], 1):
        if l.rstrip() == "---":
            return lines[1:i]
    return None


def fm_info(p, plugin=False):
    """(status, name) of the first frontmatter block of a SKILL.md (see
    block_info); `none` without a closed block."""
    lines = fm_lines(p)
    return ("none", None) if lines is None else block_info(lines, plugin)


_TRUE = r"(?:true|True|TRUE)[ \t]*(?:#.*)?"


def parse_overrides(text):
    """Round 54: the output of the overrides block of index.md, as a dict
    {skill name: set of values}, or None when it did not end with
    OVERRIDES OK (then no skill is manual)."""
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines or lines[-1] != "OVERRIDES OK":
        return None
    ov = {}
    for l in lines[:-1]:
        if l.startswith("OVERRIDE ") and " | " in l:
            k, v = l[len("OVERRIDE "):].rsplit(" | ", 1)
            ov[k] = set(v.split(","))
    return ov


def manual_ok(p, folder, ov):
    """Rounds 53 and 54, **Manual skills** in index.md: a local (user or
    project) SKILL.md whose first frontmatter block is `ok`, with no
    `user-invocable` key other than one plain `user-invocable: true`; the
    overrides (parse_overrides) read without failure and giving neither its
    effective name nor its folder name a value other than on, name-only or
    user-invocable-only; and either exactly one plain top-level
    `disable-model-invocation: true` (true, True or TRUE, unquoted) or an
    override user-invocable-only for one of those names. Such a skill is
    hidden from the model's list but the user can run it. The caller decides
    the source (plugin and claude.ai skills never count)."""
    if ov is None:
        return False
    lines = fm_lines(p)
    if lines is None or block_info(lines)[0] != "ok":
        return False
    ui = [l for l in lines if _re.match(r"user-invocable[ \t]*:", l)]
    if ui and (len(ui) != 1 or not _re.fullmatch(r"user-invocable:[ \t]+" + _TRUE, ui[0])):
        return False
    vals = set()
    for n in {ename(p, folder), folder}:
        vals |= ov.get(n, set())
    if vals - {"on", "name-only", "user-invocable-only"}:
        return False
    if "user-invocable-only" in vals:
        return True
    flag = [l for l in lines if _re.match(r"disable-model-invocation[ \t]*:", l)]
    if len(flag) != 1 or not _re.fullmatch(r"disable-model-invocation:[ \t]+" + _TRUE, flag[0]):
        return False
    if _yaml is not None and _Strict is not None:
        data = _yaml.load("\n".join(lines) + "\n", Loader=_Strict)
        return data.get("disable-model-invocation") is True and data.get("user-invocable", True) is True
    return True


def fm_name(p, plugin=False):
    """The accepted frontmatter name, only when the block is `ok`."""
    st, v = fm_info(p, plugin)
    return v if st == "ok" else None


def aliases(p, folder):
    """For a personal or project skill: (sure, possible) bare names. `sure`
    may be offered as a command: the folder name and an accepted name of an
    `ok` block. `possible` adds the would-be name of an `uncertain` block, so
    an uncertain higher-precedence skill still shadows a lower one."""
    st, v = fm_info(p)
    if not p.endswith("/SKILL.md"):  # a legacy command: its file name only (commands ignore `name`)
        return {folder}, {folder}
    sure = {folder} | ({v} if v and st == "ok" else set())
    return sure, sure | ({v} if v and st == "uncertain" else set())


def ename(p, folder, plugin=None):
    v = fm_name(p, plugin is not None) if p.endswith("/SKILL.md") else None
    if v is None:
        return folder
    if plugin is not None and v.startswith(plugin + ":") and len(v) > len(plugin) + 1:
        v = v[len(plugin) + 1:]
        if not name_ok(v, True):  # the segment left must itself be an acceptable name
            return folder
    return v
