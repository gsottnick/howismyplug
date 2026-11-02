// Proof that the history adds up. GitHub only ever shows its latest 14 days
// (ending today or a day or two before, the newest day still growing), so
// every check overlaps earlier ones. These tests build a known truth of
// individual people cloning, play GitHub's window against it on every
// schedule the plugin offers (driven by the plugin's own scheduler), store
// each answer exactly as PlugStore does (Model.recordTraffic), and compare.
//
// What must hold:
// - Clone counts: every day counted once. Totals for any period equal the truth.
// - Unique people: lifetime = sum of back-to-back 14-day blocks from the first
//   day tracked, each block = how many different people came in it (GitHub's
//   own 14-day count for that window). Never more than that, ever: no person
//   is counted twice within a block. Exact when the block's last reading saw
//   the whole block (GitHub a day behind, or the 23:55 check). Never goes down.

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

const upTo = (day, hour) => day.hours.slice(0, hour + 1).flat()
const people = (events) => new Set(events).size

// GitHub's answer at time t: the 14 days ending `lag` days before today. The
// newest day is still growing when it is today; older days are complete.
function githubAt(truth, t, lag = 0) {
  const today = Math.floor((t - START) / DAY)
  const hour = Math.floor(((t - START) % DAY) / HOUR)
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

const blockPeople = (truth, from, to) => people(truth.slice(from, to + 1).flatMap((d) => d.hours.flat()))
const countDays = (truth, from, to) => truth.slice(from, to + 1).reduce((a, d) => a + d.hours.flat().length, 0)

// Run the plugin's own scheduler from `first` to `until`: check when it says
// a check is due (its interval, plus the hourly boundary watch).
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
    const wait = M.nextDelay([repo], t, true)
    t += Math.max(wait, 60000)
  }
  return { series: repo.clones, seen, lastT }
}

// Clones from day `from` through GitHub's last day, as of the final check at
// `lastT`: earlier days complete, the last day only so far if it was today.
function countThrough(truth, from, lastEnd, lastT) {
  const today = Math.floor((lastT - START) / DAY)
  const hour = Math.floor(((lastT - START) % DAY) / HOUR)
  const last = lastEnd === today ? upTo(truth[lastEnd], hour).length : truth[lastEnd].hours.flat().length
  return countDays(truth, from, lastEnd - 1) + last
}

// The window GitHub showed at the first check: where tracking starts.
const anchorDay = (first, lag) => Math.floor((first - START) / DAY) - lag - 13

function expectedUnique(truth, anchor, lastEnd) {
  let total = 0
  for (let b = anchor; b + 13 <= lastEnd; b += 14) total += blockPeople(truth, b, b + 13)
  return total
}

for (const every of ["hourly", "daily", "weekly", "biweekly"]) {
  for (const lag of [0, 1, 2]) {
    test(`${every} checks, GitHub ${lag} day(s) behind: counts and unique people are exact`, () => {
      const truth = makeTruth(every.length * 10 + lag)
      const first = START + 20 * DAY + 9 * HOUR
      const anchor = anchorDay(first, lag)
      // Stop when GitHub's window has just finished a block (the block's last day complete).
      const lastBlockEnd = anchor + 14 * 8 - 1
      const until = START + (lastBlockEnd + lag + 1) * DAY + 2 * HOUR
      const { series, seen, lastT } = runScheduler(truth, { every, first, until, lag })

      assert.equal(series.anchor, truth[anchor].key)
      const lastEnd = M.dayIndex(series.last14.end) - M.dayIndex(truth[0].key)
      // Clone counts: every day from the anchor through GitHub's last day, once
      // (that last day as far as GitHub had counted it at the final check).
      assert.equal(M.trafficFor(series, "all", M.dayKey(until)).count, countThrough(truth, anchor, lastEnd, lastT))
      // Unique people: every finished block exactly (checked one by one), plus
      // the block in progress as a lower bound of its real count.
      for (let k = 0, b = anchor; b + 13 <= lastBlockEnd; k++, b += 14)
        assert.equal(M.blockValue(series, k), blockPeople(truth, b, b + 13), `block ${k}`)
      const done = expectedUnique(truth, anchor, lastBlockEnd)
      const got = M.uniquesFor(series, "all", M.dayKey(until))
      const inProgress = lastEnd > lastBlockEnd ? blockPeople(truth, lastBlockEnd + 1, lastEnd) : 0
      assert.ok(got >= done && got <= done + inProgress, `${got} should be ${done} plus at most ${inProgress}`)
      // 14 days: exactly GitHub's own number at the final check.
      assert.equal(M.uniquesFor(series, "14d", M.dayKey(until)), JSON.parse(githubAt(truth, lastT, lag)).uniques)
      // Never goes down.
      for (let i = 1; i < seen.length; i++) assert.ok(seen[i] >= seen[i - 1], `dropped from ${seen[i - 1]} to ${seen[i]} at check ${i}`)
    })
  }
}

