# Incidents

Defects that reached users in a tagged release. The list is the test set for every layer of review: a checklist, a skill or a reviewer is as good as the rows it would have found.

A row is added in the same commit that fixes such a defect. It names the commit that introduced it (or `unknown`), the fix, the earliest layer that should have caught it, and the test or check that catches it now. `scripts/check_incidents.py`, part of `make check`, fails a row whose commit does not exist, whose layer is not in the list below, or whose catcher is not in this repository.

A defect that nothing catches yet gets a test that fails on the old code before its row is written. When no test can see it (a window, a permission prompt, real mouse input), the catcher is the item added to `internal/release-checklist.md` and the layer is `hand-test`.

## Layers, earliest first

- `write-time`: the author's own check before committing, such as a grep for sites of the same shape, or a test run red on the old code.
- `unit`: the Swift tests in `Tests/`, one file per source folder (`make test`).
- `check`: the other gates in `make check`: both text tables, the release notes, this ledger.
- `review`: a diff review or a sweep with the `bugs` skill.
- `release-preflight`: `scripts/release.sh` preflight and `scripts/package.sh`.
- `hand-test`: the checklist in `internal/release-checklist.md`, run in the packaged app.
- `field`: only a user's Mac shows it.

A catcher is the name of a check in `Tests/`, a tracked file path, or the name of a workflow step.

## Incidents

| ID | Reported | Symptom | Introduced | Fixed | Layer | Caught by |
|---|---|---|---|---|---|---|
| K-01 | 2026-11-15 | The welcome window's system-shortcut button had unclear Chinese wording and opened System Settings without the instructions available in Settings. | b806ca3 | 2104617 | hand-test | `internal/release-checklist.md` |
| K-02 | 2026-11-16 | The first text recognition on a new Mac, after a macOS update or after another signature of the app had run, waited 30-50 s with nothing on screen while the system compiled Vision's models. | b806ca3 | d13a297 | hand-test | `internal/release-checklist.md` |
| K-03 | 2026-11-16 | If the app crashed or was forced to quit during a scrolling capture, its helper went on photographing the region six times a second, and its scratch files stayed. | b806ca3 | 98121fd | review | a helper ends when its app goes |
| K-04 | 2026-11-16 | Dragging a selection to record or to capture while scrolling raised the app's memory to several hundred megabytes (445 MB with a 4K screen and a second one), and part of it stayed afterwards. | b806ca3 | b664eca | hand-test | `internal/release-checklist.md` |
