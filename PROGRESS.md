# Build progress (for resuming)

Plan: `~/.claude/plans/can-we-make-an-melodic-wind.md`. Work on branch `first-build`, merge by PR.

- [x] Repo created (gsottnick/howismyplug), initial commit on main
- [ ] Repo public + "Protect main" ruleset copied from omatuple (needs Gavin: auto mode blocked it)
- [ ] Step 0: GitHub App "HowIsMyPlug" (Administration read, Metadata read, device flow on, user tokens don't expire) — needs Gavin's OK
- [x] Step 1 spike: Quickshell XHR does HTTPS + custom headers (status 200 from api.omarchyplugins.com)
- [ ] Step 1 rest: device-flow token reads /traffic/clones; non-expiring token works without a secret
- [x] Step 2: Model.js + tests/model.test.mjs (13 passing)
- [ ] Step 3: PlugStore.qml, Panel.qml, PlugView.qml, manifest.json, qmldir
- [ ] Step 4: preview checkpoint with Gavin
- [ ] Steps 5-8: animations/milestones, security test, CI, live test, preview.png, README/SECURITY.md, submission