test("Gavin's example: 100 people in the first 14 days, then 20 in the next 14 = 120 lifetime", () => {
  // Block 0: 100 different people. Block 1: 20 people, half of them returning.
  const truth = Array.from({ length: DAYS }, (_, d) => ({ key: M.dayKey(START + d * DAY), hours: Array.from({ length: 24 }, () => []) }))
  for (let p = 0; p < 100; p++) truth[p % 14].hours[10].push(p)
  for (let p = 0; p < 20; p++) truth[14 + (p % 14)].hours[10].push(p < 10 ? p : 1000 + p)
  let series = null
  const values = []
  for (let d = 13; d <= 28; d++) {                       // a check late every day
    const t = START + d * DAY + 22 * HOUR
    series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, t), "clones"), t)
    values.push(M.uniquesFor(series, "all", M.dayKey(t)))
  }
  assert.equal(values[0], 100, "at sign-in: GitHub's 14-day number")
  assert.equal(values[14], 120, "when the second block completes")
  for (let i = 1; i < values.length; i++) assert.ok(values[i] >= values[i - 1])
  assert.ok(values.slice(1, 14).every((v) => v >= 100 && v <= 120), "in between it rises toward 120")
})

test("missed boundary readings (computer off) can only undercount, never overcount", () => {
  for (let seed = 1; seed <= 15; seed++) {
    const truth = makeTruth(500 + seed)
    const r = rng(seed)
    const offDays = new Set(Array.from({ length: 40 }, () => 20 + Math.floor(r() * 110)))
    const first = START + 20 * DAY + 9 * HOUR
    const until = START + 140 * DAY + 3 * HOUR
    const { series, seen, lastT } = runScheduler(truth, { every: "daily", first, until, off: (t) => offDays.has(Math.floor((t - START) / DAY)) })
    // Tracking starts at the first check that happened (the first day might have been an off day).
    const anchor = M.dayIndex(series.anchor) - M.dayIndex(truth[0].key)
    const lastEnd = M.dayIndex(series.last14.end) - M.dayIndex(truth[0].key)
    const finished = Math.floor((lastEnd - anchor + 1) / 14) * 14 + anchor - 1
    const upper = expectedUnique(truth, anchor, finished) + (lastEnd > finished ? blockPeople(truth, finished + 1, lastEnd) : 0)
    assert.ok(M.uniquesFor(series, "all", M.dayKey(until)) <= upper, `seed ${seed}: overcounted`)
    for (let i = 1; i < seen.length; i++) assert.ok(seen[i] >= seen[i - 1], `seed ${seed}: dropped`)
    // Clone counts stay exact as long as no gap reaches 14 days.
    assert.equal(M.trafficFor(series, "all", M.dayKey(until)).count, countThrough(truth, anchor, lastEnd, lastT), `seed ${seed}: counts`)
  }
})

test("GLM's case: a returner after the block's last reading is not counted twice", () => {
  // Block 0 = days 0..13. A comes on day 2 and again late on day 13; B comes early on day 13.
  const truth = Array.from({ length: DAYS }, (_, d) => ({ key: M.dayKey(START + d * DAY), hours: Array.from({ length: 24 }, () => []) }))
  truth[2].hours[9].push("A")
  truth[13].hours[1].push("B")
  truth[13].hours[23].push("A")
  let series = null
  // Readings on day 13 at 22:00 (A's second visit not yet seen), then day 14 (window moved on).
  for (const t of [START + 13 * DAY + 22 * HOUR, START + 14 * DAY + 3 * HOUR])
    series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, t), "clones"), t)
  assert.equal(M.blockValue(series, 0), 2, "two different people in block 0")
  assert.equal(M.uniquesFor(series, "all", truth[14].key), 2)
})

