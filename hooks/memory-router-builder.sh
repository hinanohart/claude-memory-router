#!/bin/bash
# claude-memory-router — manifest builder
#
# Reads frontmatter (YAML-lite) from every *.md in CLAUDE_MEMORY_DIR and
# emits a manifest.json that the router consults at prompt time. Generic
# stop words (configurable via env or external file) are excluded so that
# auto-derived keywords do not poison routing.
#
# Author: see README.md  License: MIT
#
# Usage:
#   bash <repo>/hooks/memory-router-builder.sh                # rebuild
#   bash <repo>/hooks/memory-router-builder.sh --dry-run      # stdout only
#   bash <repo>/hooks/memory-router-builder.sh --verify       # diff vs existing
#
# Environment (defaults match memory-router-load.sh):
#   CLAUDE_MEMORY_DIR
#   CLAUDE_MEMORY_MANIFEST
#   CLAUDE_MEMORY_STOP_WORDS
#   CLAUDE_MEMORY_ALLOW_3CHAR
#   CLAUDE_MEMORY_LOG_DIR

set -euo pipefail

: "${CLAUDE_MEMORY_DIR:?CLAUDE_MEMORY_DIR must be set}"
: "${CLAUDE_MEMORY_MANIFEST:=$CLAUDE_MEMORY_DIR/.manifest.json}"
: "${CLAUDE_MEMORY_STOP_WORDS:=}"
: "${CLAUDE_MEMORY_ALLOW_3CHAR:=}"
: "${CLAUDE_MEMORY_LOG_DIR:=$CLAUDE_MEMORY_DIR/.logs}"

mkdir -p "$CLAUDE_MEMORY_LOG_DIR"
chmod 700 "$CLAUDE_MEMORY_LOG_DIR" 2>/dev/null || true
LOG="$CLAUDE_MEMORY_LOG_DIR/builder.log"
[[ -f "$LOG" ]] || { touch "$LOG"; chmod 600 "$LOG" 2>/dev/null || true; }

TS=$(date '+%Y-%m-%d %H:%M:%S')

DRY_RUN=0
VERIFY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --verify)  VERIFY=1 ;;
        *) ;;
    esac
done

if ! command -v python3 &>/dev/null; then
    echo "[$TS] FATAL: python3 not found" >> "$LOG"
    exit 1
fi

