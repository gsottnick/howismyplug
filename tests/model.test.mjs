// Tests for Model.js. Response shapes follow GitHub's traffic API and the
// marketplace's /v1/stats; the numbers are made up.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
// Model.js is a QML JS library: strip `.pragma library` and collect its
// top-level functions and vars.
const source = readFileSync(join(root, "Model.js"), "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "")
const names = [...source.matchAll(/^(?:function|var)\s+(\w+)/gm)].map((m) => m[1])
const M = new Function(`${source}\nreturn { ${names.join(", ")} }`)()

const DAY = 86400000
const at = (day) => Date.parse(day + "T12:00:00Z")

function clones(days, count, uniques) {
  return JSON.stringify({
    count, uniques,
    clones: Object.entries(days).map(([d, [c, u]]) => ({ timestamp: d + "T00:00:00Z", count: c, uniques: u })),
  })
}

test("repo input: names, URLs, and junk", () => {
  assert.equal(M.normalizeRepo("gsottnick/omatuple"), "gsottnick/omatuple")
  assert.equal(M.normalizeRepo(" https://github.com/gsottnick/omatuple.git/ "), "gsottnick/omatuple")
  assert.equal(M.normalizeRepo("github.com/a-b/c.d_e"), "a-b/c.d_e")
  for (const bad of ["", "omatuple", "a/b/c", "a/..", "a/.", "-a/b", "a b/c", "a/b?x=1", "../etc", "a/b#x", "http://github.com/a/b"])
    assert.equal(M.normalizeRepo(bad), "", bad)
  assert.equal(M.repoPath("a/b.c"), "a/b.c")
})

test("plugin ids follow the marketplace's rule", () => {
  assert.ok(M.validPluginId("io.github.gsottnick.omatuple"))
  for (const bad of ["", ".x", "a b", "__proto__", "Constructor", "x".repeat(129)]) assert.ok(!M.validPluginId(bad), bad)
  assert.equal(M.pluginIdFromManifest('{"id":"io.github.a.b","name":"B"}'), "io.github.a.b")
  assert.equal(M.pluginIdFromManifest('{"id":"bad id"}'), "")
  assert.equal(M.pluginIdFromManifest("not json"), "")
})

test("base64 from the contents API decodes, junk doesn't", () => {
  const manifest = JSON.stringify({ id: "io.github.a.b", name: "Plüg ✓" })
  const b64 = Buffer.from(manifest).toString("base64")
  const wrapped = b64.replace(/(.{60})/g, "$1\n")
  assert.equal(M.decodeBase64(wrapped), manifest)
  assert.equal(M.decodeBase64(""), "")
  assert.equal(M.decodeBase64("abc"), "")
  assert.equal(M.decodeBase64("<script>"), "")
  assert.equal(M.decodeBase64(Buffer.from([0xff, 0xfe]).toString("base64")), "", "not UTF-8")
})

test("traffic responses are sanitized", () => {
  const raw = JSON.stringify({
    count: 551, uniques: 152,
    clones: [
      { timestamp: "2026-10-19T00:00:00Z", count: 40, uniques: 9 },
      { timestamp: "2026-02-30T00:00:00Z", count: 5, uniques: 1 },   // not a date
      { timestamp: "2026-10-20T00:00:00Z", count: -3, uniques: "x" },
      { timestamp: "<b>", count: 1, uniques: 1 },
      "junk",
    ],
  })
  assert.deepEqual(M.parseTraffic(raw, "clones"), {
    days: { "2026-10-19": [40, 9], "2026-10-20": [0, 0] }, count: 551, uniques: 152,
  })
  assert.equal(M.parseTraffic('{"message":"Must have push access"}', "clones"), null)
  assert.equal(M.parseTraffic("<html>", "views"), null)
})

test("marketplace stats: only the ids asked for, only counts", () => {
  const raw = JSON.stringify({ schemaVersion: 1, plugins: {
    "io.github.a.b": { views: 71, copies: 2, hearts: 1, extra: "<script>" },
    "other.plugin": { views: 9 },
  } })
  assert.deepEqual(M.parseMarket(raw, ["io.github.a.b", "missing.id", "__proto__"]), {
    "io.github.a.b": { views: 71, copies: 2, hearts: 1 },
  })
  assert.equal(M.parseMarket("[]", ["a"]), null)
})

test("device flow answers are checked before use", () => {
  const ok = M.parseDeviceCode(JSON.stringify({
    device_code: "3584d83530557fdd1f46af8289938c8ef79f9dc5", user_code: "WDJB-MJHT",
    verification_uri: "https://github.com/login/device", expires_in: 899, interval: 5,
  }))
  assert.deepEqual(ok, { userCode: "WDJB-MJHT", deviceCode: "3584d83530557fdd1f46af8289938c8ef79f9dc5",
    uri: "https://github.com/login/device", intervalMs: 5000, expiresMs: 899000 })
  assert.equal(M.parseDeviceCode(JSON.stringify({ device_code: "a", user_code: "WDJB-MJHT",
    verification_uri: "https://evil.example/login" })), null)
  assert.equal(M.parseDeviceCode(JSON.stringify({ device_code: "a", user_code: "<b>", verification_uri: "https://github.com/x" })), null)

  assert.deepEqual(M.parseTokenPoll('{"access_token":"ghu_abcdefghijklmnopqrstuvwxyz0123","token_type":"bearer"}'),
    { token: "ghu_abcdefghijklmnopqrstuvwxyz0123" })
  assert.deepEqual(M.parseTokenPoll('{"access_token":"ghu_ bad token with spaces"}'), { error: "GitHub sent an unexpected answer" })
  assert.deepEqual(M.parseTokenPoll('{"error":"authorization_pending"}'), { wait: true })
  assert.deepEqual(M.parseTokenPoll('{"error":"slow_down","interval":15}'), { slowDown: true, intervalMs: 15000 })
  assert.deepEqual(M.parseTokenPoll('{"error":"slow_down"}'), { slowDown: true, intervalMs: 10000 })
  assert.deepEqual(M.parseTokenPoll('{"error":"slow_down","interval":99999}'), { slowDown: true, intervalMs: 120000 })
  assert.ok(M.parseTokenPoll('{"error":"expired_token"}').error.includes("expired"))
  assert.ok(M.parseTokenPoll("oops").error)
})

test("re-polling the same window never double counts; the larger value wins", () => {
  const first = M.parseTraffic(clones({ "2026-10-30": [10, 3], "2026-10-31": [4, 2] }, 14, 5), "clones").days
  const again = M.parseTraffic(clones({ "2026-10-31": [9, 3], "2026-11-01": [1, 1] }, 10, 4), "clones").days
  const merged = M.mergeDays(first, again)
  assert.deepEqual(merged, { "2026-10-30": [10, 3], "2026-10-31": [9, 3], "2026-11-01": [1, 1] })
  assert.deepEqual(M.mergeDays(merged, again), merged)
  assert.deepEqual(first["2026-10-31"], [4, 2], "inputs are not mutated")
})

test("period sums by calendar day; 14-day unique is GitHub's own count", () => {
  const today = "2026-11-01"
  const entries = []
  for (let i = 13; i >= 0; i--) entries.push({ timestamp: M.addDays(today, -i) + "T00:00:00Z", count: 10, uniques: 2 })
  let series = M.recordTraffic(null, M.parseTraffic(JSON.stringify({ count: 140, uniques: 11, clones: entries }), "clones"), Date.parse(today + "T12:00:00Z"))
  // Older days kept from earlier checks.
  for (let i = 14; i < 40; i++) series.days[M.addDays(today, -i)] = [10, 2]
  assert.equal(M.trafficFor(series, "7d", today).count, 70)
  assert.deepEqual(M.trafficFor(series, "14d", today), { count: 140, uniques: 11, exactUniques: true })
  assert.equal(M.trafficFor(series, "30d", today).count, 300)
  assert.equal(M.trafficFor(series, "all", today).count, 400)
  assert.equal(M.trafficFor(series, "all", today).uniques, 11, "tracking started with this window: GitHub's number for it")
  assert.deepEqual(M.trafficFor(null, "7d", today), { count: 0, uniques: 0, exactUniques: false })
})

test("marketplace periods are growth since the snapshot before the period", () => {
  let market = null
  market = M.recordMarket(market, { views: 50, copies: 1, hearts: 0 }, "2026-10-20")
  market = M.recordMarket(market, { views: 60, copies: 2, hearts: 1 }, "2026-10-25")
  market = M.recordMarket(market, { views: 80, copies: 5, hearts: 1 }, "2026-11-01")
  market = M.recordMarket(market, { views: 90, copies: 6, hearts: 2 }, "2026-11-01")
  assert.deepEqual(market.snaps["2026-11-01"], { views: 80, copies: 5, hearts: 1 }, "first reading of the day is kept")
  assert.deepEqual(M.marketFor(market, "all", "2026-11-01"), { views: 90, copies: 6, hearts: 2 })
  assert.deepEqual(M.marketFor(market, "7d", "2026-11-01"), { views: 30, copies: 4, hearts: 1 })
  // Nothing older than the period: growth since tracking started.
  assert.deepEqual(M.marketFor(market, "30d", "2026-11-01"), { views: 40, copies: 5, hearts: 2 })
})

test("totals across repos and the bar metric", () => {
  const today = "2026-11-01"
  const repos = [
    { clones: { days: { [today]: [5, 2] } }, views: { days: { [today]: [7, 3] } }, market: { current: { views: 4, copies: 1, hearts: 1 }, snaps: {} } },
    { clones: { days: { [today]: [1, 1] } }, views: null, market: null },
  ]
  const t = M.totalsFor(repos, "all", today)
  assert.equal(t.clones.count, 6)
  assert.equal(t.views.count, 7)
  assert.deepEqual(t.market, { views: 4, copies: 1, hearts: 1 })
  assert.equal(M.metricValue(t, "clones"), 6)
  assert.equal(M.metricValue(t, "views"), 7)
  assert.equal(M.metricValue(t, "copies"), 1)
  assert.equal(M.metricValue(t, "nonsense"), 6)

  // A fork with the same plugin id: its traffic counts, the shared listing doesn't count twice.
  const listing = { current: { views: 4, copies: 1, hearts: 1 }, snaps: {} }
  const forked = M.totalsFor([
    { pluginId: "io.x.plug", clones: { days: { [today]: [5, 2] } }, market: listing },
    { pluginId: "io.x.plug", clones: { days: { [today]: [3, 1] } }, market: listing },
  ], "all", today)
  assert.equal(forked.clones.count, 8)
  assert.deepEqual(forked.market, { views: 4, copies: 1, hearts: 1 })
  // The fork listed first, before its listing numbers arrived: the original's still count.
  const early = M.totalsFor([
    { pluginId: "io.x.plug", clones: null, market: null },
    { pluginId: "io.x.plug", clones: null, market: listing },
  ], "all", today)
  assert.deepEqual(early.market, { views: 4, copies: 1, hearts: 1 })
})

test("milestones: silent first run, one celebration for the newest", () => {
  assert.deepEqual(M.checkMilestone(250, 100, -1), { seen: 2, celebrate: 0 })
  assert.deepEqual(M.checkMilestone(299, 100, 2), { seen: 2, celebrate: 0 })
  assert.deepEqual(M.checkMilestone(512, 100, 2), { seen: 5, celebrate: 500 })
  assert.deepEqual(M.checkMilestone(512, 0, 2), { seen: 512, celebrate: 512 }, "step is at least 1")
})

test("poll schedule and missed days", () => {
  const now = at("2026-11-01")
  assert.equal(M.pollDelay(0, "daily", now), 0)
  assert.equal(M.pollDelay(now - 3600000, "daily", now), 23 * 3600000)
  assert.equal(M.pollDelay(now - 2 * DAY, "daily", now), 0)
  assert.equal(M.pollDelay(now + DAY, "hourly", now), 0, "a clock that went backwards polls now")
  assert.equal(M.pollEveryMs("biweekly"), 13 * DAY)
  assert.equal(M.pollEveryMs("bogus"), DAY)

  assert.equal(M.missedRange(0, now), "")
  assert.equal(M.missedRange(at("2026-10-19"), now), "", "the window still reaches back to the day after")
  assert.equal(M.missedRange(at("2026-10-18"), now), "")
  assert.equal(M.missedRange(at("2026-10-17"), now), "2026-10-18")
  assert.equal(M.missedRange(at("2026-10-01"), now), "2026-10-02 – 2026-10-18")
})

test("the state file is cleaned on load", () => {
  const s = M.cleanState(JSON.stringify({
    lastPoll: 5, authMethod: "token", seen: { clones: 3, evil: 1 },
    repos: [
      { repo: "a/b", pluginId: "io.x.y", idChecked: true, access: "ok",
        clones: { days: { "2026-11-01": [3, 1], "bad": [1, 1], "2026-11-02": "x" }, last14: { count: 3, uniques: 1 }, last14Day: "2026-11-01" },
        market: { current: { views: 2, copies: 0, hearts: 0 }, snaps: { "2026-11-01": { views: 2 }, "x": {} } } },
      { repo: "A/B" },
      { repo: "../etc" },
      { repo: "c/d", pluginId: "bad id", access: "hacked" },
    ],
  }))
  assert.equal(s.authMethod, "token")
  assert.deepEqual(s.seen, { clones: 3 })
  assert.deepEqual(s.repos.map((r) => r.repo), ["a/b", "c/d"])
  // A file from 0.1.0: the window is recovered, and lifetime counting starts from its number.
  assert.deepEqual(s.repos[0].clones, { days: { "2026-11-01": [3, 1] },
    last14: { count: 3, uniques: 1, end: "2026-11-01" }, first: { uniques: 1, end: "2026-11-01" } })
  assert.deepEqual(Object.keys(s.repos[0].market.snaps), ["2026-11-01"])
  assert.equal(s.repos[1].pluginId, "")
  assert.equal(s.repos[1].access, "")
  assert.deepEqual(M.cleanState("garbage").repos, [])
})

test("formatting", () => {
  assert.equal(M.compact(9999), "9999")
  assert.equal(M.compact(12345), "12.3K")
  assert.equal(M.compact(250000), "250K")
  assert.equal(M.compact(1200000), "1.2M")
  assert.equal(M.grouped(1234567), "1,234,567")
  assert.equal(M.countText(551, 152, "both"), "551 · 152")
  assert.equal(M.countText(551, 152, "unique"), "152")
  assert.equal(M.periodLabel("all"), "All time")
  assert.equal(M.countWords(1406, 383, "both", "clones"), "1,406 clones (383 unique)")
  assert.equal(M.countWords(1406, 383, "unique", "views"), "383 unique views")
  assert.equal(M.countWords(1406, 383, "total", "clones"), "1,406 clones")
})

test("per-repo schedule: each repo is due on its own interval", () => {
  const now = at("2026-11-01")
  const repos = [
    { repo: "a/hourly", checkGithub: "hourly", lastGithub: now - 2 * 3600000, checkListing: "weekly", lastListing: now - DAY, pluginId: "io.a" },
    { repo: "a/daily", checkGithub: "daily", lastGithub: now - 3600000, checkListing: "daily", lastListing: 0, pluginId: "" },
  ]
  assert.deepEqual(M.dueRepos(repos, "github", now), ["a/hourly"])
  assert.deepEqual(M.dueRepos(repos, "listing", now), ["a/daily"])
  assert.equal(M.nextDelay(repos, now, true), 0)
  // Signed out: only listing checks count, and only for repos with a plugin id.
  assert.equal(M.nextDelay(repos, now, false), 6 * DAY)
  assert.equal(M.nextDelay([], now, true), -1)
})

test("new repos take the defaults; stored per-repo options are cleaned", () => {
  const r = M.newRepo("a/b", 5, { checkGithub: "weekly", checkListing: "nonsense" })
  assert.equal(r.checkGithub, "weekly")
  assert.equal(r.checkListing, "daily")
  assert.deepEqual(r.milestone, { on: true, metric: "clones", step: 100 })
  const s = M.cleanState({ repos: [{ repo: "a/b", checkGithub: "hourly", milestone: { on: false, metric: "hearts", step: -4 },
    seen: { copies: 3, evil: 1 }, missed: "<b>", lastGithub: 7 }] })
  const c = s.repos[0]
  assert.equal(c.checkGithub, "hourly")
  assert.deepEqual(c.milestone, { on: false, metric: "hearts", step: 100 })
  assert.deepEqual(c.seen, { copies: 3 })
  assert.equal(c.missed, "")
  assert.equal(c.lastGithub, 7)
})

test("the bar number: any stat, all repos or one", () => {
  const today = "2026-11-01"
  const repos = [
    { repo: "a/one", clones: { days: { [today]: [5, 2] } }, views: { days: { [today]: [9, 4] } }, pluginId: "io.one",
      market: { current: { views: 70, copies: 3, hearts: 1 }, snaps: {} } },
    { repo: "a/two", clones: { days: { [today]: [1, 1] } }, views: null, market: null },
  ]
  assert.equal(M.barValue(repos, "all", "clones", today), 6)
  assert.equal(M.barValue(repos, "a/one", "views", today), 9)
  assert.equal(M.barValue(repos, "a/two", "listingViews", today), 0)
  assert.equal(M.barValue(repos, "a/gone", "clones", today), 6, "a removed repo falls back to all")
})

test("milestones: per repo and combined, first sight silent, combined can be off", () => {
  const today = "2026-11-01"
  const repo = (name, clones, milestone, seen) => ({ repo: name, clones: { days: { [today]: [clones, 1] } }, milestone, seen })
  const repos = [
    repo("a/one", 250, { on: true, metric: "clones", step: 100 }, { clones: 1 }),
    repo("a/two", 40, { on: true, metric: "clones", step: 10 }, {}),
    repo("a/off", 999, { on: false, metric: "clones", step: 1 }, { clones: 0 }),
  ]
  const r = M.milestoneCheck(repos, { on: true, metric: "clones", step: 1000 }, { clones: 0 }, today)
  assert.deepEqual(r.celebrations, [{ repo: "a/one", metric: "clones", value: 200 }, { repo: "", metric: "clones", value: 1000 }])
  assert.deepEqual(r.seen, { "a/one": { clones: 2 }, "a/two": { clones: 4 }, "": { clones: 1 } })
  const off = M.milestoneCheck(repos, { on: false, metric: "clones", step: 1000 }, { clones: 0 }, today)
  assert.ok(!off.celebrations.some((c) => c.repo === ""), "combined off: no combined milestone")
})
