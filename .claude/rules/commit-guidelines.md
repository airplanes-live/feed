# Commit message format

Feed commits follow the conventional-commits format. The workspace-wide `apl-workspace/.claude/rules/commit-and-pr.md` covers PR-body conventions; this file covers the commit-message format only.

## Structure

A commit message is structured as follows:

```
<type>[optional scope]: description

[optional body]

[optional footer(s)]
```

## Types

A commit contains one of:

1. **`fix:`** — patches a bug in the codebase (correlates with PATCH in semantic versioning).
2. **`feat:`** — introduces a new feature to the codebase (correlates with MINOR).
3. **Breaking change** — a commit that has a `BREAKING CHANGE:` footer, OR appends `!` after the type/scope, introduces a breaking change (correlates with MAJOR). The breaking marker can be applied to any type.
4. Other types are allowed: `build:`, `chore:`, `ci:`, `docs:`, `style:`, `refactor:`, `perf:`, `test:`, etc.

## Scope

A scope may be provided to a commit's type, in parentheses, to give additional context:

```
feat(parser): add ability to parse arrays
```

## Body

The body of a commit is a larger summary and **shall not exceed 256 characters**. It shall not reference any plan phases, or steps, when committed as part of task-driven development — those references rot the moment the plan is closed.

## Footers

Footers other than `BREAKING CHANGE: <description>` may be provided and follow a convention similar to the git trailer format.

## Examples

```
feat(mlat): publish runtime state file to /run/airplanes-mlat
fix(update): gate connectivity probes on command -v before nc/timeout
refactor: extract mlat/readsb builds into scripts/lib/
test: cover REINSTALL=yes and missing-artifact rebuild paths
chore!: drop bundled tar1090 installer
docs(claude): add feed-specific orientation and rule files
```

The format applies going forward. Existing commit history is mixed.
