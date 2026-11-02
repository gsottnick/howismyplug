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
- [x] Live test in Gavin's bar (2026-11-01): signed in via the app, omatuple matches GitHub (551/152 clones,
      165/4 views); token only in the keyring (not in history.json, shell.json, any /proc cmdline, or the shell log).
      Live bugs found and fixed: zero-size widget; device-flow poll stalls (20 s request timeout + retry);
      slow_down loop (poll 1 s behind GitHub's interval, use the interval it sends). Copy-code button and
      example placeholder added at Gavin's request.
      Note: `qs log -f` (log follower) aborts on exit (Quickshell bug); read logs with plain `qs log -i <id>`.
- [ ] Gavin: enable private vulnerability reporting (SECURITY.md points to it)
- [ ] Marketplace submission (show Gavin the exact text first)

Local test venv: Omatuple's `~/Work/Omatuple/.venv-harness` works (PySide6 6.11.3).
