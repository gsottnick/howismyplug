"""End-to-end tests for the HowIsMyPlug? bar widget.

Each test loads the real plugin in tests/harness (real Omarchy Ui components,
real process execution) against tests/fake_github.py and the fake
secret-tool in tests/fake-bin, drives it the way a click would, and checks
what it showed, what it stored, and where the token went.

Nothing here touches GitHub, the marketplace or the real keyring: every web
request goes to the local fake (HOWISMYPLUG_TEST_BASE), the fake secret-tool
is first on PATH, and the harness's --theme run points HOME at a throwaway
directory.

    .venv-harness/bin/python -m unittest discover -s tests -p 'panel_test.py'

The venv pins PySide6 below 6.12: Qt 6.12's QtQuick exports its own `Color`
singleton, which shadows Omarchy's in this harness (not in Quickshell).
"""

import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
HARNESS = HERE / "harness" / "main.py"
FAKE_BIN = HERE / "fake-bin"
sys.path.insert(0, str(HERE))
import fake_github  # noqa: E402

OMARCHY = Path(os.environ.get("OMARCHY_SHELL", "/usr/share/omarchy/shell"))

IGNORED_QT_WARNINGS = (
    "propertyCache.append",
    "Unable to assign [undefined] to int",
    "QProcess: Destroyed while process",
)

PLUGIN_MANIFEST = {"id": "io.github.octo.plug", "name": "Plug"}


def day(offset=0):
    return (datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=offset)).isoformat()


class Harness:
    """One run of the panel against the fake servers and keyring."""

    def __init__(self, test, fake):
        self.test = test
        self.fake = fake
        self.workdir = Path(tempfile.mkdtemp(prefix="hmp-panel-"))
        self.keyring = self.workdir / "keyring"
        self.keyring.mkdir()
        self.state_home = self.workdir / "state"
        self.env = dict(
            os.environ,
            QT_QPA_PLATFORM="offscreen",
            HARNESS_SCREEN="1600x1200",
            HOWISMYPLUG_TEST_BASE=fake.base,
            FAKE_KEYRING=str(self.keyring),
            XDG_STATE_HOME=str(self.state_home),
            PATH=f"{FAKE_BIN}:{os.environ.get('PATH', '')}",
        )

    @property
    def history_file(self):
        return self.state_home / "howismyplug" / "history.json"

    def seed(self, state):
        self.history_file.parent.mkdir(parents=True, exist_ok=True)
        self.history_file.write_text(json.dumps(state))

    def sign_in_with_keyring(self, token=fake_github.TOKEN):
        (self.keyring / "secret").write_text(token)

    def run(self, steps=(), settle=1500, step_delay=700, settings=None, font_size=12, extra=()):
        final = self.workdir / "final.json"
        dumps = self.workdir / "dumps"
        shutil.rmtree(dumps, ignore_errors=True)
        command = [
            sys.executable, str(HARNESS),
            "--omarchy", str(OMARCHY),
            "--dump", str(final), "--dump-each", str(dumps),
            "--settle", str(settle), "--step-delay", str(step_delay),
            "--theme", "tokyo-night", "--font-size", str(font_size),
            "--settings", json.dumps(settings or {}),
            "--do", ",".join(steps),
            *extra,
        ]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=120)
        noise = [line for line in result.stderr.splitlines()
                 if line.strip() and not any(i in line for i in IGNORED_QT_WARNINGS)]
        self.test.assertEqual(result.returncode, 0, f"harness failed:\n{result.stderr}")
        self.test.assertEqual(noise, [], "the panel logged QML errors")
        self.final = json.loads(final.read_text())
        return self.final

    def after(self, index):
        return json.loads(sorted((self.workdir / "dumps").glob(f"{index:02d}-*.json"))[0].read_text())

    def keyring_argv(self):
        log = self.keyring / "argv"
        return log.read_text() if log.exists() else ""

    def keyring_secret(self):
        secret = self.keyring / "secret"
        return secret.read_text() if secret.exists() else None

    def cleanup(self):
        shutil.rmtree(self.workdir, ignore_errors=True)


def every_command(snapshot):
    commands = snapshot["detached"] + [p["command"] for p in snapshot["piped"]]
    return " ".join(" ".join(c) for c in commands)


