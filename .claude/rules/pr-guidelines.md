# PR rules

How to write a PR description for this repo. Layers on top of `commit-guidelines.md` (commit-message format).

This is a public repo. PR bodies are read cold by anyone landing on the URL.

## PR descriptions

- **Short.** A few sentences of plain prose. Add at most one short list if there's a real reason.
- **State the effect and why.** Skip diff narration — the "Files changed" tab covers that.
- **No per-file sections.** No `### filename` headers, no per-file bullet lists, no "what changed in X" walkthroughs.
- **No "Test plan" or "Verification" section.** Verify before opening; that work is internal.
- **Stand alone.** No references to internal plans, phases, roadmap items, design docs, infrastructure topology, or chat threads. The PR body is the only thing the reader has.
- **Avoid templated multi-section structure.** Plain paragraphs beat multiple `###` headings.

## Issue keywords

- `Fixes #N` — closes the issue when this PR merges to the default branch.
- `Addresses #N` / `Refs #N` — work continues on a downstream branch; closure happens later (e.g. on `dev → main` merge).

Pick the right one and move on. Do **not** justify the choice in the PR body — that leaks the internal release process to public repos.

## PR titles

Imperative, single line, ≤ 72 chars. Describe the user-visible effect, not the file changed.

## Rule of thumb

If the body has multiple `###` sections, per-file walkthroughs, "Why X not Y" subsections, or "Test plan / Verification" headings, rewrite it as a paragraph or two of plain prose.
