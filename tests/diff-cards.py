#!/usr/bin/env python3
"""Compare two index files card by card (key = '## ' heading).
Usage: tests/diff-cards.py before.md after.md
Prints added, removed and changed cards, whether the header changed, and any
duplicate card headings (a duplicate is reported, never collapsed), and the
project cards grouped by project root (legacy 'project/<name>' keys apart).
Exit 1 when either file has a duplicate heading."""
import sys

def cards(path):
    head, out, key, order, dups = [], {}, None, [], []
    for line in open(path, encoding="utf-8"):
        if line.startswith("## "):
            key = line.strip()
            if key in out:
                dups.append(key)
                key = "%s  [duplicate %d]" % (key, dups.count(key) + 1)
            order.append(key); out[key] = [line]
        elif key is None:
            head.append(line)
        else:
            out[key].append(line)
    return "".join(head), {k: "".join(v).rstrip("\n") for k, v in out.items()}, order, dups

h1, a, oa, d1 = cards(sys.argv[1]); h2, b, ob, d2 = cards(sys.argv[2])
print("header:", "same" if h1 == h2 else "changed  %r -> %r" % (h1.strip(), h2.strip()))
print("cards: %d -> %d" % (len(oa), len(ob)))
print("duplicates before:", d1)
print("duplicates after:", d2)
print("added:", [k for k in ob if k not in a])
print("removed:", [k for k in oa if k not in b])
ch = [k for k in oa if k in b and a[k] != b[k]]
print("changed:", ch)
same = [k for k in oa if k in b and a[k] == b[k]]
print("byte-identical: %d" % len(same))
print("order kept:", [k for k in ob if k in a] == [k for k in oa if k in b])

def split_key(k):
    """'## <source>/<name>' -> (source, name); the name is after the last '/'.
    A project source is 'project:<absolute root>'; 'project' alone is legacy."""
    k = k.split("  [duplicate")[0][3:]
    src, _, name = k.rpartition("/")
    return src, name

def roots(order):
    out = {}
    for k in order:
        src, name = split_key(k)
        if src == "project":
            out.setdefault("(legacy project/)", []).append(name)
        elif src.startswith("project:"):
            out.setdefault(src[len("project:"):], []).append(name)
    return out

for label, order in (("before", oa), ("after", ob)):
    for root, names in sorted(roots(order).items()):
        print("project cards %s: %s -> %s" % (label, root, sorted(names)))
sys.exit(1 if d1 or d2 else 0)