class PanelTest(unittest.TestCase):
    maxDiff = None

    @classmethod
    def setUpClass(cls):
        if not OMARCHY.is_dir():
            raise unittest.SkipTest(f"Omarchy shell not found at {OMARCHY}")

    def setUp(self):
        self.fake = fake_github.Fake()
        self.addCleanup(self.fake.close)
        self.fake.repos["octo/plug"] = {
            "manifest": PLUGIN_MANIFEST,
            "clones": {day(-2): (10, 4), day(-1): (6, 3), day(0): (2, 2)},
            "views": {day(-1): (30, 5), day(0): (5, 1)},
        }
        self.fake.market["io.github.octo.plug"] = {"views": 71, "copies": 3, "hearts": 2}

    def harness(self):
        h = Harness(self, self.fake)
        self.addCleanup(h.cleanup)
        return h

    def assert_token_stays_private(self, h, token):
        state = h.final
        self.assertNotIn(token, every_command(state), "never on a command line")
        self.assertNotIn(token, h.keyring_argv(), "never on secret-tool's command line")
        if h.history_file.exists():
            self.assertNotIn(token, h.history_file.read_text(), "never in the state file")
        self.assertNotIn(token, json.dumps(state["barWrites"]), "never in shell.json")
        for method, path, auth in self.fake.requests:
            if auth:
                self.assertTrue(path.startswith("/api/"), f"token sent to {path}")
                self.assertNotIn(token, path)

    def test_first_run_is_empty_and_signed_out(self):
        h = self.harness()
        s = h.run()
        self.assertTrue(s["stateLoaded"])
        self.assertTrue(s["keyringChecked"])
        self.assertFalse(s["signedIn"])
        self.assertEqual(s["panel"]["barText"], "")
        self.assertGreater(s["panel"]["width"], 0, "the widget takes space in the bar")
        self.assertGreater(s["panel"]["height"], 0)
        self.assertEqual(s["state"]["repos"], [])
        # Nothing tracked: no web requests at all.
        self.assertEqual(self.fake.requests, [])

    def test_marketplace_numbers_work_without_signing_in(self):
        h = self.harness()
        s = h.run(["track:https://github.com/octo/plug", "wait:1500"])
        repo = s["state"]["repos"][0]
        self.assertEqual(repo["repo"], "octo/plug")
        self.assertEqual(repo["pluginId"], "io.github.octo.plug")
        self.assertEqual(repo["market"]["current"], {"views": 71, "copies": 3, "hearts": 2})
        self.assertEqual(s["view"]["totals"]["market"], {"views": 71, "copies": 3, "hearts": 2})
        self.assertIsNone(repo["clones"], "no traffic without a sign-in")
        self.assertFalse(any(path.endswith("/traffic/clones") for _, path, _ in self.fake.requests))
        # The history survives a restart.
        saved = json.loads(h.history_file.read_text())
        self.assertEqual(saved["repos"][0]["pluginId"], "io.github.octo.plug")
        self.assertEqual(oct(h.history_file.stat().st_mode & 0o777), "0o600")

    def test_bad_repo_names_are_refused(self):
        h = self.harness()
        s = h.run(["track:not a repo", "track:../etc/passwd"])
        self.assertEqual(s["state"]["repos"], [])
        self.assertIn("owner/repo", s["view"]["repoError"])
        self.assertEqual(self.fake.requests, [])

    def test_a_pasted_token_goes_to_the_keyring_on_stdin_and_reads_traffic(self):
        h = self.harness()
        s = h.run(["track:octo/plug", "token:" + fake_github.PAT, "wait:1500"])
        self.assertTrue(s["signedIn"])
        self.assertEqual(s["authMethod"], "token")
        self.assertEqual(h.keyring_secret(), fake_github.PAT)
        repo = s["state"]["repos"][0]
        self.assertEqual(repo["access"], "ok")
        # Counts add up by day; unique people are GitHub's own 14-day count (the fake reports the busiest day's).
        self.assertEqual(s["view"]["totals"]["clones"], {"count": 18, "uniques": 4})
        self.assertEqual(s["view"]["totals"]["views"], {"count": 35, "uniques": 5})
        self.assertEqual(s["panel"]["barText"], "18")
        self.assert_token_stays_private(h, fake_github.PAT)

    def test_a_second_token_saved_mid_write_is_the_one_kept(self):
        h = self.harness()
        s = h.run(["token:" + fake_github.PAT, "token:" + fake_github.PAT2, "wait:1500"], step_delay=50)
        self.assertEqual(h.keyring_secret(), fake_github.PAT2)
        self.assertTrue(s["signedIn"])
        self.assert_token_stays_private(h, fake_github.PAT2)

    def test_signing_out_mid_write_leaves_the_keyring_empty(self):
        h = self.harness()
        s = h.run(["token:" + fake_github.PAT, "sign-out", "wait:1500"], step_delay=50)
        self.assertFalse(s["signedIn"])
        self.assertIsNone(h.keyring_secret())

    def test_a_bad_token_is_refused_before_it_is_stored(self):
        h = self.harness()
        s = h.run(["token:not a token!"])
        self.assertFalse(s["signedIn"])
        self.assertIsNone(h.keyring_secret())
        self.assertIn("doesn't look like", s["view"]["tokenError"])

    def test_sign_in_with_github_device_flow(self):
        h = self.harness()
        s = h.run(["track:octo/plug", "sign-in", "wait:7000"], step_delay=900)
        during = h.after(1)
        self.assertEqual(during["userCode"], "ABCD-1234")
        self.assertIn("https://github.com/login/device", during["opened"])
        copied = [p["stdin"] for p in during["piped"] if p["command"] == ["wl-copy"]]
        self.assertIn("ABCD-1234", copied)
        self.assertTrue(during["view"]["codeCopied"] is False, "only the button shows 'Copied'")
        self.assertTrue(s["signedIn"])
        self.assertEqual(s["authMethod"], "app")
        self.assertFalse(s["signingIn"])
        self.assertEqual(h.keyring_secret(), fake_github.TOKEN)
        self.assertEqual(s["state"]["repos"][0]["access"], "ok")
        self.assert_token_stays_private(h, fake_github.TOKEN)

    def test_sign_in_gets_through_a_strict_poll_interval(self):
        # GitHub answers slow_down to a poll that is even slightly early and adds
        # 5 s each time; polling right at the limit never gets the token.
        self.fake.strict = True
        self.fake.pending_polls = 1
        h = self.harness()
        s = h.run(["sign-in", "wait:16000"], step_delay=500)
        self.assertEqual(self.fake.slow_downs, 0, "never polls too early")
        self.assertTrue(s["signedIn"])

    def test_sign_in_follows_the_interval_github_asks_for(self):
        self.fake.strict = True
        self.fake.interval = 7      # the device code says 5 s; the server wants 7.5 s at first
        h = self.harness()
        s = h.run(["sign-in", "wait:24000"], step_delay=500)
        self.assertLessEqual(self.fake.slow_downs, 1, "one slow_down, then it waits as told")
        self.assertTrue(s["signedIn"])

    def test_sign_in_survives_a_poll_that_never_answers(self):
        self.fake.hang_polls = 1
        h = self.harness()
        h.env["HOWISMYPLUG_TEST_TIMEOUT_MS"] = "3000"
        s = h.run(["sign-in", "wait:19000"], step_delay=500)
        self.assertGreaterEqual(self.fake.token_polls, 2, "asked again after the stuck poll")
        self.assertTrue(s["signedIn"])
        self.assertEqual(h.keyring_secret(), fake_github.TOKEN)

    def test_the_copy_button_copies_the_sign_in_code(self):
        self.fake.pending_polls = 99
        h = self.harness()
        s = h.run(["sign-in", "wait:300", "click:overviewSignIn-copyCode"])
        copied = [p["stdin"] for p in s["piped"] if p["command"] == ["wl-copy"]]
        self.assertEqual(copied, ["ABCD-1234", "ABCD-1234"], "copied on sign-in and again on click")
        self.assertTrue(s["view"]["codeCopied"])

    def test_a_saved_sign_in_is_used_on_start_and_sign_out_forgets_it(self):
        h = self.harness()
        h.sign_in_with_keyring()
        h.seed({"repos": [{"repo": "octo/plug", "pluginId": "io.github.octo.plug", "idChecked": True}]})
        s = h.run(["wait:1000", "sign-out"])
        signed_in = h.after(0)
        self.assertTrue(signed_in["signedIn"])
        self.assertEqual(signed_in["state"]["repos"][0]["access"], "ok", "polled on start (never polled before)")
        self.assertFalse(s["signedIn"])
        self.assertIsNone(h.keyring_secret())
        self.assert_token_stays_private(h, fake_github.TOKEN)

    def test_a_repo_without_access_offers_to_give_access(self):
        self.fake.repos["octo/private"] = {"manifest": None, "access": False}
        h = self.harness()
        h.sign_in_with_keyring()
        s = h.run(["track:octo/private", "wait:1200", "open-repo:octo/private", "click:giveAccessButton"])
        repo = s["state"]["repos"][0]
        self.assertEqual(repo["access"], "denied")
        self.assertTrue(repo["idChecked"])
        self.assertEqual(repo["pluginId"], "")
        self.assertIn("https://github.com/apps/howismyplug/installations/new", s["opened"])

    def test_repolling_merges_days_without_double_counting(self):
        h = self.harness()
        h.sign_in_with_keyring()
        h.seed({"lastPoll": 1, "repos": [{"repo": "octo/plug", "pluginId": "io.github.octo.plug", "idChecked": True,
                 "clones": {"days": {day(-30): [100, 20], day(-1): [4, 2]}}}]})
        s = h.run(["wait:1000", "poll", "wait:1000"])
        clones = s["state"]["repos"][0]["clones"]
        self.assertEqual(clones["days"][day(-30)], [100, 20], "days GitHub forgot are kept")
        self.assertEqual(clones["days"][day(-1)], [6, 3], "the larger reading wins")
        self.assertEqual(s["view"]["totals"]["clones"]["count"], 100 + 10 + 6 + 2)

    def test_junk_from_the_server_is_ignored(self):
        self.fake.repos["octo/plug"]["clones_raw"] = {"count": "lots", "clones": [{"timestamp": "<script>", "count": 5}, "x"]}
        self.fake.market["io.github.octo.plug"] = {"views": -5, "copies": "<b>", "hearts": 1e30}
        h = self.harness()
        h.sign_in_with_keyring()
        s = h.run(["track:octo/plug", "wait:1500"])
        repo = s["state"]["repos"][0]
        self.assertEqual(repo["clones"]["days"], {})
        self.assertEqual(repo["market"]["current"], {"views": 0, "copies": 0, "hearts": 0})

    def test_period_choice_is_saved_to_the_widget_settings(self):
        h = self.harness()
        s = h.run(["period:7d"])
        self.assertEqual(s["panel"]["period"], "7d")
        self.assertEqual(s["barWrites"][-1]["period"], "7d")
        self.assertEqual(s["barWrites"][-1]["id"], "io.github.gsottnick.howismyplug")

    def test_milestone_shows_once_when_the_dropdown_opens(self):
        h = self.harness()
        h.seed({"seen": {"clones": 0}, "repos": [{"repo": "octo/plug", "pluginId": "io.github.octo.plug", "idChecked": True,
                 "clones": {"days": {day(-40): [250, 30]}}}]})
        s = h.run(["wait:300", "close", "open", "wait:600", "close", "open", "wait:300"], settings={"milestoneStep": 100}, extra=["--closed"])
        before = h.after(0)
        self.assertTrue(before["panel"]["milestonePending"])
        self.assertTrue(before["panel"]["disco"])
        shown = h.after(3)
        self.assertTrue(shown["view"]["cardVisible"])
        self.assertTrue(shown["view"]["confetti"], "confetti with animations on")
        self.assertEqual(shown["view"]["shown"], {"repo": "", "metric": "clones", "value": 200}, "the combined milestone")
        self.assertEqual(s["state"]["seen"]["clones"], 2)
        self.assertEqual(s["state"]["repos"][0]["seen"]["clones"], 2, "the repo's own milestone, first seen: recorded silently")
        self.assertFalse(s["panel"]["milestonePending"])
        self.assertFalse(s["view"]["cardVisible"], "not shown again")

    def test_first_run_records_milestones_silently(self):
        h = self.harness()
        h.seed({"repos": [{"repo": "octo/plug", "idChecked": True, "clones": {"days": {day(-40): [250, 30]}}}]})
        s = h.run(["wait:600"])
        self.assertEqual(s["state"]["seen"]["clones"], 2)
        self.assertEqual(s["state"]["repos"][0]["seen"]["clones"], 2)
        self.assertFalse(s["view"]["cardVisible"])

    def test_animations_off_still_announces_milestones(self):
        h = self.harness()
        h.seed({"seen": {"clones": 1}, "repos": [{"repo": "octo/plug", "idChecked": True, "clones": {"days": {day(-40): [250, 30]}}}]})
        s = h.run(["wait:400"], settings={"animations": False})
        self.assertFalse(s["panel"]["disco"])
        self.assertTrue(s["view"]["cardVisible"])
        self.assertFalse(s["view"]["confetti"], "no confetti with animations off")

    def test_a_repo_celebrates_its_own_milestone_and_combined_can_be_off(self):
        h = self.harness()
        h.seed({"seen": {"clones": 0}, "repos": [
            {"repo": "octo/plug", "idChecked": True, "milestone": {"on": True, "metric": "clones", "step": 50}, "seen": {"clones": 1},
             "clones": {"days": {day(-40): [120, 30]}}}]})
        s = h.run(["wait:400"], settings={"combinedMilestones": False})
        self.assertTrue(s["view"]["cardVisible"])
        self.assertEqual(s["view"]["shown"], {"repo": "octo/plug", "metric": "clones", "value": 100})
        self.assertEqual(s["state"]["seen"]["clones"], 0, "combined off: its count is left alone")

    def test_a_failed_plugin_id_lookup_is_retried(self):
        h = self.harness()
        h.seed({"repos": [{"repo": "octo/plug", "idChecked": False}]})
        s = h.run(["wait:1200"])
        repo = s["state"]["repos"][0]
        self.assertTrue(repo["idChecked"])
        self.assertEqual(repo["pluginId"], "io.github.octo.plug")
        self.assertEqual(repo["market"]["current"]["views"], 71, "signed out: listing numbers still arrive")

    def test_the_dropdown_never_grows_past_its_size(self):
        heights = {}
        for count, size in ((1, "normal"), (60, "normal"), (60, "compact"), (60, "tall")):
            h = self.harness()
            h.seed({"repos": [{"repo": f"octo/plug{i}", "idChecked": True} for i in range(count)]})
            s = h.run(["wait:200"], settings={"panelSize": size})
            heights[(count, size)] = s["panel"]["contentHeight"]
        self.assertEqual(heights[(1, "normal")], heights[(60, "normal")], "sixty repos: same height, the list scrolls")
        self.assertLess(heights[(60, "compact")], heights[(60, "normal")])
        self.assertLess(heights[(60, "normal")], heights[(60, "tall")])

    def test_each_repo_has_its_own_checks_and_milestones(self):
        h = self.harness()
        h.seed({"repos": [{"repo": "octo/plug", "pluginId": "io.github.octo.plug", "idChecked": True},
                          {"repo": "octo/other", "idChecked": True}]})
        s = h.run(["open-repo:octo/plug", "pick:repoCheckGithub=hourly", "pick:repoCheckListing=weekly",
                   "click:repoMilestonesToggle", "click:repoMilestonesToggle", "choose:repoMilestoneMetric=hearts",
                   "number:repoMilestoneStep=25"])
        self.assertEqual(h.after(0)["view"]["page"], "repo")
        plug, other = s["state"]["repos"]
        self.assertEqual((plug["checkGithub"], plug["checkListing"]), ("hourly", "weekly"))
        self.assertEqual(plug["milestone"], {"on": True, "metric": "hearts", "step": 25})
        self.assertFalse(h.after(3)["state"]["repos"][0]["milestone"]["on"], "the toggle switched it off, then on")
        self.assertEqual((other["checkGithub"], other["checkListing"]), ("daily", "daily"), "other repos untouched")
        self.assertEqual(other["milestone"], {"on": True, "metric": "clones", "step": 100})

    def test_changing_a_repos_schedule_checks_right_away(self):
        h = self.harness()
        h.sign_in_with_keyring()
        now = int(time.time() * 1000)   # just checked: nothing is due on its own
        h.seed({"repos": [{"repo": "octo/plug", "pluginId": "io.github.octo.plug", "idChecked": True,
                           "lastGithub": now, "lastListing": now}]})
        s = h.run(["wait:600", "open-repo:octo/plug", "pick:repoCheckGithub=twodays", "wait:600",
                   "pick:repoCheckListing=weekly", "wait:600"])
        traffic = [p for _, p, _ in self.fake.requests if p.endswith("/traffic/clones")]
        stats = [p for _, p, _ in self.fake.requests if p == "/market/v1/stats"]
        self.assertEqual(len(traffic), 1, "one GitHub check, from the schedule change")
        self.assertEqual(len(stats), 1, "one listing check, from the schedule change")
        self.assertEqual(s["state"]["repos"][0]["checkGithub"], "twodays")
        self.assertEqual(s["state"]["repos"][0]["checkListing"], "weekly")

    def test_new_repos_start_with_the_default_checks(self):
        h = self.harness()
        s = h.run(["page:settings", "pick:defaultCheckGithubChoice=weekly", "pick:defaultCheckListingChoice=hourly",
                   "page:overview", "track:octo/plug", "wait:600"])
        repo = s["state"]["repos"][0]
        self.assertEqual((repo["checkGithub"], repo["checkListing"]), ("weekly", "hourly"))

    def test_the_bar_number_can_be_any_stat_of_any_repo(self):
        self.fake.repos["octo/other"] = {"manifest": {"id": "io.github.octo.other"}}
        self.fake.market["io.github.octo.other"] = {"views": 5000, "copies": 9, "hearts": 4}
        h = self.harness()
        s = h.run(["track:octo/plug", "track:octo/other", "wait:1500", "page:settings",
                   "choose:barSourceChoice=octo/plug", "choose:barStatChoice=listingViews"])
        self.assertEqual(s["panel"]["barText"], "71")
        self.assertEqual((s["barWrites"][-1]["barSource"], s["barWrites"][-1]["barStat"]), ("octo/plug", "listingViews"))
        all_listing = h.after(2)["panel"]["barValue"]
        self.assertEqual(all_listing, 0, "default stat is clones (signed out: none yet)")

    def test_settings_page_saves_look_and_milestone_choices(self):
        h = self.harness()
        s = h.run(["page:settings", "pick:panelSizeChoice=tall", "pick:accentChoice=urgent", "pick:countModeChoice=unique",
                   "click:animationsToggle", "click:showCombinedToggle", "click:combinedMilestonesToggle",
                   "click:combinedMilestonesToggle", "choose:combinedMilestoneMetric=copies", "number:combinedMilestoneStep=10"])
        last = s["barWrites"][-1]
        self.assertEqual((last["panelSize"], last["accent"], last["countMode"]), ("tall", "urgent", "unique"))
        self.assertEqual((last["animations"], last["showCombined"], last["combinedMilestones"]), (False, False, True))
        self.assertEqual((last["milestoneMetric"], last["milestoneStep"]), ("copies", 10))

    def test_help_page_links_go_where_the_steps_say(self):
        h = self.harness()
        s = h.run(["click:helpButton", "click:helpTokenPage", "click:helpGiveAccess", "click:backButton"])
        self.assertEqual(h.after(0)["view"]["page"], "help")
        self.assertIn("https://github.com/settings/personal-access-tokens/new", s["opened"])
        self.assertIn("https://github.com/apps/howismyplug/installations/new", s["opened"])
        self.assertEqual(s["view"]["page"], "overview")

    def test_the_refresh_button_checks_now_and_replays_the_numbers(self):
        h = self.harness()
        h.seed({"repos": [{"repo": "octo/plug", "pluginId": "io.github.octo.plug", "idChecked": True}]})
        s = h.run(["wait:300", "click:refreshButton", "wait:800"])
        self.assertEqual(s["view"]["reveals"], h.after(0)["view"]["reveals"] + 1, "replayed without reopening")
        self.assertTrue(s["panel"]["opened"])
        self.assertTrue(any(path == "/market/v1/stats" for _, path, _ in self.fake.requests), "and checked")

    def test_a_removed_repo_closes_its_page(self):
        h = self.harness()
        h.seed({"repos": [{"repo": "octo/plug", "idChecked": True}]})
        s = h.run(["open-repo:octo/plug", "click:removeRepoButton", "click:removeRepoButton"])
        self.assertEqual(len(h.after(1)["state"]["repos"]), 1, "the first click only asks")
        self.assertEqual(s["state"]["repos"], [])
        self.assertEqual(s["view"]["page"], "overview")


if __name__ == "__main__":
    unittest.main()
