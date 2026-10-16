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

## Label hints (optional)

These hints guide first labels. They do not limit what you inspect or find,
or predict acceptance or disposition. Choose a first label and file.
Examples are illustrative, not exhaustive.

- **Demonstrated shipped or operator-facing failure** → `bug`, even when
  a fixture exposed it. Includes classifier defects, misleading copy or
  defaults, missing diagnostics that prevent an operator from understanding
  or recovering from a failure, and leftover state that blocks a later
  user action. Demonstrated false-green default CI or validation also
  remains `bug`; no escaped product regression is required. Report
  vulnerabilities privately per SECURITY.md.
- **Demonstrated failure confined to a test, harness, or formal model** →
  `test`; documentation defects → `documentation`. Coverage requests and
  weak pins without a demonstrated product or default-validation failure
  also fit `test`. Model defects do not establish that the classifier is
  correct; demonstrated classifier or false-green validation failures
  remain `bug`. Operationally misleading documentation follows the first
  bullet.
- **Unresolved claims** follow Policy's existing `question` rule. Extra
  diagnostic detail without a demonstrated failure to explain or recover
  fits here. Include the evidence and what remains uncertain.

Label the affected behavior, not the source of the evidence. Describe known
reachability and uncertainty; incomplete reproduction does not block filing.

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
