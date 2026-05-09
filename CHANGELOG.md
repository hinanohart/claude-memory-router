# CHANGELOG — claude-memory-router

## v0.1.2 — 2026-05-09

Two pollution sources slipped through v0.1.1 and showed up in the wild
as recurring "Claude got dumb / weird interpretations" symptoms:

### Fixed — filename-only injection (rule "c" removed)

The previous selection lattice had four rules:

```
accept entry IF
       (explicit_hit AND score >= 3)
    OR (fname_boost >= 3 AND inferred_hits >= 1)
    OR (fname_boost >= 6)            ← removed in v0.1.2
    OR (inferred_hits >= 3)
```

Rule (c) was meant to catch "the prompt names a whole filename
phrase, very high confidence." In practice, a `fname_boost = 6`
fired whenever **two** ≥4-character tokens that survived the
stop-word filter both happened to appear in a filename — for
example, `archive` and `2026` for `archive-2026-04-26.md`. The user
need not have mentioned aliases, triggers, or inferred terms; just
having those two tokens anywhere in the prompt was enough to inject
the file. With a memory directory of dozens of date-stamped notes,
this routinely pulled in 100 KiB+ of unrelated files.

v0.1.2 removes rule (c) entirely. Filename naming alone is too weak
a confidence signal. The minimum now is **filename + at least one
inferred hit** (rule b). Orphan rescue continues to be served by
**three or more inferred hits** (rule d, now renumbered c).

### Fixed — ASCII keyword substring match

Aliases, triggers, and inferred terms used `kw.lower() in prompt`,
i.e. plain substring matching. That meant:

- alias `token` matched `tokenizer`, `GITHUB_TOKEN`, `tokenize`
- alias `api` matched `apidocs`, `apiserver`, `napi`
- alias `widget` matched `widgetx`

In a memory file like `feedback_no_token_handling.md` (alias
`token`), any prompt mentioning a tokenizer, env-var-style
identifier, or even casual English text could pull the whole file
in. v0.1.2 changes ASCII keyword matching to **word-boundary**:

```python
re.search(r'(?<![a-z0-9_])' + re.escape(kw_lower) + r'(?![a-z0-9_])', prompt)
```

CJK keywords (anything that doesn't fit `[a-z0-9_-]+`) keep the
substring path, because there are no word boundaries in CJK. So
`議論` still matches inside `議論プロトコル`, but `token` no
longer matches inside `tokenizer`.

### Compatibility

- **Selection rule change is bugfix-shaped**: a user who is
  currently overwhelmed by injections will see fewer, not more,
  files load. Any user who *relied* on the rule-c path (i.e. had
  fully orphan files with no aliases, no triggers, no inferred
  terms, recovered only by their filename matching two tokens of a
  prompt) should run `hooks/memory-router-migrate.sh --apply` to
  add a single inferred alias to those files. Detection oneliner:

  ```bash
  jq -r '.entries[]
    | select((.aliases // []) == [] and (.triggers // []) == []
             and (.inferred_aliases // []) | length < 1)
    | .file' .manifest.json
  ```

- **Word-boundary change**: ASCII aliases that previously matched
  fragments of compound words now don't. This will reduce noise for
  the vast majority. Users who want the old behaviour for a
  specific alias can add the prefix/suffix variant explicitly to
  the file's `aliases:` (e.g. `[token, tokenize, tokenized]`).

- No environment-variable changes, no manifest schema changes, no
  install path changes. `hooks/memory-router-builder.sh` does not
  need to be re-run.

### Tests

`tests/test_router.bats` adds:

- `v0.1.2 BOUNDARY` block — substring-only matches must reject
- `v0.1.2 NO_FNAME6` block — filename-alone injection is gone

## v0.1.1 — 2026-05-08

Hardening release after the initial v0.1.0 publish.

- **Security**: realpath-confine `add_file` to `CLAUDE_MEMORY_DIR`,
  reject `..` / absolute paths in `CLAUDE_MEMORY_ROUTES`, mode-600
  `.bak` files, atomic temp-file replace.
- **Logic**: dedupe filename-boost tokens (`foo foo foo` cannot
  fabricate boost=9), localize `nocasematch` to the keyword `case`
  block.
- **Docs**: SECURITY.md updated for MultiEdit / NotebookEdit /
  filesystem confinement / `.bak` retention.

## v0.1.0 — 2026-05-08

Initial public release. Four selection rules, manifest builder,
size monitor, migration script, bats regression suite.
