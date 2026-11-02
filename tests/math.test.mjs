// Proof that the history adds up. GitHub only ever shows its latest 14 days
// (ending today or a day or two before, the newest day still growing), and the
// window rolls: each day one day comes in and the oldest drops out. These
// tests build a known truth of individual people cloning, play GitHub's window
// against it on every schedule the plugin offers (driven by the plugin's own
// scheduler), store each answer exactly as PlugStore does
// (Model.recordTraffic), and compare.
//
// What must hold:
// - Clone counts: every day counted once. Totals for any period equal the truth.
// - Unique: lifetime = GitHub's 14-day number at the first check + each later
//   day's unique number (as GitHub reports it for that day). 14 days = GitHub's
//   own number. Never goes down; nothing lost unless no check for 14+ days.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const source = readFileSync(join(root, "Model.js"), "utf8").replace(/^\s*\.pragma\s+library\s*$/m, "")
const names = [...source.matchAll(/^(?:function|var)\s+(\w+)/gm)].map((m) => m[1])
const M = new Function(`${source}\nreturn { ${names.join(", ")} }`)()

const DAY = 86400000
const HOUR = 3600000
const START = Date.UTC(2026, 6, 1)          // day 0 of the made-up history
const DAYS = 150

function rng(seed) {
  let s = seed >>> 0
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32)
}

// The truth: for each day and hour, the people who cloned (with repeats).
// A pool of regulars returns often; new people show up too.
function makeTruth(seed, { pool = 60, busy = 1 } = {}) {
  const r = rng(seed)
  let next = pool
  const days = []
  for (let d = 0; d < DAYS; d++) {
    const hours = []
    for (let h = 0; h < 24; h++) {
      const events = []
      const n = Math.floor(r() * 4 * busy)
      for (let i = 0; i < n; i++) events.push(r() < 0.7 ? Math.floor(r() * pool) : next++)
      hours.push(events)
    }
    days.push({ key: M.dayKey(START + d * DAY), hours })
  }
  return days
}

const emptyTruth = () => Array.from({ length: DAYS }, (_, d) => ({ key: M.dayKey(START + d * DAY), hours: Array.from({ length: 24 }, () => []) }))
const upTo = (day, hour) => day.hours.slice(0, hour + 1).flat()
const people = (events) => new Set(events).size
const dayOf = (t) => Math.floor((t - START) / DAY)
const hourOf = (t) => Math.floor(((t - START) % DAY) / HOUR)

// GitHub's answer at time t: the 14 days ending `lag` days before today. The
// newest day is still growing when it is today; older days are complete.
function githubAt(truth, t, lag = 0) {
  const today = dayOf(t), hour = hourOf(t)
  const end = Math.min(today - lag, DAYS - 1)
  const list = [], window = []
  for (let d = end - 13; d <= end; d++) {
    if (d < 0) continue
    const events = d === today ? upTo(truth[d], hour) : truth[d].hours.flat()
    window.push(...events)
    list.push({ timestamp: truth[d].key + "T00:00:00Z", count: events.length, uniques: people(events) })
  }
  return JSON.stringify({ count: list.reduce((a, e) => a + e.count, 0), uniques: people(window), clones: list })
}

const countDays = (truth, from, to) => truth.slice(from, to + 1).reduce((a, d) => a + d.hours.flat().length, 0)

// A day's count / unique number as GitHub last showed it by time lastT.
const dayCount = (truth, d, lastT) => (d === dayOf(lastT) ? upTo(truth[d], hourOf(lastT)) : truth[d].hours.flat()).length
const dayUniques = (truth, d, lastT) => people(d === dayOf(lastT) ? upTo(truth[d], hourOf(lastT)) : truth[d].hours.flat())

// Run the plugin's own scheduler from `first` to `until`: check when it says a check is due.
function runScheduler(truth, { every, first, until, lag = 0, off = () => false }) {
  const repo = { repo: "a/b", checkGithub: every, lastGithub: 0, clones: null, pluginId: "" }
  const seen = []
  let t = first, lastT = 0
  while (t <= until) {
    if (!off(t)) {
      repo.clones = M.recordTraffic(repo.clones, M.parseTraffic(githubAt(truth, t, lag), "clones"), t)
      repo.lastGithub = t
      lastT = t
      seen.push(M.uniquesFor(repo.clones, "all", M.dayKey(t)))
    }
    t += Math.max(M.nextDelay([repo], t, true), 60000)
  }
  return { series: repo.clones, seen, lastT }
}

