# Contributing

Thanks for considering a contribution.

## Quick rules

1. **No personal data in PRs or issues.** Reduce reproducers to
   synthetic fixtures under `tests/fixtures/memory/`. The fixture
   memory files in this repo are intentionally fictional (widget,
   sandbox, quokka, …).
2. Run `bats tests/test_router.bats` before opening a PR. Add a new
   case for any behaviour you are changing or fixing.
3. `shellcheck hooks/*.sh` and `python3 -m compileall hooks/` should
   both succeed cleanly.
4. Keep the design boundary in `docs/DESIGN.md` honest. If a change
   pushes the project past those boundaries (towards generic search,
   MCP, etc.) please open an issue first to discuss scope.

## Local development

```bash
export CLAUDE_MEMORY_DIR=$(pwd)/tests/fixtures/memory
bash hooks/memory-router-builder.sh
bats tests/test_router.bats
```

## Releasing

The project uses semantic versioning. Tag releases as `vMAJOR.MINOR.PATCH`.
Any change that alters the four selection rules in `docs/DESIGN.md`
constitutes a minor bump (or major if it removes a previously-accepted
case).
