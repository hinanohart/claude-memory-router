# Security and privacy posture

This document describes the threat model the project assumes, the
defensive design choices, and the user-side configuration we
recommend you apply on top of installing the hook.

## Threat model

The hook runs in your local shell as part of every Claude Code prompt.
Two failure classes matter most:

1. **Context pollution** — promiscuous keyword matching injects
   unrelated memory into the prompt, degrading Claude's attention and
   causing the model to drift off-task. This is the primary problem
   the router exists to solve.
2. **Self-modification by prompt injection** — a malicious prompt
   convinces Claude to use the `Edit` / `Write` / `Bash` tool against
   the hook itself, gutting the protection. This is a defense-in-depth
   concern; the router does not introduce the vulnerability, but it
   provides templates for closing it.

## What the hook itself does

- Logs are created `chmod 600`. Their directory is created `chmod 700`.
- Only filenames and matched keywords appear in logs; the raw prompt is
  never written.
- The Python parsing block receives the prompt via `argv`, not
  interpolation, so a hostile prompt cannot inject code.
- All hook scripts use `set -euo pipefail` and validate
  `CLAUDE_MEMORY_DIR` before doing anything.
- Manifest writes are atomic (`tmpfile.replace(out)` after `chmod 600`).

## Recommended Claude Code settings

Edit/Write tool deny entries are the single most effective addition.
They prevent a prompt-injected Claude from rewriting the hook scripts
out from under you. Add the following to the `permissions.deny` array
in `~/.claude/settings.json`:

```json
"Edit(~/path/to/claude-memory-router/**)",
"Write(~/path/to/claude-memory-router/**)",
"Edit(~/.claude/hooks/**)",
"Write(~/.claude/hooks/**)",
"Edit(~/.claude/agents/**)",
"Write(~/.claude/agents/**)",
"Edit(~/.claude/skills/**)",
"Write(~/.claude/skills/**)"
```

If you also want to block `Bash`-tool redirection into those paths,
add a `PreToolUse(Bash)` hook with regex matching
`(>|>>|tee|sed -i|truncate|install) … (.claude/(hooks|agents|skills)/…\.(sh|py|json|md))`.
Mind that legitimate writes to a `logs/` or `tests/` subdirectory
should be allowed through.

## Recommended Read-tool guard

The `Read` tool in Claude Code can be guarded with a `PreToolUse(Read)`
hook that denies reading files that look like credentials. We recommend
also denying reads of the hook scripts themselves, so a prompt-injected
Claude cannot first reconnoitre the rules it intends to bypass. A
deny-pattern like `\.claude/hooks/[^/]*\.(sh|py|json)$` is sufficient.

## Memory hygiene

The hook will not make a bloated memory directory healthy on its own.
Run `memory-router-size-monitor.sh` periodically. Threshold defaults
are conservative; tune via the `CLAUDE_MEMORY_MAX_*` environment
variables once you understand your own tolerance.

## Reporting issues

Please open a GitHub issue with the smallest reproducer you can share.
Do not paste real memory file contents into a public issue; reduce the
problem to synthetic fixtures under `tests/fixtures/`.