test("a new person in a block's last minutes, after the 23:55 check, is the only possible miss", () => {
  const truth = Array.from({ length: DAYS }, (_, d) => ({ key: M.dayKey(START + d * DAY), hours: Array.from({ length: 24 }, () => []) }))
  truth[5].hours[9].push("A")
  truth[13].hours[1].push("B")
  // The scheduler's own boundary checks run; a 23:55 reading sees everyone who came before then.
  const { series } = runScheduler(truth, { every: "weekly", first: START + 13 * DAY + 2 * HOUR, until: START + 15 * DAY })
  assert.equal(M.blockValue(series, 0), 2)
})

test("checking the same moment twice, or a hundred times, changes nothing", () => {
  const truth = makeTruth(7)
  const t = START + 50 * DAY + 12 * HOUR
  const once = M.recordTraffic(null, M.parseTraffic(githubAt(truth, t), "clones"), t)
  let many = null
  for (let i = 0; i < 100; i++) many = M.recordTraffic(many, M.parseTraffic(githubAt(truth, t), "clones"), t)
  assert.deepEqual(many, once)
})

test("today's growing count is replaced, not added, as the day goes on", () => {
  const truth = makeTruth(8)
  const day = START + 60 * DAY
  let series = null
  for (const h of [1, 9, 17, 23.9]) series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, day + h * HOUR), "clones"), day + h * HOUR)
  assert.equal(series.days[M.dayKey(day)][0], truth[60].hours.flat().length)
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

test("periods count by calendar day; 14 days unique is GitHub's own number", () => {
  const truth = makeTruth(11)
  let series = null
  for (let d = 13; d <= 70; d++) {
    const t = START + d * DAY + 23.5 * HOUR
    series = M.recordTraffic(series, M.parseTraffic(githubAt(truth, t), "clones"), t)
  }
  const today = truth[70].key
  assert.equal(M.trafficFor(series, "7d", today).count, countDays(truth, 64, 70))
  assert.equal(M.trafficFor(series, "30d", today).count, countDays(truth, 41, 70))
  assert.equal(M.trafficFor(series, "14d", today).uniques, blockPeople(truth, 57, 70))
  // 7 and 30 days: never more than the people who really came in those days.
  assert.ok(M.trafficFor(series, "7d", today).uniques <= blockPeople(truth, 64, 70))
  assert.ok(M.trafficFor(series, "30d", today).uniques >= blockPeople(truth, 57, 70) - blockPeople(truth, 57, 63) - 0)
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

test("Gavin's real omatuple numbers: 152 unique, not 172", () => {
  const days = { "2026-10-18": [0, 0], "2026-10-19": [1, 1], "2026-10-20": [0, 0], "2026-10-21": [0, 0], "2026-10-22": [1, 1],
    "2026-10-23": [1, 1], "2026-10-24": [1, 1], "2026-10-25": [0, 0], "2026-10-26": [1, 1], "2026-10-27": [0, 0],
    "2026-10-28": [0, 0], "2026-10-29": [45, 18], "2026-10-30": [197, 50], "2026-10-31": [304, 99] }
  const raw = JSON.stringify({ count: 551, uniques: 152, clones: Object.entries(days).map(([d, [c, u]]) => ({ timestamp: d + "T00:00:00Z", count: c, uniques: u })) })
  const s = M.recordTraffic(null, M.parseTraffic(raw, "clones"), Date.UTC(2026, 10, 2, 1))
  assert.equal(M.trafficFor(s, "all", "2026-11-02").count, 551)
  assert.equal(M.uniquesFor(s, "all", "2026-11-02"), 152)
  assert.equal(M.uniquesFor(s, "14d", "2026-11-02"), 152)
  // The file written before this fix migrates to the same answer.
  const migrated = M.cleanSeries({ days, last14: { count: 551, uniques: 152 }, last14Day: "2026-11-02" })
  assert.equal(M.uniquesFor(migrated, "all", "2026-11-02"), 152)
})
