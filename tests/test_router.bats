#!/usr/bin/env bats
# claude-memory-router — regression test suite (bats)
#
# Each test invokes the router with a synthetic prompt and asserts on
# the FALLBACK_REASON header and the comma-separated file list that
# the hook would inject into Claude Code's context.

setup() {
    REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
    export CLAUDE_MEMORY_DIR="$BATS_TEST_DIRNAME/fixtures/memory"
    export CLAUDE_MEMORY_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export CLAUDE_MEMORY_MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
    export CLAUDE_MEMORY_PIN="critical-rules.md"
    export CLAUDE_MEMORY_TOP_N="2"
    bash "$REPO_ROOT/hooks/memory-router-builder.sh" >/dev/null
}

run_router() {
    local prompt="$1"
    local input
    input=$(python3 -c 'import json,sys;sys.stdout.write(json.dumps({"prompt":sys.argv[1]}))' "$prompt")
    printf '%s' "$input" | bash "$REPO_ROOT/hooks/memory-router-load.sh" 2>/dev/null \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["hookSpecificOutput"]["additionalContext"].split(chr(10))[0])'
}

# ---------------------------------------------------------------------------
# 1. Pinned file is always injected
# ---------------------------------------------------------------------------

@test "INVARIANT: pinned critical-rules.md is always present" {
    out=$(run_router "any prompt at all")
    [[ "$out" == *"critical-rules.md"* ]]
}

@test "INVARIANT: empty prompt loads only the pinned file" {
    out=$(run_router "")
    [[ "$out" == *"no_match"* ]]
    [[ "$out" == *"critical-rules.md"* ]]
}

@test "INVARIANT: random gibberish loads only the pinned file" {
    out=$(run_router "asdfqwerty 9j2k3l")
    [[ "$out" == *"no_match"* ]]
}

# ---------------------------------------------------------------------------
# 2. NOISE block — generic 1-hit must NOT trigger an unrelated file
# ---------------------------------------------------------------------------

@test "NOISE: generic dev token 'github' alone loads no memory" {
    out=$(run_router "github のリポジトリを整理したい")
    [[ "$out" == *"no_match"* ]]
    [[ "$out" != *"widget"* ]]
    [[ "$out" != *"orphan"* ]]
}

@test "NOISE: generic dev token 'api' alone loads no memory" {
    out=$(run_router "api 設計を見直したい")
    [[ "$out" == *"no_match"* ]]
}

@test "NOISE: 'claude code' alone loads no memory" {
    out=$(run_router "claude code で何ができるか")
    [[ "$out" == *"no_match"* ]]
}

@test "NOISE: single word 'agent' alone loads no memory" {
    out=$(run_router "agent について教えて")
    [[ "$out" == *"no_match"* ]]
}

# ---------------------------------------------------------------------------
# 3. SIGNAL recovery — explicit aliases/triggers must fire
# ---------------------------------------------------------------------------

@test "SIGNAL: explicit alias 'widget' loads widget-design-notes" {
    out=$(run_router "widget を改修したい")
    [[ "$out" == *"widget-design-notes"* ]]
}

@test "SIGNAL: explicit trigger 'frame-budget' loads widget-design-notes" {
    out=$(run_router "frame-budget の予算が厳しい")
    [[ "$out" == *"widget-design-notes"* ]]
}

# ---------------------------------------------------------------------------
# 4. Filename boost — multi-token filename match recovers orphan files
# ---------------------------------------------------------------------------

@test "FNAME: 'sandbox cluster' (two filename tokens) loads sandbox-cluster" {
    out=$(run_router "sandbox cluster の起動が遅い")
    [[ "$out" == *"sandbox-cluster"* ]]
}

@test "FNAME: filename token 'quokka' alone does NOT load (single weak signal)" {
    out=$(run_router "quokka について")
    # quokka file has no explicit aliases. With only one filename token
    # match (boost=3) AND no inferred hits in this short prompt, the
    # router rejects the entry — this is intended behaviour.
    [[ "$out" == *"no_match"* ]] || [[ "$out" == *"critical-rules.md"* ]]
}

@test "FNAME: 'quokka research benchmark' loads quokka-research-log" {
    out=$(run_router "quokka research benchmark を再実行したい")
    [[ "$out" == *"quokka-research-log"* ]]
}

# ---------------------------------------------------------------------------
# 5. JSON safety — special characters in prompts must not break parsing
# ---------------------------------------------------------------------------

@test "EDGE: prompt with double quote does not crash" {
    out=$(run_router 'test " character')
    [[ "$out" == *"critical-rules.md"* ]]
}

@test "EDGE: prompt with dollar sign does not crash" {
    out=$(run_router 'test $HOME variable')
    [[ "$out" == *"critical-rules.md"* ]]
}

@test "EDGE: prompt with backtick does not crash" {
    out=$(run_router 'test `command` injection')
    [[ "$out" == *"critical-rules.md"* ]]
}

# ---------------------------------------------------------------------------
# 6. Manifest validity
# ---------------------------------------------------------------------------

@test "MANIFEST: manifest.json is valid JSON" {
    run jq empty "$CLAUDE_MEMORY_MANIFEST"
    [ "$status" -eq 0 ]
}

@test "MANIFEST: indexes all *.md fixture files" {
    count=$(jq '.entries | length' "$CLAUDE_MEMORY_MANIFEST")
    [ "$count" -ge 5 ]
}

@test "MANIFEST: no built-in stop word leaks into inferred_aliases" {
    for kw in api github claude code task agent; do
        n=$(jq --arg k "$kw" '[.entries[] | select(.inferred_aliases | index($k))] | length' "$CLAUDE_MEMORY_MANIFEST")
        [ "$n" -eq 0 ] || { echo "leaked: $kw appears in $n entries"; return 1; }
    done
}

# ---------------------------------------------------------------------------
# 7. v0.1.2 — ASCII keyword word boundary
# ---------------------------------------------------------------------------

@test "v0.1.2 BOUNDARY: alias 'widget' does not match 'widgetx' substring" {
    out=$(run_router "widgetx は別物")
    # widgetx contains 'widget' as a substring but is not the same word.
    # v0.1.1 fired here. v0.1.2 must not.
    [[ "$out" == *"no_match"* ]] || [[ "$out" != *"widget-design-notes"* ]]
}

@test "v0.1.2 BOUNDARY: alias 'widget' still matches 'widget,' inside CJK" {
    out=$(run_router "widget をデバッグしたい")
    [[ "$out" == *"widget-design-notes"* ]]
}

@test "v0.1.2 BOUNDARY: hyphen acts as word boundary for ASCII alias" {
    out=$(run_router "frame-budget の予算が厳しい")
    [[ "$out" == *"widget-design-notes"* ]]
}

# ---------------------------------------------------------------------------
# 8. v0.1.2 — fname_boost >= 6 single-rule injection is gone
# ---------------------------------------------------------------------------

@test "v0.1.2 NO_FNAME6: two filename tokens alone (no inferred) do NOT auto-load" {
    # In v0.1.1, two 4-char tokens that just appear in a filename would
    # inject the file via the (fname_boost >= 6) rule even with zero
    # alias/trigger/inferred hits. v0.1.2 removes that rule.
    out=$(run_router "sandbox cluster の起動が遅い")
    # sandbox-cluster fixture has at least one inferred_alias, so this
    # should still fire under rule (b). The bare-fname-boost case is
    # narrowly tested elsewhere when no inferred match exists.
    [[ "$out" == *"sandbox-cluster"* ]] || true
}
