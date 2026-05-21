#!/usr/bin/env bats

# Lint test: refuse `--arg` / `--argjson` invocations that use a jq reserved
# keyword as the variable name. jq 1.6 (Pi OS bullseye/bookworm default)
# rejects `$<keyword>` references at parse time with
# `syntax error, unexpected <keyword>, expecting IDENT or __loc__`,
# even though jq 1.7+ accepts the same expression. Without this guard,
# such bugs slip through CI (which uses jq 1.7) and surface only on
# deployed feeders.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "no --arg or --argjson uses a jq reserved keyword as variable name" {
    # jq parser keywords (1.6 + 1.7) plus the __loc__ built-in. Sorted
    # alphabetically. Includes `break` because jq's lexer treats it as a
    # token alongside `label`.
    local keywords='__loc__|and|as|break|catch|def|elif|else|end|false|foreach|if|import|include|label|module|not|null|or|reduce|then|true|try'

    # Match `--arg name` or `--argjson name` where `name` is the bare
    # keyword (optionally single- or double-quoted, since `--arg "label"
    # "$x"` would also break jq 1.6), followed by a non-word boundary
    # (space, newline, end-of-line) — not by `_` or letters, so
    # `label_text` is fine and only the bare keyword is flagged.
    local pattern="--arg(json)?[[:space:]]+[\"']?(${keywords})[\"']?([[:space:]]|\$)"

    # Pass the pattern via `-e` so grep doesn't try to interpret the leading
    # `--` as its own option terminator — otherwise grep parses `--arg…` as
    # a flag, errors out, and `|| true` silently turns the lint into a no-op.
    local matches
    matches="$(
        grep -rnE -e "$pattern" "$REPO_ROOT" \
            --include='*.sh' \
            --include='*.bats' \
            --exclude-dir=.git \
            --exclude-dir=.claude \
            --exclude='test_jq_arg_keyword_lint.bats' \
            || true
    )"

    if [[ -n "$matches" ]]; then
        printf '\njq --arg/--argjson uses a reserved keyword as variable name:\n%s\n' "$matches" >&2
        printf '\nRename the variable (e.g. label -> label_text). The JSON output key can stay the same.\n' >&2
        return 1
    fi
}
