#!/usr/bin/env python3
"""Fail if this skill's reference and `tydo help` disagree about the command set.

Usage: check.py [path-to-tydo]   (default: ./.build/release/tydo, else $PATH)
"""
import re, shutil, subprocess, sys
from pathlib import Path

HERE = Path(__file__).parent
STOP = re.compile(r"^[a-z][a-z-]*$")  # a literal word, not <arg>, [opt] or --flag


def paths(text):
    """Every `tydo <cmd> [<sub>]` mentioned, with `a|b` alternatives expanded."""
    out = set()
    for line in re.findall(r"tydo((?: +[^\s`\n|]+(?:\|[^\s`\n|]+)*)+)", text):
        words = []
        for token in line.split():
            alts = [a for a in token.split("|") if STOP.match(a)]
            if not alts:
                break
            words.append(alts)
        if words:
            for head in words[0]:
                out.add((head,) + ((tuple(words[1]),) if len(words) > 1 else ()))
    # flatten the second level
    return {(h, s) for h, *rest in out for s in (rest[0] if rest else (None,))}


tydo = sys.argv[1] if len(sys.argv) > 1 else None
if not tydo:
    local = HERE.parents[2] / ".build/release/tydo"
    tydo = str(local) if local.exists() else shutil.which("tydo")
if not tydo:
    sys.exit("tydo not found; pass its path as an argument")

live = paths(subprocess.run([tydo, "help"], capture_output=True, text=True, check=True).stdout)
live.add(("help", None))  # `help` never lists itself
docs = paths((HERE / "references/cli-reference.md").read_text())

missing = sorted(docs - live)   # documented but gone from the CLI
undocumented = sorted(live - docs)
for label, items in (("documented but not in `tydo help`", missing),
                     ("in `tydo help` but not documented", undocumented)):
    for item in items:
        print(f"{label}: tydo {' '.join(p for p in item if p)}")
print("OK" if not (missing or undocumented) else "MISMATCH", f"({len(live)} commands)")
sys.exit(1 if (missing or undocumented) else 0)
