# Incidents

Defects that reached users in a tagged release. The list is the test set for every layer of review: a checklist, a skill or a reviewer is as good as the rows it would have found.

A row is added in the same commit that fixes such a defect. It names the commit that introduced it (or `unknown`), the fix, the earliest layer that should have caught it, and the test or check that catches it now. `scripts/check_incidents.py`, part of `make check`, fails a row whose commit does not exist, whose layer is not in the list below, or whose catcher is not in this repository.

A defect that nothing catches yet gets a test that fails on the old code before its row is written. When no test can see it (a window, a permission prompt, real mouse input), the catcher is the item added to `internal/release-checklist.md` and the layer is `hand-test`.

## Layers, earliest first

- `write-time`: the author's own check before committing, such as a grep for sites of the same shape, or a test run red on the old code.
- `unit`: the Swift tests in `Tests/main.swift` (`make test`).
- `check`: the other gates in `make check`: both text tables, the release notes, this ledger.
- `review`: a diff review or a sweep with the `bugs` skill.
- `release-preflight`: `scripts/release.sh` preflight and `scripts/package.sh`.
- `hand-test`: the checklist in `internal/release-checklist.md`, run in the packaged app.
- `field`: only a user's Mac shows it.

A catcher is the name of a check in `Tests/main.swift`, a tracked file path, or the name of a workflow step.

## Incidents

No release has been tagged yet, so there are no rows. The first one will look like this (without the leading `>`):

> | K-01 | 2026-12-01 | What the user saw (#issue) | abc1234 | def5678 | unit | `Tests/main.swift` |

| ID | Reported | Symptom | Introduced | Fixed | Layer | Caught by |
|---|---|---|---|---|---|---|