const dayIdx = (truth, key) => M.dayIndex(key) - M.dayIndex(truth[0].key)

// What lifetime unique must be: the first window's number, then each later day's.
function expectedLifetime(truth, series, lastT) {
  let total = series.first.uniques
  for (let d = dayIdx(truth, series.first.end) + 1; d <= dayIdx(truth, series.last14.end); d++) total += dayUniques(truth, d, lastT)
  return total
}

function expectedCount(truth, series, lastT) {
  let total = 0
  for (let d = dayIdx(truth, series.first.end) - 13; d <= dayIdx(truth, series.last14.end); d++) total += dayCount(truth, d, lastT)
  return total
}

for (const every of ["hourly", "daily", "twodays", "weekly", "biweekly"]) {
  for (const lag of [0, 1, 2]) {
    test(`${every} checks, GitHub ${lag} day(s) behind: counts and lifetime unique add up exactly`, () => {
      const truth = makeTruth(every.length * 10 + lag)
      const first = START + 20 * DAY + 9 * HOUR
      const until = START + 130 * DAY + 2 * HOUR
      const { series, seen, lastT } = runScheduler(truth, { every, first, until, lag })
      const firstEnd = dayOf(first) - lag
      assert.equal(series.first.end, truth[firstEnd].key, "counting starts at the first window GitHub showed")
      // The first window's number is GitHub's own for it (from its most complete reading).
      assert.ok(series.first.uniques > 0 && series.first.uniques <= people(truth.slice(firstEnd - 13, firstEnd + 1).flatMap((d) => d.hours.flat())))
      assert.equal(M.trafficFor(series, "all", M.dayKey(until)).count, expectedCount(truth, series, lastT))
      assert.equal(M.uniquesFor(series, "all", M.dayKey(until)), expectedLifetime(truth, series, lastT))
      // 14 days: exactly GitHub's number at the final check.
      assert.equal(M.uniquesFor(series, "14d", M.dayKey(until)), JSON.parse(githubAt(truth, lastT, lag)).uniques)
      for (let i = 1; i < seen.length; i++) assert.ok(seen[i] >= seen[i - 1], `dropped from ${seen[i - 1]} to ${seen[i]} at check ${i}`)
    })
  }
}

test("Gavin's example: 100 when installed, then 20 more people over the next days = 120", () => {
  const truth = emptyTruth()
  for (let p = 0; p < 100; p++) truth[p % 14].hours[10].push(p)
  for (let p = 0; p < 20; p++) truth[14 + (p % 14)].hours[10].push(1000 + p)
  let series = null
  const values = []
  for (let d = 13; d <= 28; d++) {
    const t = START + d * DAY + 22 * HOUR
    series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, t), "clones"), t)
    values.push(M.uniquesFor(series, "all", M.dayKey(t)))
  }
  assert.equal(values[0], 100)
  assert.equal(values[values.length - 1], 120)
  for (let i = 1; i < values.length; i++) assert.ok(values[i] >= values[i - 1])
})

test("computer off for two days: the next check fills in both days by their dates", () => {
  const truth = makeTruth(77)
  const t1 = START + 40 * DAY + 20 * HOUR, t2 = START + 43 * DAY + 9 * HOUR   // off on days 41 and 42
  let series = M.recordTraffic(null, M.parseTraffic(githubAt(truth, t1), "clones"), t1)
  assert.equal(series.days[truth[41].key], undefined)
  series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, t2), "clones"), t2)
  for (const d of [40, 41, 42]) {
    assert.equal(series.days[truth[d].key][0], truth[d].hours.flat().length, `day ${d} count`)
    assert.equal(series.days[truth[d].key][1], people(truth[d].hours.flat()), `day ${d} unique`)
  }
  assert.equal(M.uniquesFor(series, "all", truth[43].key), expectedLifetime(truth, series, t2))
})

