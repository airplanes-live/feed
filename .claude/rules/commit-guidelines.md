# Commit message format

Feed commits follow the conventional-commits format. The workspace-wide `apl-workspace/.claude/rules/commit-and-pr.md` covers PR-body conventions; this file covers the commit-message format only.

## Structure

A commit message shall be structured as follows:

```
<type>[optional scope]: description

[optional body]

[optional footer(s)]
```

## Structural elements

A commit contains the following structural elements:

1. **`fix:`** — a commit of type `fix` patches a bug in the codebase (this correlates with `PATCH` in Semantic Versioning).
2. **`feat:`** — a commit of the type `feat` introduces a new feature to the codebase (this correlates with `MINOR` in Semantic Versioning).
3. **`BREAKING CHANGE:`** — a commit that has a footer `BREAKING CHANGE:`, or appends a `!` after the type/scope, introduces a breaking change (correlating with `MAJOR` in Semantic Versioning). A `BREAKING CHANGE` can be part of commits of any type.
4. Types other than `fix:` and `feat:` are allowed, for example `build:`, `chore:`, `ci:`, `docs:`, `style:`, `refactor:`, `perf:`, `test:`, and others.
5. Footers other than `BREAKING CHANGE: <description>` may be provided and follow a convention similar to the git trailer format.

## Scope

A scope may be provided to a commit's type, to provide additional contextual information and is contained within parentheses, e.g., `feat(parser): add ability to parse arrays`.

## Body

The body of a commit is a larger summary and shall not exceed 256 characters. It shall not reference any plan phases, or steps, when committed as part of task-driven development.

## Examples

```
feat(mlat): publish runtime state file to /run/airplanes-mlat
fix(update): gate connectivity probes on command -v before nc/timeout
refactor: extract mlat/readsb builds into scripts/lib/
test: cover REINSTALL=yes and missing-artifact rebuild paths
chore!: drop bundled tar1090 installer
docs(claude): add feed-specific orientation and rule files
```