PYTHONIOENCODING=utf-8 \
CLAUDE_MEMORY_STOP_WORDS_ENV="$CLAUDE_MEMORY_STOP_WORDS" \
CLAUDE_MEMORY_ALLOW_3CHAR_ENV="$CLAUDE_MEMORY_ALLOW_3CHAR" \
python3 - "$CLAUDE_MEMORY_DIR" "$CLAUDE_MEMORY_MANIFEST" "$DRY_RUN" "$VERIFY" "$LOG" "$TS" <<'PY'
"""Manifest builder.

Parses frontmatter (YAML-lite header between the first two `---` lines)
from every Markdown file. For each file we record:
  - explicit aliases / triggers (human-curated, high-quality keywords)
  - inferred_aliases derived from name + description, after stop-word
    and short-token filtering (the noise-prone fallback path; the
    router's selection rules ensure 1-hit matches alone do not load it).
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

memory_dir = Path(sys.argv[1])
out_json = Path(sys.argv[2])
dry_run = sys.argv[3] == "1"
verify = sys.argv[4] == "1"
log_path = Path(sys.argv[5])
ts = sys.argv[6]

# ---------------------------------------------------------------------------
# Stop-word and allowlist loading
# ---------------------------------------------------------------------------

# Compact built-in defaults; users can extend via CLAUDE_MEMORY_STOP_WORDS.
_BUILTIN_STOP: frozenset[str] = frozenset({
    # Japanese particles & morphemes
    "の", "を", "が", "は", "に", "で", "と", "も", "や", "から", "まで",
    "した", "する", "して", "された", "等", "用", "化", "性", "的",
    "ある", "ない", "なる", "なった", "ため", "とき", "こと", "もの",
    # English prepositions / determiners
    "this", "that", "these", "those", "the", "a", "an",
    "and", "or", "but", "for", "with", "by", "to", "of", "in", "on", "at",
    "from", "into", "onto", "upon", "as", "is", "are", "was", "were", "be", "been",
    "do", "does", "did", "have", "has", "had", "will", "would", "can", "could",
    # File extensions
    "md", "json", "yaml", "yml", "py", "sh", "txt", "log", "csv", "tsv",
    "html", "css", "js", "ts", "tsx", "jsx", "rs", "go", "rb",
    # Generic dev tokens that promiscuously match
    "claude", "code", "api", "ai", "llm", "ml", "gpu", "cpu",
    "github", "git", "gitlab", "repo", "repository", "branch", "commit", "commits",
    "tool", "tools", "task", "tasks", "status", "run", "running", "runs",
    "model", "models", "version", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9",
    "file", "files", "dir", "directory", "path", "paths", "config", "configs",
    "system", "systems", "hook", "hooks", "build", "builds", "install", "setup",
    "update", "updated", "fix", "fixed", "bug", "bugs", "issue", "issues",
    "test", "tests", "ci", "cd", "ops",
    # Generic Japanese (frequent in memory descriptions)
    "完成", "完了", "中断", "保留", "開始", "終了", "実行", "着手",
    "実装", "動作", "確認", "検証", "監査", "報告", "結果",
    "設計", "構築", "改修", "拡張", "強化", "削減", "削除", "配置", "移行", "退避",
    "記録", "記述", "説明", "詳細", "概要", "一覧", "索引",
    "全", "全部", "全方位", "一括", "個別", "単独", "全員",
    "ローカル", "リモート", "オンライン", "オフライン",
    "プロジェクト", "システム", "ツール", "サーバー", "クライアント",
    "エージェント", "agent", "agents", "subagent",
    "background", "foreground", "wsl", "linux", "windows", "macos",
    "byte", "bytes", "kb", "mb", "gb", "tb",
    "provider", "providers", "experiments", "experiment", "protocol", "protocols",
    "reward", "rewards", "ablation", "ablations", "multi", "single",
    "pointer", "archive", "archived", "homeserver", "tunnel", "vendor", "vendors",
    "clean", "pass", "passed", "mock", "mocked", "strict",
    "current", "previous", "latest", "next", "final", "initial",
    "input", "output", "result", "results", "sample", "samples",
    "block", "blocks", "phase", "phases", "step", "steps",
    "default", "custom", "common", "generic", "abstract",
    "skill", "skills", "policy", "policies",
})


def _load_external_words(env_name: str) -> set[str]:
    p = os.environ.get(env_name, "")
    if not p or not os.path.isfile(p):
        return set()
    out: set[str] = set()
    with open(p, encoding="utf-8") as f:
        for line in f:
            t = line.strip().lower()
            if t and not t.startswith("#"):
                out.add(t)
    return out


_USER_STOP = _load_external_words("CLAUDE_MEMORY_STOP_WORDS_ENV")
STOP_WORDS = _BUILTIN_STOP | _USER_STOP

_BUILTIN_3CHAR_ALLOW: frozenset[str] = frozenset({
    # generic dev/infra abbreviations only — keep this list neutral.
    # Add domain-specific 3-letter terms via CLAUDE_MEMORY_ALLOW_3CHAR.
    "oss", "wsl", "mcp", "ssh", "tdd", "cli", "gpu", "tpu", "npm", "pip",
    "aws", "gcp", "tcp", "udp", "url", "uri", "yml", "csv", "tsv", "pdf",
    "png", "jpg", "av1", "hdr",
})
_USER_3CHAR_ALLOW = _load_external_words("CLAUDE_MEMORY_ALLOW_3CHAR_ENV")
THREE_CHAR_ALLOW = _BUILTIN_3CHAR_ALLOW | _USER_3CHAR_ALLOW


# ---------------------------------------------------------------------------
# Frontmatter parser (YAML-lite, no PyYAML dependency)
# ---------------------------------------------------------------------------

_TOKEN_SPLIT = re.compile(r"[\s,，、。:;:/／()（）\[\]【】\-_–—『』「」'\"`!\?！？]+")
_NUMERIC_ONLY = re.compile(r"^\d+$")
_DATE_LIKE = re.compile(r"^\d{4}[-/]?\d{1,2}([-/]?\d{1,2})?$")


def parse_frontmatter(text: str) -> dict:
    """Parse the YAML-lite header between the first two `---` lines.

    Supported: scalar `key: value`, quoted strings, inline lists `[a, b]`,
    multi-line lists with `-` prefix, `null`. No nested dicts.
    """
    if not text.startswith("---\n"):
        return {}
    try:
        end = text.index("\n---\n", 4)
    except ValueError:
        return {}
    body = text[4:end]
    fm: dict = {}
    cur_key: str | None = None
    for raw in body.splitlines():
        line = raw.rstrip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*):\s*(.*)$", line)
        if m:
            cur_key = m.group(1)
            val = m.group(2).strip()
            if val == "":
                fm[cur_key] = ""
            elif val.startswith("[") and val.endswith("]"):
                inner = val[1:-1]
                fm[cur_key] = [
                    s.strip().strip('"').strip("'")
                    for s in inner.split(",") if s.strip()
                ]
            elif val == "null":
                fm[cur_key] = None
            else:
                fm[cur_key] = val.strip('"').strip("'")
        elif (line.startswith("  - ") or line.startswith("- ")) and cur_key:
            item = line.split("-", 1)[1].strip().strip('"').strip("'")
            if not isinstance(fm.get(cur_key), list):
                fm[cur_key] = []
            fm[cur_key].append(item)
        elif line.startswith("  ") and cur_key and not isinstance(fm.get(cur_key), list):
            fm[cur_key] = (fm.get(cur_key, "") + " " + line.strip()).strip()
    return fm


# ---------------------------------------------------------------------------
# inferred_aliases derivation
# ---------------------------------------------------------------------------

def _is_stop(t: str) -> bool:
    return t in STOP_WORDS or bool(_NUMERIC_ONLY.match(t)) or bool(_DATE_LIKE.match(t))


def derive_keywords(name: str, description: str, max_n: int = 30) -> list[str]:
    """Tokenize name+description and return up-to max_n discriminative words.

    3-character tokens require explicit allowlist membership (otherwise
    short words like 'oss', 'wsl', 'mcp' would otherwise be pruned).
    """
    text = f"{name} {description}"
    seen: set[str] = set()
    out: list[str] = []
    for raw in _TOKEN_SPLIT.split(text):
        t = raw.strip().lower()
        if not t or len(t) < 3:
            continue
        if len(t) == 3 and t not in THREE_CHAR_ALLOW:
            continue
        if _is_stop(t) or t in seen:
            continue
        seen.add(t)
        out.append(t)
        if len(out) >= max_n:
            break
    return out


# ---------------------------------------------------------------------------
# Build manifest
# ---------------------------------------------------------------------------

entries: list[dict] = []
warnings: list[str] = []

for md in sorted(memory_dir.glob("*.md")):
    if md.name.startswith("."):  # skip hidden / dotfiles
        continue
    try:
        text = md.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        warnings.append(f"read_failed:{md.name}:{e}")
        continue
    fm = parse_frontmatter(text)
    stat = md.stat()
    if not fm or "name" not in fm:
        if md.name not in {"MEMORY.md", "README.md"}:
            warnings.append(f"frontmatter_missing:{md.name}")
        entry = {
            "file": md.name,
            "path": str(md),
            "name": md.stem.replace("_", " ").replace("-", " "),
            "description": "(frontmatter missing — auto-derived from filename)",
            "type": "unknown",
            "aliases": [],
            "triggers": [],
            "last_referenced": "",
            "supersedes": None,
            "size_bytes": stat.st_size,
            "mtime_iso": datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds"),
            "inferred_aliases": derive_keywords(md.stem, ""),
        }
    else:
        explicit_aliases = fm.get("aliases", []) if isinstance(fm.get("aliases"), list) else []
        explicit_triggers = fm.get("triggers", []) if isinstance(fm.get("triggers"), list) else []
        entry = {
            "file": md.name,
            "path": str(md),
            "name": fm.get("name", ""),
            "description": fm.get("description", ""),
            "type": fm.get("type", "unknown"),
            "aliases": explicit_aliases,
            "triggers": explicit_triggers,
            "last_referenced": fm.get("last_referenced", ""),
            "supersedes": fm.get("supersedes", None),
            "size_bytes": stat.st_size,
            "mtime_iso": datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds"),
            "inferred_aliases": derive_keywords(fm.get("name", ""), fm.get("description", "")),
        }
    entries.append(entry)

manifest = {
    "generated_at": datetime.now().isoformat(timespec="seconds"),
    "memory_dir": str(memory_dir),
    "total_files": len(entries),
    "warnings": warnings,
    "entries": entries,
}
manifest_json = json.dumps(manifest, ensure_ascii=False, indent=2)

if verify:
    if not out_json.exists():
        print(f"verify: manifest does not exist at {out_json}", file=sys.stderr)
        sys.exit(2)
    old = json.loads(out_json.read_text(encoding="utf-8"))
    new_files = {e["file"] for e in entries}
    old_files = {e["file"] for e in old.get("entries", [])}
    added = new_files - old_files
    removed = old_files - new_files
    if added or removed:
        print(f"verify: changed (added={len(added)}, removed={len(removed)}, total_now={len(entries)})")
        for f in sorted(added):
            print(f"  + {f}")
        for f in sorted(removed):
            print(f"  - {f}")
    if warnings:
        print(f"verify: {len(warnings)} warnings", file=sys.stderr)
        for w in warnings:
            print(f"  ! {w}", file=sys.stderr)
    sys.exit(0 if (not added and not removed) else 1)

if dry_run:
    print(manifest_json)
    print(f"# total: {len(entries)} entries, {len(warnings)} warnings", file=sys.stderr)
    sys.exit(0)

# Atomic write (PID + ns suffix prevents racing with concurrent builders)
import time
out_json.parent.mkdir(parents=True, exist_ok=True)
tmp = out_json.with_suffix(f".json.new.{os.getpid()}.{time.time_ns()}")
try:
    tmp.write_text(manifest_json + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(out_json)
finally:
    if tmp.exists():
        try:
            tmp.unlink()
        except OSError:
            pass

with log_path.open("a", encoding="utf-8") as f:
    f.write(f"[{ts}] generated total={len(entries)} warnings={len(warnings)}\n")
    for w in warnings:
        f.write(f"[{ts}]   ! {w}\n")

print(f"manifest updated: {len(entries)} entries, {len(warnings)} warnings")
PY
