# Contributing

Changes go through pull requests into `main`; CI (`Node tests`, `Panel tests`) must pass.

## Tests

```bash
node --test 'tests/*.test.mjs'           # logic, the lifetime math, security rules
python3 -m venv .venv-harness && .venv-harness/bin/pip install --only-binary :all: --require-hashes -r tests/requirements-harness.txt
cd tests && ../.venv-harness/bin/python -m unittest panel_test -v   # the real panel, fake GitHub
omarchy plugin validate .
```

- `tests/math.test.mjs` proves the counting rule against simulated traffic: GitHub's rolling 14-day
  window (0 to 2 days behind, the newest day still growing), every check schedule, days off.
- `tests/security.test.mjs` fails the build if a shipped file contacts another host, uses plain HTTP,
  puts the GitHub token anywhere but the allowed lines, passes data on a command line, logs, or uses
  privilege escalation.
- `tests/panel_test.py` runs the real QML (with Omarchy's real Commons/Ui) against a local fake of
  GitHub and the marketplace (`tests/fake_github.py`) and a fake `secret-tool` (`tests/fake-bin`), so it
  never touches a real account or keyring. It checks where the token goes, too.

The panel tests load Omarchy's shell components from `/usr/share/omarchy/shell`, or from
`OMARCHY_SHELL` (a checkout's `shell/` folder). CI runs them on the releases in `OMARCHY_REFS`
(`.github/workflows/tests.yml`). Right now that is Omarchy 4.0.6, the current stable release, and
Omarchy 4.5.0-rc3, the current 4.5 prerelease. The plugin adapts to each: 4.5 draws bar labels itself
and has a system-wide animation switch; 4.0.6 does not. `tests/panel_test.py` checks both paths.
PySide6 must stay below 6.12 (Qt 6.12's `Color` shadows Omarchy's in the harness).

## Preview

`.venv-harness/bin/python tools/preview/make-preview.py` rebuilds `preview.png` (3840x2160) from the
real dropdown with made-up repos and numbers. Needs chromium.

## Releasing

Bump `version` in `manifest.json` and merge. Tag a GitHub release at the full 40-character SHA of
that commit on `main`.

The first marketplace listing is a submission issue on `omacom/omarchy-plugin-marketplace`. The title
is `[Plugin]: HowIsMyPlug?`. The body keeps the six headings and the five checklist lines from that
repo's `SUBMISSION.md`, in that order, with every box checked. Category is `Developer Tools`. Tags are
`bar` and `quickshell`.

A later version uses the marketplace update form ("Verify and publish a newer upstream commit") with
this plugin's id, the repository root URL, and the full SHA of current `main`. A commit that lands on
`main` after a listing shows "Update unverified" until that form is approved.
