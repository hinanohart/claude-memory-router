# Orphan file (no frontmatter)

This file deliberately omits frontmatter. The builder should still index
it via filename-derived `inferred_aliases`, but the router's selection
rules require multiple inferred matches OR a filename-token boost
before injecting it — so a single generic keyword in the prompt should
NOT pull this file in.
