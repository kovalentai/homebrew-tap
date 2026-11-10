# Full Test Coverage Plan

The Homebrew tap's share of the coverage effort that brought the Kovalent apps to 100%. The rules are the same as the apps':

- **The target is 100%** of lines. Statements, functions and branches have no counterpart here: bashcov traces executed lines, which is all a shell script offers.
- **Exclusions are only for code that can't run in a test,** listed in one place, `.simplecov`, with a reason. There is one: `tests/`, which is the harness rather than shipped code. A guard in `tests/coverage.sh` fails the run if a script under `scripts/` is absent from the report, which is what bashcov's own scan for untested files would have caught had it not also double-counted the script it traced.
- **No coverage without a check.** A test asserts what the bump workflow or a maintainer sees: the exit code, the note on stderr, or the rendered formula. Each case is proven by breaking the code it covers and watching it fail.
- **Floors only rise.** The floor lives in `tests/coverage.sh`, because SimpleCov's own `minimum_coverage` is not enforced under bashcov.
- **Unreachable code is removed, not excluded,** in its own commit with the reason.
- **A bug found while covering code gets its own commit,** with a test that fails first, and the PR names it.

Measure the way CI does: `tests/coverage.sh`. It needs `bashcov`, and on macOS a bash newer than the 3.2 Apple ships.

## Baseline (November 2026)

0%. The tap had no test runner. CI style-checked, audited, installed and ran the formula on three platforms, which covers everything in `Formula/knaix.rb`, but nothing ran `scripts/render-formula.sh` -- the 289-line script that renders that formula from what `releases.knaix.com` serves, decides whether a release is publishable, and is the only place a wrong checksum could reach a user.

Order: there is one script, so one PR.

## PR 1: The render script

**Goal:** `scripts/render-formula.sh` at 100% of lines, with the coverage gate and the README badge.

- **No network and no ports.** Each case stands up its own release bucket as files and puts `tests/fake-curl` on a trimmed `PATH` in place of `curl`, which serves that tree by URL path and records every call. A loopback server would have needed a port, which a sandboxed run does not get.
- **Trimming `PATH` is also what covers both platforms' hashing.** The script prefers `sha256sum` and falls back to `shasum`, so on a mac one of those lines can never run. A world that offers only `shasum`, and one that adds `tests/fake-sha256sum`, run both on either platform.
- **One seam.** `KNAIX_TAP_FORMULA` points the reuse path at a fixture formula instead of the one this repo ships, matching the `KNAIX_RELEASES_URL` and `KNAIX_TAP_FORCE_VERIFY` seams already there.
- **Cases:** `latest-version` unreachable or empty, and a version ahead of what it serves; a full verify rendering to stdout and to a file, with the published version, urls and recomputed checksums; a binary or a sidecar that is not reachable; a binary that does not match its sidecar; the reuse path matching all four sidecars and downloading nothing; and its four fall-throughs -- an unusable pinned checksum, a sidecar that will not load, a sidecar that no longer matches a republished binary, and a forced verify.
- **The bump's own traffic.** Every request is asserted to carry the `knaix-tap-bump` token, which is what the stats query in knaix-cli matches to file the hourly run as ci rather than as four installs.
- **The coverage gate.** CI runs the suite on all three matrix platforms, since this is a bash script and macOS still ships bash 3.2, and measures coverage once on Linux. The floor is 100.
- **The README badge.** On each push to `main`, a separate job commits the line coverage, rounded down, as a shields.io endpoint file to the orphan `badges` branch, only when it changed. Only that job can write. It may fail without marking `main` red. Red below 60%, yellow below 80%, green from 80%.

Corrected on the way: the comment above the User-Agent said it must not contain the word "homebrew", and it does. The classifier tests `knaix-tap-bump` first and files the request as ci, so the code was right and the comment was wrong; it now names the token that matters.

Nothing is left for later. There is no second script, and the formula is checked by `brew style`, `brew audit --online`, `brew install` and `brew test` on Apple Silicon, Intel and Linux.
