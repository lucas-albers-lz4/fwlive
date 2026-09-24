# Issue authoring (review findings)

Owner for **review findings filed as GitHub issues**. Implementation issues,
questions, and umbrellas stay free-form.

## Required sections

Skip a section with nothing true to say — do not pad.

### Finding

What is wrong; include `path:line` for code defects.

### Evidence

Quote from the diff, or a command plus its output.

### Next step

Short decision or pointer — not a full implementation spec. Plans may be folded
into the same issue later.

Optional: `Impact`, `Expected behavior`, `Confidence: high|medium|low`.
Independent re-checks go in a **comment**, not extra sections.

## Policy

- One defect per issue. Two reviewers, same defect → file once.
- Unsure it is a defect → `question`, not `bug`.
- Use an existing label (`gh label list`). Write the body with `--body-file`.
- Public tracker is not for vulnerabilities ([`SECURITY.md`](../../SECURITY.md)).

## Example

Title: `bug: unquoted expansion in helper script`

```markdown
## Finding
`scripts/foo.sh:42` — failure path echoes `$msg` unquoted.
## Evidence
Line 42: `echo $msg` (no quotes around `$msg`).
## Next step
Quote the expansion; add a shellcheck gate if missing.
```
