# Contributing

Changes go through pull requests into `main`; CI (`Node tests`, `Panel tests`) must pass.

## Tests

```bash
node --test 'tests/*.test.mjs'           # logic, the lifetime math, security rules
python3 -m venv .venv-harness && .venv-harness/bin/pip install 'PySide6>=6.10,<6.12'
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

The panel tests load Omarchy's shell components from `/usr/share/omarchy/shell`. If your Omarchy is
newer than the version CI pins (`OMARCHY_REF` in `.github/workflows/tests.yml`), point `OMARCHY_SHELL`
at a checkout of that version's `shell/` folder. PySide6 must stay below 6.12 (Qt 6.12's `Color`
shadows Omarchy's in the harness).

## Preview

`.venv-harness/bin/python tools/preview/make-preview.py` rebuilds `preview.png` (3840x2160) from the
real dropdown with made-up repos and numbers. Needs chromium.

## Releasing

Bump `version` in `manifest.json`, merge, tag a GitHub release at the merge commit, then send the
marketplace's update form ("Verify and publish a newer upstream commit") with the full commit SHA.
