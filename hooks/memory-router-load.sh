#!/bin/bash
# claude-memory-router — UserPromptSubmit hook
#
# Routes the Claude Code prompt to the most relevant memory files.
# Designed to avoid the "context pollution" failure mode where a single
# generic keyword match triggers a flood of unrelated memory injections.
#
# License: MIT
#
# Usage (settings.json):
#   "hooks": {
#     "UserPromptSubmit": [{
#       "matcher": "",
#       "hooks": [{
#         "type": "command",
#         "command": "bash <repo>/hooks/memory-router-load.sh",
#         "timeout": 5
#       }]
#     }]
#   }
#
# Environment (with sensible defaults):
#   CLAUDE_MEMORY_DIR             — directory of memory files (*.md)
#   CLAUDE_MEMORY_LOG_DIR         — log directory (default: $CLAUDE_MEMORY_DIR/.logs)
#   CLAUDE_MEMORY_MANIFEST        — manifest.json path (default: $CLAUDE_MEMORY_DIR/.manifest.json)
#   CLAUDE_MEMORY_STOP_WORDS      — stop word file (one token per line; comments via #)
#   CLAUDE_MEMORY_ALLOW_3CHAR     — 3-character allowlist file
#   CLAUDE_MEMORY_ROUTES          — user-defined hardcode routes file (key=value lines)
#   CLAUDE_MEMORY_MAX_BYTES       — total injected context cap (default: 204800 = 200 KiB)
#   CLAUDE_MEMORY_TOP_N           — top N files to inject from manifest match (default: 2)
#   CLAUDE_MEMORY_PIN             — colon-separated relative file paths always injected
#                                   (default: critical-rules.md if present)

set -euo pipefail
# v0.1.1: do NOT enable nocasematch globally — `case "$ADDED_PATHS"`
# duplicate-detection must remain case-sensitive on Linux. We toggle it
# only around the keyword `case` blocks where we want flexible matching.

# --- Defaults ---------------------------------------------------------------
: "${CLAUDE_MEMORY_DIR:?CLAUDE_MEMORY_DIR must be set (path to memory directory)}"
: "${CLAUDE_MEMORY_LOG_DIR:=$CLAUDE_MEMORY_DIR/.logs}"
: "${CLAUDE_MEMORY_MANIFEST:=$CLAUDE_MEMORY_DIR/.manifest.json}"
: "${CLAUDE_MEMORY_STOP_WORDS:=}"
: "${CLAUDE_MEMORY_ALLOW_3CHAR:=}"
: "${CLAUDE_MEMORY_ROUTES:=}"
: "${CLAUDE_MEMORY_MAX_BYTES:=204800}"
: "${CLAUDE_MEMORY_TOP_N:=2}"
: "${CLAUDE_MEMORY_PIN:=critical-rules.md}"

mkdir -p "$CLAUDE_MEMORY_LOG_DIR"
chmod 700 "$CLAUDE_MEMORY_LOG_DIR" 2>/dev/null || true

LOG="$CLAUDE_MEMORY_LOG_DIR/router.log"
[[ -f "$LOG" ]] || { touch "$LOG"; chmod 600 "$LOG" 2>/dev/null || true; }

TS=$(date '+%Y-%m-%d %H:%M:%S')

# --- Read prompt from stdin (Claude Code hook protocol) --------------------
INPUT=$(cat 2>/dev/null || true)
PROMPT=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("prompt", ""))
except Exception as e:
    sys.stderr.write(f"router: prompt parse failed: {e}\n")
    print("")
' 2>>"$LOG")

# --- Collected files ---------------------------------------------------------
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

ADDED_PATHS=""
ADDED_NAMES=""
ADDED_BYTES=0
TRUNCATED_FILES=""