test("computer off for days at a time: nothing lost while every gap is under 14 days", () => {
  for (let seed = 1; seed <= 15; seed++) {
    const truth = makeTruth(500 + seed)
    const r = rng(seed)
    const offDays = new Set(Array.from({ length: 40 }, () => 25 + Math.floor(r() * 100)))
    const until = START + 140 * DAY + 3 * HOUR
    const { series, seen, lastT } = runScheduler(truth, { every: "daily", first: START + 20 * DAY + 9 * HOUR, until, off: (t) => offDays.has(dayOf(t)) })
    assert.equal(M.uniquesFor(series, "all", M.dayKey(until)), expectedLifetime(truth, series, lastT), `seed ${seed}`)
    assert.equal(M.trafficFor(series, "all", M.dayKey(until)).count, expectedCount(truth, series, lastT), `seed ${seed}: counts`)
    for (let i = 1; i < seen.length; i++) assert.ok(seen[i] >= seen[i - 1], `seed ${seed}: dropped`)
  }
})

test("checking the same moment twice, or a hundred times, changes nothing", () => {
  const truth = makeTruth(7)
  const t = START + 50 * DAY + 12 * HOUR
  const once = M.recordTraffic(null, M.parseTraffic(githubAt(truth, t), "clones"), t)
  let many = null
  for (let i = 0; i < 100; i++) many = M.recordTraffic(many, M.parseTraffic(githubAt(truth, t), "clones"), t)
  assert.deepEqual(many, once)
})

test("a day's growing count is replaced, not added, as the day goes on", () => {
  const truth = makeTruth(8)
  const day = START + 60 * DAY
  let series = null
  for (const h of [1, 9, 17, 23.9]) series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, day + h * HOUR), "clones"), day + h * HOUR)
  assert.equal(series.days[M.dayKey(day)][0], truth[60].hours.flat().length)
  assert.equal(series.days[M.dayKey(day)][1], people(truth[60].hours.flat()))
})

test("a gap longer than 14 days: what GitHub dropped is missing (and reported), nothing is invented", () => {
  const truth = makeTruth(9)
  const before = START + 30 * DAY + 10 * HOUR
  const after = START + 60 * DAY + 10 * HOUR          // 30 days later: days 31..46 are gone from GitHub
  let series = M.recordTraffic(null, M.parseTraffic(githubAt(truth, before), "clones"), before)
  series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, after), "clones"), after)
  assert.equal(M.missedRange(before, after), M.dayKey(START + 31 * DAY) + " – " + M.dayKey(START + 46 * DAY))
  for (let d = 31; d <= 46; d++) assert.equal(series.days[truth[d].key], undefined, `day ${d} not made up`)
  // Day 30 was read at 10:00 and then fell out of the window: its partial count is all there is.
  const expected = countDays(truth, 17, 29) + upTo(truth[30], 10).length + countDays(truth, 47, 59) + upTo(truth[60], 10).length
  assert.equal(M.trafficFor(series, "all", M.dayKey(after)).count, expected)
})

test("periods count by calendar day; 14 days unique is GitHub's own number; shorter periods never exceed lifetime", () => {
  const truth = makeTruth(11)
  let series = null
  for (let d = 13; d <= 70; d++) {
    const t = START + d * DAY + 23.5 * HOUR
    series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, t), "clones"), t)
  }
  const today = truth[70].key
  assert.equal(M.trafficFor(series, "7d", today).count, countDays(truth, 64, 70))
  assert.equal(M.trafficFor(series, "30d", today).count, countDays(truth, 41, 70))
  assert.equal(M.trafficFor(series, "14d", today).uniques, people(truth.slice(57, 71).flatMap((d) => d.hours.flat())))
  let sum7 = 0
  for (let d = 64; d <= 70; d++) sum7 += people(truth[d].hours.flat())
  assert.equal(M.trafficFor(series, "7d", today).uniques, sum7, "7 days: each day's unique number added up")
  const all = M.trafficFor(series, "all", today).uniques
  assert.ok(M.trafficFor(series, "30d", today).uniques <= all && sum7 <= all)
})

