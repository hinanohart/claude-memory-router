# claude-memory-router

A Claude Code `UserPromptSubmit` hook that **routes the prompt to the
right memory files** instead of carpet-bombing the context with
everything that vaguely matched.

## Why

Claude Code's `~/.claude/projects/<id>/memory/` directory grows quickly.
Once you have 50–100 markdown files, naïve keyword matching has a
characteristic failure mode: a single common word (`api`, `github`,
`claude`, `code`, `agent`, …) appears in dozens of file titles and
descriptions. Every prompt now drags 30–45 KiB of unrelated memory
into Claude's context window, attention drifts away from the task,
and you start seeing **"Claude got dumb / hallucinates / weird
interpretations"**.

This hook fixes that by:

1. **Refusing to load a file on a single 1-hit generic match.** A file
   has to clear at least one of three selection rules (explicit
   alias/trigger, filename + inferred hit, or three-or-more inferred
   hits) before it reaches the prompt.
2. **Treating frontmatter as a first-class signal.** Aliases and
   triggers from a file's YAML header are scored 5× / 3× higher than
   tokens auto-derived from the description.
3. **Pinning what must always load.** A small list of "always include"
   files (e.g. `critical-rules.md`) bypasses routing entirely.
4. **Capping total injection.** Even after routing, total auxiliary
   context is capped (default 200 KiB) so a runaway match cannot push
   the prompt off-screen.

## What's in the box

| File | What it does |
| --- | --- |
| `hooks/memory-router-load.sh` | The `UserPromptSubmit` hook. Reads `manifest.json` and routes the prompt. |
| `hooks/memory-router-builder.sh` | Rebuilds `manifest.json` from frontmatter. Run on demand or via cron. |
| `hooks/memory-router-migrate.sh` | Adds minimal frontmatter (aliases) to orphan memory files. |
| `hooks/memory-router-size-monitor.sh` | Reports memory bloat (file count / size / orphan %) with thresholds. |
| `examples/stop_words.example.txt` | User-extensible stop-word list. |
| `examples/allow_three_char.example.txt` | Allowlist for 3-letter abbreviations (e.g. `kvm`, `rag`). |
| `examples/routes.example.txt` | High-confidence keyword → file routes (bypasses the manifest). |
| `tests/test_router.bats` | bats regression suite (17+ cases). |

## Quickstart

```bash
git clone https://github.com/<your-org>/claude-memory-router.git ~/claude-memory-router
export CLAUDE_MEMORY_DIR=~/.claude/projects/<your-project>/memory
bash ~/claude-memory-router/hooks/memory-router-builder.sh
```

Wire the hook into Claude Code by editing `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "bash ~/claude-memory-router/hooks/memory-router-load.sh",
        "timeout": 5
      }]
    }]
  }
}
```

That's it. Restart your Claude Code session and the next prompt will be
routed.

## Selection rules (the heart of it)

Each manifest entry is scored on four signals:

| Signal | Weight | Notes |
| --- | --- | --- |
| `aliases` (frontmatter) | +5 per hit | curated, high precision |
| `triggers` (frontmatter) | +3 per hit | curated synonyms |
| `inferred_aliases` (auto) | +1 per hit | derived from name/description |
| `filename_boost` | +3 per hit | prompt token literally appears in filename |

An entry is loaded **only if** at least one of:

- **(a)** an explicit alias/trigger fires AND total score ≥ 3
- **(b)** filename boost ≥ 3 AND at least one inferred hit
- **(c)** ≥ 3 inferred hits (multi-token signal — orphan rescue)

Rule (b) is what rescues frontmatter-less files. Rule (a) requires
human-curated keywords for confidence. The crucial thing the rules
*reject* is "one inferred hit, no filename match" — that case is the
overwhelming source of context pollution.

