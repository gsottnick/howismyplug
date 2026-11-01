# Build progress (for resuming)

Plan: `~/.claude/plans/can-we-make-an-melodic-wind.md`. Work on branch `first-build`, merge by PR.

- [x] Repo created (gsottnick/howismyplug), public, "Protect main" ruleset (PRs only, Node tests + Panel tests required)
- [x] GitHub App "HowIsMyPlug" (id 5572028, client ID Iv23liNYpgF5dSPSM5qD): Administration read, Metadata read,
      device flow on, user tokens don't expire, no webhook, installable by any account, no private key.
      Installed on gsottnick → omatuple only.
- [x] Live check (2026-11-01): device-flow token reads omatuple traffic (551/152 clones, matches GitHub); 403 on a repo without the app
- [x] Model.js + tests/model.test.mjs; tests/security.test.mjs (static rules)
- [x] PlugStore.qml, Panel.qml, PlugView.qml, manifest.json, qmldir; animations copied from token-payoff
- [x] tests/panel_test.py (14, fake GitHub + fake secret-tool); live public-API run OK (omatuple id + listing stats)
- [x] README, SECURITY.md, preview.png (tools/preview), CI workflow
- [ ] Gavin: approve the look (preview.png) and the PR; merge
- [ ] Live test in Gavin's bar (needs his OK for omarchy-restart-shell)
- [ ] Gavin: enable private vulnerability reporting (SECURITY.md points to it)
- [ ] Marketplace submission (show Gavin the exact text first)

Local test venv: Omatuple's `~/Work/Omatuple/.venv-harness` works (PySide6 6.11.3).