test("combined totals add each repo once, and a shared listing once", () => {
  const today = "2026-11-01"
  const a = { repo: "a/a", pluginId: "io.a", clones: { days: { [today]: [5, 2], "2026-10-31": [3, 1] } }, views: null,
    market: { current: { views: 10, copies: 1, hearts: 0 }, snaps: {} } }
  const b = { repo: "a/b", pluginId: "io.b", clones: { days: { [today]: [7, 3] } }, views: null,
    market: { current: { views: 4, copies: 0, hearts: 2 }, snaps: {} } }
  const fork = { ...a, repo: "a/a-fork", clones: { days: { [today]: [1, 1] } } }
  const t = M.totalsFor([a, b, fork], "all", today)
  assert.equal(t.clones.count, 5 + 3 + 7 + 1)
  assert.deepEqual(t.market, { views: 14, copies: 1, hearts: 2 })
})

test("Gavin's real omatuple numbers: 152 when first checked, + 46 on 11/01 = 198; 14 days = GitHub's 191", () => {
  const first = { "2026-10-18": [0, 0], "2026-10-19": [1, 1], "2026-10-20": [0, 0], "2026-10-21": [0, 0], "2026-10-22": [1, 1],
    "2026-10-23": [1, 1], "2026-10-24": [1, 1], "2026-10-25": [0, 0], "2026-10-26": [1, 1], "2026-10-27": [0, 0],
    "2026-10-28": [0, 0], "2026-10-29": [45, 18], "2026-10-30": [197, 50], "2026-10-31": [304, 99] }
  const answer = (days, count, uniques) => JSON.stringify({ count, uniques,
    clones: Object.entries(days).map(([d, [c, u]]) => ({ timestamp: d + "T00:00:00Z", count: c, uniques: u })) })
  let s = M.recordTraffic(null, M.parseTraffic(answer(first, 551, 152), "clones"), Date.UTC(2026, 10, 1, 1))
  assert.equal(M.uniquesFor(s, "all", "2026-11-01"), 152)
  const next = { ...first, "2026-11-01": [128, 46] }
  delete next["2026-10-18"]
  s = M.recordTraffic(s, M.parseTraffic(answer(next, 679, 191), "clones"), Date.UTC(2026, 10, 2, 12))
  assert.equal(M.uniquesFor(s, "all", "2026-11-02"), 198)
  assert.equal(M.uniquesFor(s, "14d", "2026-11-02"), 191)
  assert.equal(M.trafficFor(s, "14d", "2026-11-02").count, 679, "14 days = GitHub's own window, even though it ends on 11/01")
  assert.equal(M.trafficFor(s, "all", "2026-11-02").count, 551 + 128)
  // A file from 0.1.0 starts lifetime counting from the 14-day number it kept.
  const migrated = M.cleanSeries({ days: next, last14: { count: 679, uniques: 191 }, last14Day: "2026-11-02" })
  assert.equal(M.uniquesFor(migrated, "all", "2026-11-02"), 191)
})

test("a new repo's first answer can run ahead with nothing counted: the settled window is the start (seen live)", () => {
  const answer = (days, count, uniques) => JSON.stringify({ count, uniques,
    clones: Object.entries(days).map(([d, [c, u]]) => ({ timestamp: d + "T00:00:00Z", count: c, uniques: u })) })
  const zeros = {}
  for (let i = 0; i < 14; i++) zeros[M.addDays("2026-11-02", -i)] = [0, 0]
  let s = M.recordTraffic(null, M.parseTraffic(answer(zeros, 0, 0), "clones"), Date.UTC(2026, 10, 2, 11))
  const real = {}
  for (let i = 0; i < 14; i++) real[M.addDays("2026-11-01", -i)] = [0, 0]
  real["2026-11-01"] = [17, 8]
  s = M.recordTraffic(s, M.parseTraffic(answer(real, 17, 8), "clones"), Date.UTC(2026, 10, 2, 12))
  assert.deepEqual(s.first, { uniques: 8, end: "2026-11-01" })
  assert.equal(M.uniquesFor(s, "all", "2026-11-02"), 8)
  assert.equal(M.uniquesFor(s, "14d", "2026-11-02"), 8)
  assert.equal(M.trafficFor(s, "all", "2026-11-02").count, 17)
})
