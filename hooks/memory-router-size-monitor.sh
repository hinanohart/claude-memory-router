#!/bin/bash
# claude-memory-router — auto-load size monitor
#
# Run as a SessionStart hook (or manually) to surface memory bloat
# before it degrades Claude's attention. Reports:
#
#   - count of *.md files in CLAUDE_MEMORY_DIR
#   - total bytes
#   - largest file (likely autoload candidate)
#   - count of orphan files (no frontmatter)
#
# Exits non-zero if any threshold is exceeded so you can wire it into
# pre-commit / CI as you wish. Defaults are conservative; tune via env.
#
# License: MIT
#
# Environment:
#   CLAUDE_MEMORY_DIR              (required)
#   CLAUDE_MEMORY_MAX_FILES        default 60
#   CLAUDE_MEMORY_MAX_TOTAL_KB     default 1024
#   CLAUDE_MEMORY_MAX_FILE_KB      default 30
#   CLAUDE_MEMORY_MAX_ORPHAN_PCT   default 50

set -euo pipefail

: "${CLAUDE_MEMORY_DIR:?CLAUDE_MEMORY_DIR must be set}"
: "${CLAUDE_MEMORY_MAX_FILES:=60}"
: "${CLAUDE_MEMORY_MAX_TOTAL_KB:=1024}"
: "${CLAUDE_MEMORY_MAX_FILE_KB:=30}"
: "${CLAUDE_MEMORY_MAX_ORPHAN_PCT:=50}"

PYTHONIOENCODING=utf-8 python3 - "$CLAUDE_MEMORY_DIR" \
    "$CLAUDE_MEMORY_MAX_FILES" "$CLAUDE_MEMORY_MAX_TOTAL_KB" \
    "$CLAUDE_MEMORY_MAX_FILE_KB" "$CLAUDE_MEMORY_MAX_ORPHAN_PCT" <<'PY'
import sys
from pathlib import Path

memory_dir = Path(sys.argv[1])
max_files = int(sys.argv[2])
max_total_kb = int(sys.argv[3])
max_file_kb = int(sys.argv[4])
max_orphan_pct = int(sys.argv[5])

files = [m for m in memory_dir.glob("*.md") if not m.name.startswith(".")]
total_bytes = sum(m.stat().st_size for m in files)
file_count = len(files)

orphans = []
for m in files:
    try:
        text = m.read_text(encoding="utf-8", errors="replace")
    except OSError:
        continue
    if not text.startswith("---\n"):
        orphans.append(m.name)

orphan_pct = (100 * len(orphans) // file_count) if file_count else 0
largest = max(files, key=lambda m: m.stat().st_size, default=None)
largest_kb = (largest.stat().st_size // 1024) if largest else 0

print(f"memory dir: {memory_dir}")
print(f"file count: {file_count} (threshold {max_files})")
print(f"total size: {total_bytes // 1024} KiB (threshold {max_total_kb})")
if largest:
    print(f"largest:    {largest.name} = {largest_kb} KiB (threshold {max_file_kb})")
print(f"orphans:    {len(orphans)} ({orphan_pct}%) (threshold {max_orphan_pct}%)")

failures = []
if file_count > max_files:
    failures.append(f"file count {file_count} > {max_files}")
if total_bytes // 1024 > max_total_kb:
    failures.append(f"total size {total_bytes // 1024} KiB > {max_total_kb}")
if largest_kb > max_file_kb:
    failures.append(f"largest file {largest_kb} KiB > {max_file_kb}")
if orphan_pct > max_orphan_pct:
    failures.append(f"orphan pct {orphan_pct}% > {max_orphan_pct}%")

if failures:
    print("\n⚠️  thresholds exceeded:")
    for f in failures:
        print(f"  - {f}")
    print("\nSuggested actions:")
    print("  - archive old/inactive memory files into a subdirectory")
    print("  - run memory-router-migrate.sh --apply to add aliases")
    print("  - tighten CLAUDE_MEMORY_MAX_BYTES on the router (default 200 KiB)")
    sys.exit(1)

print("\n✅ all thresholds OK")
PY