> **v0.1.2:** the previous rule "filename boost ≥ 6 alone" was
> removed. Two 4-character tokens that just appear in a filename
> (e.g. `hinata` + `2026` matching `hinata-2026-04-26.md`) were
> enough to inject the file with zero alias / trigger / inferred
> hits. Filename naming alone proved too weak a confidence signal —
> filename **plus** at least one inferred hit (rule b) is now the
> minimum. Orphan rescue is still served by rule (c).
>
> v0.1.2 also tightens ASCII keyword matching to **word-boundary**
> instead of substring. Aliases like `token` no longer match
> `tokenizer`, `apidocs` no longer fires the `api` alias, and
> compound prompts that incidentally contain a fragment of an alias
> stop dragging in unrelated files. CJK keywords keep substring
> matching since CJK has no word boundaries.

## Configuration

All knobs are environment variables (so the same script can serve
multiple memory directories).

```bash
CLAUDE_MEMORY_DIR              # required: where the *.md files live
CLAUDE_MEMORY_MANIFEST         # default: $CLAUDE_MEMORY_DIR/.manifest.json
CLAUDE_MEMORY_LOG_DIR          # default: $CLAUDE_MEMORY_DIR/.logs
CLAUDE_MEMORY_STOP_WORDS       # path to a one-token-per-line file (optional)
CLAUDE_MEMORY_ALLOW_3CHAR      # path to a 3-char allowlist file (optional)
CLAUDE_MEMORY_ROUTES           # path to high-confidence routes (optional)
CLAUDE_MEMORY_PIN              # colon-separated relative paths, always loaded
CLAUDE_MEMORY_MAX_BYTES        # default 204800 (200 KiB) auxiliary cap
CLAUDE_MEMORY_TOP_N            # default 2 manifest hits to inject
```

## Privacy posture

This project takes seriously the fact that **everything in
`~/.claude/`** — paste cache, file history, sessions, hook logs — is
plaintext by default and persists across restarts.

The hook makes a few choices accordingly:

- Logs are created with mode `600` and stored under `$CLAUDE_MEMORY_LOG_DIR`,
  itself created with mode `700`.
- Only filenames and matched keywords are logged, never raw prompts.
- The Python parsing block uses `argv` (not string interpolation) so a
  prompt cannot inject Python code through the hook.
- Bundled hook companions (see `hooks/memory-router-size-monitor.sh`)
  encourage you to archive old memory rather than let it grow forever.

A reference `settings.json` deny snippet that closes the
Edit/Write-tool path to your hook directory is in
`docs/SECURITY.md`.

## Maintenance loop

Recommended cadence:

| Frequency | Command | Why |
| --- | --- | --- |
| Per session start | `memory-router-size-monitor.sh` | catch bloat before it bites |
| When adding files | `memory-router-builder.sh` | refresh the manifest |
| Monthly | `memory-router-migrate.sh --apply` | keep orphan rate down |
| On regression | `bats tests/` | confirm rules still hold |

## Testing

```bash
# bats >= 1.7
bats tests/test_router.bats
```

The suite covers pinned-file invariants, 1-hit noise rejection, alias
recovery, filename boost, JSON-injection safety on weird prompts, and
manifest-shape assertions. Add your own fixtures under
`tests/fixtures/memory/` and re-run.

## Compatibility

Tested with bash 5.x, Python 3.10+, jq 1.6+. No third-party Python
packages are required (the frontmatter parser is intentionally
YAML-lite to avoid a dependency).

## Companion: `claude-memory-lint`

This router pairs with **[claude-memory-lint](https://github.com/hinanohart/claude-memory-lint)**:

- `claude-memory-router` (this repo, Bash) — **runtime** prompt routing
  via UserPromptSubmit hook; decides which memory files to load for the
  current turn.
- `claude-memory-lint` (Python, SARIF/JSON/text reporters) —
  **compile-time** static analysis of the same memory directory; catches
  frontmatter rot, oversized files, stop-word noise, and rule-shape
  violations before they reach the router at runtime.

Same posture, different timing. Use both for full coverage.

## License

MIT. See `LICENSE`.