add_file() {
    # v0.1.1 hardening:
    #   - reject path traversal segments ("..") in the input
    #   - resolve symlinks and confine the resolved path to CLAUDE_MEMORY_DIR
    #   - keep duplicate-detection case-sensitive (nocasematch is not enabled here)
    local path="$1"
    case "$path" in
        *..*) echo "[$TS] reject_traversal: $path" >> "$LOG"; return 0 ;;
    esac
    case "$ADDED_PATHS" in *"|${path}|"*) return 0 ;; esac

    local real_dir real_path
    real_dir=$(cd "$CLAUDE_MEMORY_DIR" 2>/dev/null && pwd -P) || return 0
    real_path=$(readlink -f -- "$path" 2>/dev/null || echo "")
    if [[ -z "$real_path" ]]; then
        return 0
    fi
    case "$real_path" in
        "$real_dir"/*|"$real_dir") ;;
        *)
            echo "[$TS] reject_outside_dir: $(basename "$path")" >> "$LOG"
            return 0
            ;;
    esac

    if [[ -r "$real_path" ]]; then
        local fsize
        fsize=$(wc -c < "$real_path" 2>/dev/null || echo 0)
        if [[ $((ADDED_BYTES + fsize)) -gt $CLAUDE_MEMORY_MAX_BYTES ]]; then
            TRUNCATED_FILES="${TRUNCATED_FILES} $(basename "$real_path")"
            echo "[$TS] truncated: $(basename "$real_path") (cumulative cap)" >> "$LOG"
            return 0
        fi
        printf '\n\n=== %s ===\n' "${real_path#"$real_dir/"}" >> "$TMP"
        cat "$real_path" >> "$TMP"
        ADDED_PATHS="${ADDED_PATHS}|${real_path}|"
        ADDED_NAMES="${ADDED_NAMES}$(basename "$real_path"), "
        ADDED_BYTES=$((ADDED_BYTES + fsize))
    fi
}

# --- 1. Pinned files (always injected) -------------------------------------
IFS=':' read -ra PIN_FILES <<< "$CLAUDE_MEMORY_PIN"
for pf in "${PIN_FILES[@]}"; do
    [[ -z "$pf" ]] && continue
    add_file "$CLAUDE_MEMORY_DIR/$pf"
done
AUX_START_MARK=$(wc -c < "$TMP")

# --- 2. User-defined hardcode routes ---------------------------------------
# routes file format: lines of  pattern|file1,file2,...
# pattern is a bash glob (e.g. *deploy*|*release* or *paper*|*manuscript*)
if [[ -n "$CLAUDE_MEMORY_ROUTES" && -r "$CLAUDE_MEMORY_ROUTES" ]]; then
    # case-insensitive only inside this block; restored on exit.
    shopt -s nocasematch
    while IFS='|' read -r pattern files; do
        [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
        case "$PROMPT" in
            $pattern)
                IFS=',' read -ra fs <<< "$files"
                for f in "${fs[@]}"; do
                    f="${f// /}"
                    [[ -z "$f" ]] && continue
                    # v0.1.1: reject absolute paths and traversal in routes file
                    case "$f" in
                        /*|*..*)
                            echo "[$TS] reject_route: $f" >> "$LOG"
                            continue
                            ;;
                    esac
                    add_file "$CLAUDE_MEMORY_DIR/$f"
                done
                ;;
        esac
    done < "$CLAUDE_MEMORY_ROUTES"
    shopt -u nocasematch
fi

# --- 3. Manifest-driven routing --------------------------------------------
AUX_PRE_MANIFEST=$(wc -c < "$TMP")
MANIFEST_HITS=""

if [[ -r "$CLAUDE_MEMORY_MANIFEST" && -n "$PROMPT" ]]; then
    MANIFEST_MATCHES=$(
        CLAUDE_MEMORY_DIR_ENV="$CLAUDE_MEMORY_DIR" \
        CLAUDE_MEMORY_TOP_N_ENV="$CLAUDE_MEMORY_TOP_N" \
        CLAUDE_MEMORY_ALLOW_3CHAR_ENV="$CLAUDE_MEMORY_ALLOW_3CHAR" \
        python3 - "$CLAUDE_MEMORY_MANIFEST" "$PROMPT" "$ADDED_PATHS" <<'PY' 2>>"$LOG" || { echo "[$TS] manifest_python_error" >> "$LOG"; true; }
"""Manifest-driven routing.

Selection rules — accept entry if any of:
  (a) explicit_hit AND score >= 3                 alias/trigger match
  (b) filename_boost >= 3 AND inferred_hits >= 1  file name + token match
  (c) filename_boost >= 6                         multiple file name tokens
  (d) inferred_hits >= 3                          multi-token signal

Generic 1-hit matches (e.g. a single common keyword in inferred_aliases)
are intentionally rejected — they are the most frequent source of noise.

Returns: top-N rows of "<path>\\t<score>\\t<file>\\t<matched_keywords>"
"""
import json
import os
import re
import sys

manifest_path = sys.argv[1]
prompt = sys.argv[2][:102400].lower()  # cap at 100 KiB to bound work
added = sys.argv[3]

memory_dir = os.environ.get("CLAUDE_MEMORY_DIR_ENV", "")
top_n = int(os.environ.get("CLAUDE_MEMORY_TOP_N_ENV", "2"))
allow_3char_path = os.environ.get("CLAUDE_MEMORY_ALLOW_3CHAR_ENV", "")

# 3-char allowlist (load once)
allow_3char: set[str] = set()
if allow_3char_path and os.path.isfile(allow_3char_path):
    with open(allow_3char_path, encoding="utf-8") as f:
        for line in f:
            t = line.strip().lower()
            if t and not t.startswith("#") and len(t) == 3:
                allow_3char.add(t)

# Generic "do not boost on filename match" tokens
FNAME_STOP = {
    "github", "claude", "code", "task", "status", "agent", "tool", "file",
    "this", "that", "with", "from", "into", "memory", "project", "system",
    "test", "tests", "main", "default", "config", "build", "install",
}

try:
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    sys.stderr.write(f"router: manifest load failed: {e}\n")
    sys.exit(0)

# v0.1.2: word boundary match for ASCII keywords, substring for CJK.
# Prevents 'token' alias from matching 'tokenizer' or compound prompts
# where the alias is a fragment of a larger English word. CJK keywords
# keep substring match because there are no word boundaries in CJK text.
_ASCII_KW_RE = re.compile(r'^[a-z0-9_\-]+$')

def _kw_match(kw_lower: str, prompt: str) -> bool:
    if not kw_lower:
        return False
    if _ASCII_KW_RE.match(kw_lower):
        pattern = r'(?<![a-z0-9_])' + re.escape(kw_lower) + r'(?![a-z0-9_])'
        return re.search(pattern, prompt) is not None
    return kw_lower in prompt

results: list[tuple[int, str, str, list[str]]] = []

for entry in manifest.get("entries", []):
    fpath = entry.get("path") or os.path.join(memory_dir, entry.get("file", ""))
    if not fpath or f"|{fpath}|" in added:
        continue
    fname = entry.get("file", "")
    # Always-skip: these get pinned by CLAUDE_MEMORY_PIN and MEMORY index files
    if fname in {"MEMORY.md", "critical-rules.md"}:
        continue

    score = 0
    matched: list[str] = []
    explicit_hit = False
    inferred_hits = 0

    for kw in entry.get("aliases", []) or []:
        if kw and len(kw) >= 2 and _kw_match(kw.lower(), prompt):
            score += 5
            matched.append(kw)
            explicit_hit = True
    for kw in entry.get("triggers", []) or []:
        if kw and len(kw) >= 2 and _kw_match(kw.lower(), prompt):
            score += 3
            matched.append(kw)
            explicit_hit = True
    for kw in entry.get("inferred_aliases", []) or []:
        if kw and len(kw) >= 3 and _kw_match(kw.lower(), prompt):
            score += 1
            matched.append(kw)
            inferred_hits += 1

    # filename boost: prompt token literally appears in file name.
    # v0.1.1: dedupe tokens before scoring so 'sandbox sandbox sandbox'
    # cannot fabricate boost=9.
    fname_lower = fname.lower()
    fname_boost = 0
    seen_tokens: set[str] = set()
    for raw_token in re.split(r"[\s,，、。:;:/／()（）\[\]【】\-_]+", prompt):
        token = raw_token.strip().lower()
        if not token or token in FNAME_STOP or token in seen_tokens:
            continue
        seen_tokens.add(token)
        if len(token) >= 4 or (len(token) == 3 and token in allow_3char):
            if token in fname_lower:
                fname_boost += 3
                if token not in (m.lower() for m in matched):
                    matched.append(token)
    score += fname_boost

    # v0.1.2: removed `(fname_boost >= 6)` rule. Two 4-char tokens that just
    # appear in a filename (e.g. `hinata` + `2026` for `hinata-2026-04-26.md`)
    # were enough to inject the file even with zero alias/trigger/inferred
    # hits. Filename naming alone is too weak a confidence signal —
    # filename + at least one inferred hit (rule b) is the minimum.
    # Orphan rescue is still served by `inferred_hits >= 3`.
    if (explicit_hit and score >= 3) \
            or (fname_boost >= 3 and inferred_hits >= 1) \
            or (inferred_hits >= 3):
        results.append((score, fpath, fname, matched[:3]))

results.sort(key=lambda x: -x[0])
for score, fpath, fname, matched in results[:top_n]:
    print(f"{fpath}\t{score}\t{fname}\t{','.join(matched)}")
PY
    )
    if [[ -n "$MANIFEST_MATCHES" ]]; then
        while IFS=$'\t' read -r path score fname kws; do
            [[ -z "$path" ]] && continue
            add_file "$path"
            MANIFEST_HITS="${MANIFEST_HITS}${fname}(s${score}:${kws}) "
        done <<< "$MANIFEST_MATCHES"
    fi
fi

# --- 4. Determine FALLBACK_REASON ------------------------------------------
AUX_END=$(wc -c < "$TMP")
AUX_BYTES=$((AUX_END - AUX_START_MARK))
PRE_MANIFEST_BYTES=$((AUX_PRE_MANIFEST - AUX_START_MARK))

if [[ "$AUX_BYTES" -eq 0 ]]; then
    FALLBACK_REASON="no_match"
elif [[ "$PRE_MANIFEST_BYTES" -eq 0 ]] && [[ -n "$MANIFEST_HITS" ]]; then
    FALLBACK_REASON="manifest_only"
elif [[ -n "$MANIFEST_HITS" ]]; then
    FALLBACK_REASON="routes+manifest"
else
    FALLBACK_REASON="routes_matched"
fi

# --- 5. Emit JSON for Claude Code -----------------------------------------
SUMMARY="AUTO-LOADED MEMORY ($FALLBACK_REASON): ${ADDED_NAMES%, }"
[[ -n "$TRUNCATED_FILES" ]] && SUMMARY="${SUMMARY} [size-limited:${TRUNCATED_FILES}]"
[[ -n "$MANIFEST_HITS" ]] && SUMMARY="${SUMMARY} [manifest-matched: ${MANIFEST_HITS%% }]"

echo "[$TS] $SUMMARY" >> "$LOG"

HEADER="$SUMMARY
(Tip: this is a compressed view; if precision matters, Read the file directly.)"
{
    printf '%s' "$HEADER"
    cat "$TMP"
} | python3 -c '
import json, sys
content = sys.stdin.read()
out = {
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": content,
    }
}
print(json.dumps(out, ensure_ascii=False))
'
