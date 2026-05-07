# Design notes

## The failure mode in one paragraph

Imagine a memory directory of 90 files. Most are project notebooks; a
handful carry frontmatter, the rest do not. When the manifest builder
falls back to deriving keywords from a file's `name` and `description`,
generic dev tokens — `api`, `github`, `claude`, `code`, `agent`,
`task`, `status` — end up sprinkled across half of all files'
`inferred_aliases`. The router is then asked to score "the prompt
contains `api`": every file that mentions `api` in its description
fires for one point. With a permissive selection rule (`score > 0`,
top-3 wins), three unrelated files are injected into every prompt.
The model attends to that injected context and starts answering as
though those files were the topic. **Routing precision collapses
silently. Recall is near-1.**

## The fix in one paragraph

Treat `inferred_aliases` as a weak signal. **One** inferred hit is
not enough — period. Either the prompt has to clear an explicit alias
or trigger (frontmatter, human-curated, weight 5 / 3), or it has to
clear a structural threshold: filename token literally appears in the
file name (weight 3 per token), or three or more inferred tokens fire
together. Add an aggressive stop-word list and a 3-character
allowlist, regenerate the manifest, and noise drops to zero on the
test fixtures while the orphan recovery path still works.

## Score table

| Source | Per-hit weight | Selection contribution |
| --- | --- | --- |
| `aliases` (frontmatter) | +5 | sets `explicit_hit = True` |
| `triggers` (frontmatter) | +3 | sets `explicit_hit = True` |
| filename token (≥ 4 chars, or ≥ 3 in allowlist, not in fname-stop list) | +3 per token | accumulates into `fname_boost` |
| `inferred_aliases` (auto) | +1 | accumulates into `inferred_hits` |

Acceptance:

```text
accept entry IF
        (explicit_hit AND score >= 3)
     OR (fname_boost >= 3 AND inferred_hits >= 1)
     OR (fname_boost >= 6)
     OR (inferred_hits >= 3)
```

The first rule is the curated path. The second covers frontmatter-less
files with at least some keyword agreement. The third covers a prompt
that names a file's whole filename phrase (very high confidence). The
fourth is the residual multi-keyword case for orphan files where users
have not yet written aliases.

## Why not just `score >= N` with one threshold?

Because there is no value of `N` that simultaneously rejects 1-hit
generic noise and accepts orphan files. `N=1` is the original
pollution. `N=3` (with no other path) makes orphan files unreachable
forever. The lattice above is what makes both invariants hold.

## Why a separate `fname_boost`?

A filename match is qualitatively different from a description match:
the prompt has named the file's identity, not just one of many topics
it discusses. Keeping the two signals separate lets us require
"filename + at least something else" without inflating the score
threshold globally.

## Stop words and 3-character allowlist

The built-in stop-word set includes ~150 tokens — Japanese particles,
English determiners and prepositions, file extensions, and the dev
vocabulary that turned out to be the noise generators in practice.
Extend it via `CLAUDE_MEMORY_STOP_WORDS=path/to/file`.

The 3-character allowlist exists so that real abbreviations
(`oss`, `wsl`, `mcp`, `kvm`, `rag`, `api`-when-you-want-it) survive
the "len < 3 prune" without forcing us to lower the global threshold.

## Why bash + python inline?

Two practical reasons:

1. The Claude Code hook protocol delivers JSON on stdin and expects
   JSON on stdout. Doing the prompt parse and the manifest score
   computation in Python inline (heredoc) avoids spawning two
   processes and keeps timeout headroom under the default 5 seconds.
2. Bash + Python is part of every Claude Code installation already.
   No additional dependencies, no PyPI install step, no wheel build
   for users behind restrictive firewalls.

## What this design does *not* try to be

- **Not** a generic search engine. We do TF-IDF-shaped scoring on a
  small dictionary, not BM25 on the file bodies.
- **Not** an MCP server. The Claude Code `UserPromptSubmit` hook
  delivers exactly the API surface needed; an MCP server would add
  process boundaries without buying anything.
- **Not** a substitute for writing frontmatter. Routing precision is
  capped above by the quality of `aliases` and `triggers`. The
  migration helper is there to bootstrap that work, not to replace it.
