#!/bin/bash
# claude-memory-router — frontmatter migration helper
#
# For every *.md in CLAUDE_MEMORY_DIR that has no frontmatter (or is
# missing `aliases:` / `triggers:`), this script proposes a minimum
# frontmatter block derived from filename + first H1 heading.
#
# By default the script runs in --dry-run mode and prints suggestions
# to stdout. Pass --apply to write the headers in place. A single .bak
# is created next to each modified file.
#
# License: MIT
#
# Usage:
#   bash memory-router-migrate.sh                     # show suggestions
#   bash memory-router-migrate.sh --apply             # write headers
#   bash memory-router-migrate.sh --apply --force     # overwrite existing aliases
#
# Environment:
#   CLAUDE_MEMORY_DIR (required)

set -euo pipefail

: "${CLAUDE_MEMORY_DIR:?CLAUDE_MEMORY_DIR must be set}"

APPLY=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --force) FORCE=1 ;;
        --help|-h)
            sed -n '2,/^$/p' "$0"
            exit 0
            ;;
    esac
done

PYTHONIOENCODING=utf-8 \
APPLY_ENV="$APPLY" FORCE_ENV="$FORCE" \
python3 - "$CLAUDE_MEMORY_DIR" <<'PY'
"""Suggest or apply minimum frontmatter for orphan memory files.

Heuristic for `aliases`:
  - filename stem split by [-_] gives candidate tokens
  - first H1 heading split by whitespace gives more candidates
  - keep tokens with len >= 3 that are not in a small generic-stop list
  - de-duplicate, cap at 6
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import Iterable

memory_dir = Path(sys.argv[1])
apply = os.environ.get("APPLY_ENV", "0") == "1"
force = os.environ.get("FORCE_ENV", "0") == "1"

GENERIC_STOP = {
    "memory", "project", "system", "notes", "log", "logs", "doc", "docs",
    "todo", "draft", "wip", "tmp", "test", "tests", "main", "common",
    "the", "and", "for", "with", "from", "into", "this", "that",
    "の", "を", "が", "は", "に", "で", "と", "も", "や",
}


def candidates(stem: str, h1: str) -> list[str]:
    raw = re.split(r"[\s\-_,;:/／()（）\[\]]+", f"{stem} {h1}")
    seen: set[str] = set()
    out: list[str] = []
    for r in raw:
        t = r.strip().lower()
        if not t or len(t) < 3 or t.isdigit() or t in GENERIC_STOP:
            continue
        if re.match(r"^\d{4}([-/]\d{1,2}){0,2}$", t):
            continue
        if t in seen:
            continue
        seen.add(t)
        out.append(t)
        if len(out) >= 6:
            break
    return out


def first_h1(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return ""


def has_frontmatter(text: str) -> bool:
    return text.startswith("---\n")


def has_field(text: str, field: str) -> bool:
    if not has_frontmatter(text):
        return False
    try:
        end = text.index("\n---\n", 4)
    except ValueError:
        return False
    return any(line.startswith(f"{field}:") for line in text[4:end].splitlines())


changed = 0
total = 0

for md in sorted(memory_dir.glob("*.md")):
    if md.name.startswith("."):
        continue
    total += 1
    text = md.read_text(encoding="utf-8", errors="replace")
    needs_aliases = not has_field(text, "aliases") or force

    if has_frontmatter(text) and not needs_aliases:
        continue

    h1 = first_h1(text)
    aliases = candidates(md.stem, h1)
    if not aliases:
        print(f"SKIP no-candidates: {md.name}", file=sys.stderr)
        continue

    if has_frontmatter(text):
        # add aliases line to existing frontmatter
        try:
            end = text.index("\n---\n", 4)
        except ValueError:
            print(f"SKIP malformed-frontmatter: {md.name}", file=sys.stderr)
            continue
        head = text[: end]
        body = text[end:]
        addition = f"\naliases: [{', '.join(aliases)}]"
        new_text = head + addition + body
    else:
        # synthesize a fresh frontmatter block
        title = md.stem.replace("_", " ").replace("-", " ")
        block = (
            "---\n"
            f"name: {h1 or title}\n"
            f"description: (auto-generated; please review)\n"
            "type: project\n"
            f"aliases: [{', '.join(aliases)}]\n"
            "triggers: []\n"
            "---\n\n"
        )
        new_text = block + text

    if apply:
        # v0.1.1: keep .bak readable only by owner, write atomically
        bak = md.with_suffix(md.suffix + ".bak")
        if not bak.exists():
            bak.write_text(text, encoding="utf-8")
            try:
                os.chmod(bak, 0o600)
            except OSError:
                pass
        tmp = md.with_suffix(md.suffix + f".tmp.{os.getpid()}.{os.urandom(4).hex()}")
        try:
            tmp.write_text(new_text, encoding="utf-8")
            try:
                os.chmod(tmp, 0o600)
            except OSError:
                pass
            tmp.replace(md)
        finally:
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass
        changed += 1
        print(f"APPLIED: {md.name}  aliases={aliases}")
    else:
        print(f"SUGGEST: {md.name}  aliases={aliases}")

if apply:
    print(f"\n# applied frontmatter to {changed}/{total} files")
else:
    print(f"\n# dry-run: {total} files scanned. Re-run with --apply to write.")
PY
