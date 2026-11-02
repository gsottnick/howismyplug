.pragma library

// Pure logic for HowIsMyPlug?: input validation, response sanitizing, the
// day-by-day history, period sums, milestones and the poll schedule. No QML
// imports, so this file loads straight into Node for tests. Everything that
// comes from the network or the state file goes through a sanitizer here.

var DAY_MS = 86400000
var GITHUB_WINDOW_DAYS = 14

// Bi-weekly is 13 days: GitHub's 14-day window includes today, so a full
// 14-day gap would lose the end of one day.
var POLL_MS = { hourly: 3600000, daily: DAY_MS, weekly: 7 * DAY_MS, biweekly: 13 * DAY_MS }

var METRICS = ["clones", "uniqueClones", "views", "uniqueViews", "listingViews", "copies", "hearts"]
var METRIC_LABELS = {
  clones: "clones", uniqueClones: "unique clones", views: "repo views", uniqueViews: "unique repo views",
  listingViews: "listing views", copies: "install copies", hearts: "hearts"
}
var PERIODS = ["7d", "14d", "30d", "all"]

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

function parseJson(raw) {
  try { return JSON.parse(text(raw)) } catch (e) { return null }
}

function isObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v)
}

function safeCount(value) {
  var n = Math.trunc(Number(value))
  return isFinite(n) && n >= 0 && n <= 9007199254740991 ? n : 0
}

// ── input ─────────────────────────────────────────────────────────────

// "owner/repo", a GitHub URL, or "github.com/owner/repo" -> "owner/repo", or "".
function normalizeRepo(input) {
  var s = text(input).trim().replace(/^https:\/\/(www\.)?github\.com\//i, "").replace(/^github\.com\//i, "")
  s = s.replace(/\/+$/, "").replace(/\.git$/i, "")
  var m = /^([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\/([A-Za-z0-9._-]{1,100})$/.exec(s)
  if (!m || m[2] === "." || m[2] === "..") return ""
  return m[1] + "/" + m[2]
}

function repoPath(repo) {
  var parts = normalizeRepo(repo).split("/")
  return parts.length === 2 ? encodeURIComponent(parts[0]) + "/" + encodeURIComponent(parts[1]) : ""
}

// Same rule as the marketplace's engagement API.
function validPluginId(id) {
  var s = text(id)
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(s)
      && ["__proto__", "constructor", "prototype"].indexOf(s.toLowerCase()) < 0
}

// ── responses ─────────────────────────────────────────────────────────

function isoDay(timestamp) {
  var m = /^(\d{4})-(\d{2})-(\d{2})T/.exec(text(timestamp))
  if (!m) return ""
  var d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]))
  return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3]
    ? m[1] + "-" + m[2] + "-" + m[3] : ""
}

// GET /repos/{r}/traffic/clones or /views -> { days: {day: [count, uniques]}, count, uniques } or null.
function parseTraffic(raw, kind) {
  var p = typeof raw === "string" ? parseJson(raw) : raw
  if (!isObject(p) || !Array.isArray(p[kind])) return null
  var days = {}
  for (var i = 0; i < p[kind].length; i++) {
    var e = p[kind][i]
    var day = isObject(e) ? isoDay(e.timestamp) : ""
    if (day) days[day] = [safeCount(e.count), safeCount(e.uniques)]
  }
  return { days: days, count: safeCount(p.count), uniques: safeCount(p.uniques) }
}

// GET api.omarchyplugins.com/v1/stats -> { id: {views, copies, hearts} } for the ids asked about.
function parseMarket(raw, ids) {
  var p = typeof raw === "string" ? parseJson(raw) : raw
  if (!isObject(p) || !isObject(p.plugins)) return null
  var out = {}
  for (var i = 0; i < ids.length; i++) {
    var id = ids[i]
    if (!validPluginId(id) || !Object.prototype.hasOwnProperty.call(p.plugins, id)) continue
    var v = p.plugins[id]
    if (isObject(v)) out[id] = { views: safeCount(v.views), copies: safeCount(v.copies), hearts: safeCount(v.hearts) }
  }
  return out
}

// Base64 (as GitHub's contents API sends it) -> UTF-8 text, or "" if malformed.
function decodeBase64(b64) {
  var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var s = text(b64).replace(/\s/g, "")
  if (!/^[A-Za-z0-9+\/]*={0,2}$/.test(s) || s.length % 4 !== 0) return ""
  s = s.replace(/=+$/, "")
  var bytes = [], buf = 0, bits = 0
  for (var i = 0; i < s.length; i++) {
    buf = (buf << 6) | chars.indexOf(s.charAt(i))
    bits += 6
    if (bits >= 8) { bits -= 8; bytes.push((buf >> bits) & 0xff) }
  }
  var pct = ""
  for (var j = 0; j < bytes.length; j++) pct += "%" + (bytes[j] < 16 ? "0" : "") + bytes[j].toString(16)
  try { return decodeURIComponent(pct) } catch (e) { return "" }
}

// The decoded text of a repo's manifest.json -> its plugin id, or "".
function pluginIdFromManifest(manifestText) {
  var m = parseJson(manifestText)
  return isObject(m) && validPluginId(m.id) ? String(m.id) : ""
}

// POST github.com/login/device/code -> what to show the user, or null.
function parseDeviceCode(raw) {
  var p = parseJson(raw)
  if (!isObject(p)) return null
  var code = text(p.user_code), device = text(p.device_code), uri = text(p.verification_uri)
  if (!/^[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(code) || !/^[A-Za-z0-9]{1,128}$/.test(device)) return null
  if (uri.indexOf("https://github.com/") !== 0) return null
  return {
    userCode: code, deviceCode: device, uri: uri,
    intervalMs: Math.max(5, Math.min(60, safeCount(p.interval) || 5)) * 1000,
    expiresMs: Math.max(60, Math.min(1800, safeCount(p.expires_in) || 900)) * 1000
  }
}

// POST github.com/login/oauth/access_token -> { token } | { wait } | { slowDown } | { error }.
function parseTokenPoll(raw) {
  var p = parseJson(raw)
  if (!isObject(p)) return { error: "GitHub sent an unexpected answer" }
  if (p.access_token !== undefined) {
    var t = text(p.access_token)
    return /^[A-Za-z0-9_]{20,255}$/.test(t) ? { token: t } : { error: "GitHub sent an unexpected answer" }
  }
  if (p.error === "authorization_pending") return { wait: true }
  // GitHub sends the interval it now requires (5 s more each time).
  if (p.error === "slow_down") return { slowDown: true, intervalMs: Math.max(5, Math.min(120, safeCount(p.interval) || 10)) * 1000 }
  if (p.error === "expired_token") return { error: "The code expired. Sign in again." }
  if (p.error === "access_denied") return { error: "Sign-in was cancelled on GitHub." }
  return { error: "GitHub sign-in failed" }
}

// ── history ───────────────────────────────────────────────────────────

function dayKey(ms) {
  return new Date(ms).toISOString().slice(0, 10)
}

function addDays(day, n) {
  return dayKey(Date.parse(day + "T00:00:00Z") + n * DAY_MS)
}

// Today's count grows during the day, and GitHub sometimes revises recent
// days, so the larger value per field wins.
function mergeDays(old, fresh) {
  var out = {}, k
  for (k in old) out[k] = [old[k][0], old[k][1]]
  for (k in fresh) {
    var o = out[k] || [0, 0]
    out[k] = [Math.max(o[0], fresh[k][0]), Math.max(o[1], fresh[k][1])]
  }
  return out
}

// First day of a period ending today, or "" for all time.
function periodStart(period, today) {
  var n = { "7d": 7, "14d": 14, "30d": 30 }[period]
  return n ? addDays(today, 1 - n) : ""
}

function sumDays(days, start) {
  var count = 0, uniques = 0
  for (var k in days) {
    if (start && k < start) continue
    count += days[k][0]
    uniques += days[k][1]
  }
  return { count: count, uniques: uniques }
}

// Clones or views for a period. Counts add up day by day (each day stored
// once). Unique people don't add up across days, so they come from GitHub's
// exact 14-day counts (see uniquesFor).
function trafficFor(series, period, today) {
  if (!series) return { count: 0, uniques: 0, exactUniques: false }
  // "14 days" is GitHub's own window (it can end a day or two before today),
  // so both numbers match its traffic page exactly.
  if (period === "14d" && series.last14) return { count: series.last14.count, uniques: series.last14.uniques, exactUniques: true }
  var s = sumDays(series.days || {}, periodStart(period, today))
  return { count: s.count, uniques: uniquesFor(series, period, today), exactUniques: period === "14d" }
}

// ── unique people over time ───────────────────────────────────────────
// GitHub shows unique cloners (or visitors) per day, and for its latest 14
// days as a whole. Lifetime unique = GitHub's 14-day number from the first
// check, plus each later day's unique number. GitHub's window rolls (a day
// in, a day out), and every day is stored before it drops out, so nothing is
// lost unless no check happens for more than 14 days.

function dayIndex(day) { return Math.round(Date.parse(day + "T00:00:00Z") / DAY_MS) }
function dayFromIndex(i) { return dayKey(i * DAY_MS) }

function uniquesFor(series, period, today) {
  if (!series || !series.last14) return 0
  if (period === "14d") return series.last14.uniques       // exactly GitHub's "in last 14 days"
  var first = series.first
  var start = periodStart(period, today)
  var firstStart = first ? dayFromIndex(dayIndex(first.end) - 13) : ""
  var total = 0, inFirst = 0
  for (var d in series.days) {
    if (start && d < start) continue
    if (first && d <= first.end) inFirst += series.days[d][1]
    else total += series.days[d][1]
  }
  // The first 14 days count as GitHub's own number for them; a period that
  // only covers part of them can't count more than that.
  if (first) total += !start || start <= firstStart ? first.uniques : Math.min(inFirst, first.uniques)
  return total
}

// Store one GitHub traffic answer (parseTraffic's result) in a series.
function recordTraffic(series, t, now) {
  var old = series || { days: {} }
  var keys = Object.keys(t.days).sort()
  var out = { days: mergeDays(old.days || {}, t.days), last14: old.last14 || null, first: old.first || null }
  if (keys.length === 0) return out
  var end = keys[keys.length - 1]
  out.last14 = { count: t.count, uniques: t.uniques, end: end }
  // The window seen at the first check is where lifetime counting starts.
  // A later reading of that same window (its last day still growing) is more
  // complete. If GitHub steps back to an earlier window (its first answer for
  // a new repo can run ahead with nothing counted yet), that settled window is
  // the real start; the days after it are added one by one like any others.
  if (!out.first || end < out.first.end || (end === out.first.end && t.uniques > out.first.uniques))
    out.first = { uniques: t.uniques, end: end }
  return out
}

// Marketplace counts are lifetime. A period shows the growth since the last
// snapshot taken before the period started.
// shortcut: one snapshot a day, so a period edge is off by up to a day of activity; fine for a counter.
function marketFor(market, period, today) {
  var zero = { views: 0, copies: 0, hearts: 0 }
  if (!market || !market.current) return zero
  var cur = market.current
  var start = periodStart(period, today)
  if (!start) return cur
  var snaps = market.snaps || {}, base = null, earliest = null
  for (var k in snaps) {
    if (k < start && (!base || k > base)) base = k
    if (!earliest || k < earliest) earliest = k
  }
  var b = snaps[base || earliest] || zero
  return {
    views: Math.max(0, cur.views - b.views),
    copies: Math.max(0, cur.copies - b.copies),
    hearts: Math.max(0, cur.hearts - b.hearts)
  }
}

// Records the day's first marketplace reading and the latest one.
function recordMarket(market, stats, today) {
  var snaps = {}
  var old = market && market.snaps ? market.snaps : {}
  for (var k in old) snaps[k] = old[k]
  if (!snaps[today]) snaps[today] = stats
  return { current: stats, snaps: snaps }
}

// One number, for the bar and milestones.
function metricValue(totals, metric) {
  switch (metric) {
  case "uniqueClones": return totals.clones.uniques
  case "views": return totals.views.count
  case "uniqueViews": return totals.views.uniques
  case "listingViews": return totals.market.views
  case "copies": return totals.market.copies
  case "hearts": return totals.market.hearts
  default: return totals.clones.count
  }
}

// Every tracked repo added up for one period.
function totalsFor(repos, period, today) {
  var t = { clones: { count: 0, uniques: 0 }, views: { count: 0, uniques: 0 }, market: { views: 0, copies: 0, hearts: 0 } }
  var listings = {}
  for (var i = 0; i < repos.length; i++) {
    var r = repos[i]
    var c = trafficFor(r.clones, period, today), v = trafficFor(r.views, period, today)
    t.clones.count += c.count; t.clones.uniques += c.uniques
    t.views.count += v.count; t.views.uniques += v.uniques
    // A fork tracked next to its original shares one listing: count it once,
    // from the first repo that has its numbers.
    if (!r.market || (r.pluginId && listings[r.pluginId])) continue
    if (r.pluginId) listings[r.pluginId] = true
    var m = marketFor(r.market, period, today)
    t.market.views += m.views; t.market.copies += m.copies; t.market.hearts += m.hearts
  }
  return t
}

// ── milestones ────────────────────────────────────────────────────────

// -> { seen, celebrate } where celebrate is the milestone number to show, or 0.
// seen < 0 means first run: record silently.
function checkMilestone(value, step, seen) {
  var s = Math.max(1, safeCount(step))
  var n = Math.floor(safeCount(value) / s)
  if (seen < 0) return { seen: n, celebrate: 0 }
  if (n > seen) return { seen: n, celebrate: n * s }
  return { seen: seen, celebrate: 0 }
}

// ── schedule ──────────────────────────────────────────────────────────

function pollEveryMs(every) {
  return POLL_MS[every] || POLL_MS.daily
}

// ms until the next poll is due (0 = now).
function pollDelay(lastPoll, every, now) {
  if (!(lastPoll > 0) || lastPoll > now) return 0
  return Math.max(0, lastPoll + pollEveryMs(every) - now)
}

// Days that fell out of GitHub's window before they could be read, or "".
function missedRange(lastPoll, now) {
  if (!(lastPoll > 0)) return ""
  var firstVisible = addDays(dayKey(now), 1 - GITHUB_WINDOW_DAYS)
  var lastSeen = dayKey(lastPoll)
  if (addDays(lastSeen, 1) >= firstVisible) return ""
  var from = addDays(lastSeen, 1), to = addDays(firstVisible, -1)
  return from === to ? from : from + " – " + to
}


// ── state file ────────────────────────────────────────────────────────

function cleanSeries(s) {
  if (!isObject(s)) return null
  var days = {}, k
  if (isObject(s.days)) {
    for (k in s.days) {
      var v = s.days[k]
      if (isoDay(k + "T") && Array.isArray(v)) days[k] = [safeCount(v[0]), safeCount(v[1])]
    }
  }
  var keys = Object.keys(days).sort()
  var out = { days: days, last14: null, first: null }
  if (isObject(s.last14)) {
    // Older files kept the check's date instead of the window's last day.
    var end = isoDay(text(s.last14.end) + "T") ? s.last14.end : (keys.length ? keys[keys.length - 1] : "")
    if (end) out.last14 = { count: safeCount(s.last14.count), uniques: safeCount(s.last14.uniques), end: end }
  }
  if (isObject(s.first) && isoDay(text(s.first.end) + "T")) out.first = { uniques: safeCount(s.first.uniques), end: s.first.end }
  // Files from before: lifetime counting starts from the latest 14-day number they kept.
  else if (out.last14) out.first = { uniques: out.last14.uniques, end: out.last14.end }
  return out
}

function cleanCounts(c) {
  return isObject(c) ? { views: safeCount(c.views), copies: safeCount(c.copies), hearts: safeCount(c.hearts) } : null
}

function cleanMarket(m) {
  if (!isObject(m) || !cleanCounts(m.current)) return null
  var snaps = {}
  if (isObject(m.snaps)) for (var k in m.snaps) if (isoDay(k + "T") && cleanCounts(m.snaps[k])) snaps[k] = cleanCounts(m.snaps[k])
  return { current: cleanCounts(m.current), snaps: snaps }
}

var ACCESS = ["", "ok", "denied", "missing"]
var CHECKS = ["hourly", "daily", "weekly", "biweekly"]

function cleanCheck(v, fallback) {
  return CHECKS.indexOf(v) >= 0 ? v : (CHECKS.indexOf(fallback) >= 0 ? fallback : "daily")
}

function cleanMilestone(m) {
  m = isObject(m) ? m : {}
  return {
    on: m.on !== false,
    metric: METRICS.indexOf(m.metric) >= 0 ? m.metric : "clones",
    step: Math.max(1, Math.min(1000000, safeCount(m.step) || 100))
  }
}

function cleanSeen(s) {
  var out = {}
  if (isObject(s)) for (var m in s) if (METRICS.indexOf(m) >= 0) out[m] = safeCount(s[m])
  return out
}

// defaults: { checkGithub, checkListing } for a newly added repo.
function newRepo(repo, now, defaults) {
  var d = defaults || {}
  return {
    repo: repo, addedAt: now, pluginId: "", idChecked: false, access: "", clones: null, views: null, market: null,
    checkGithub: cleanCheck(d.checkGithub), checkListing: cleanCheck(d.checkListing),
    lastGithub: 0, lastListing: 0, missed: "", milestone: cleanMilestone(null), seen: {}
  }
}

function cleanState(raw) {
  var p = typeof raw === "string" ? parseJson(raw) : raw
  var out = { schema: 1, lastPoll: 0, lastMarket: 0, authMethod: "app", repos: [], seen: {} }
  if (!isObject(p)) return out
  out.lastPoll = safeCount(p.lastPoll)
  out.lastMarket = safeCount(p.lastMarket)
  if (p.authMethod === "token") out.authMethod = "token"
  out.seen = cleanSeen(p.seen)
  var list = Array.isArray(p.repos) ? p.repos : [], have = {}
  for (var i = 0; i < list.length && out.repos.length < 100; i++) {
    var r = list[i]
    var name = isObject(r) ? normalizeRepo(r.repo) : ""
    if (!name || have[name.toLowerCase()]) continue
    have[name.toLowerCase()] = true
    out.repos.push({
      repo: name, addedAt: safeCount(r.addedAt),
      pluginId: validPluginId(r.pluginId) ? String(r.pluginId) : "",
      idChecked: r.idChecked === true,
      access: ACCESS.indexOf(r.access) >= 0 ? r.access : "",
      clones: cleanSeries(r.clones), views: cleanSeries(r.views), market: cleanMarket(r.market),
      checkGithub: cleanCheck(r.checkGithub), checkListing: cleanCheck(r.checkListing),
      lastGithub: safeCount(r.lastGithub), lastListing: safeCount(r.lastListing),
      missed: /^\d{4}-\d{2}-\d{2}( – \d{4}-\d{2}-\d{2})?$/.test(text(r.missed)) ? r.missed : "",
      milestone: cleanMilestone(r.milestone), seen: cleanSeen(r.seen)
    })
  }
  return out
}

// ── per-repo schedule ─────────────────────────────────────────────────

// Repos whose GitHub traffic (kind "github") or listing ("listing") is due.
function githubDelay(r, now) {
  return pollDelay(r.lastGithub, r.checkGithub, now)
}

function dueRepos(repos, kind, now) {
  return repos.filter(function(r) {
    return (kind === "github" ? githubDelay(r, now) : pollDelay(r.lastListing, r.checkListing, now)) === 0
  }).map(function(r) { return r.repo })
}

// ms until the next repo is due. GitHub checks only count when signed in;
// listing checks only for repos that have a plugin id.
function nextDelay(repos, now, signedIn) {
  var best = -1
  for (var i = 0; i < repos.length; i++) {
    var r = repos[i]
    var delays = []
    if (signedIn) delays.push(githubDelay(r, now))
    if (r.pluginId) delays.push(pollDelay(r.lastListing, r.checkListing, now))
    for (var j = 0; j < delays.length; j++) if (best < 0 || delays[j] < best) best = delays[j]
  }
  return best
}

// ── bar number and milestones ─────────────────────────────────────────

function findRepo(repos, name) {
  for (var i = 0; i < repos.length; i++) if (repos[i].repo === name) return repos[i]
  return null
}

// source: "all" or a tracked repo's name (falls back to all repos).
function barValue(repos, source, stat, today) {
  var one = source && source !== "all" ? findRepo(repos, source) : null
  return metricValue(totalsFor(one ? [one] : repos, "all", today), stat)
}

// Milestones due now: each repo's own (if on) and the combined one (if on).
// -> { seen: {repo name or "": {metric: n}}, celebrations: [{repo, metric, value}] }
// A repo or combined total seen for the first time is recorded silently.
function milestoneCheck(repos, combined, combinedSeen, today) {
  var seen = {}, celebrations = []
  function check(key, list, cfg, seenMap) {
    var value = metricValue(totalsFor(list, "all", today), cfg.metric)
    var before = seenMap[cfg.metric] === undefined ? -1 : seenMap[cfg.metric]
    var r = checkMilestone(value, cfg.step, before)
    if (r.seen !== before) { seen[key] = {}; seen[key][cfg.metric] = r.seen }
    if (r.celebrate > 0) celebrations.push({ repo: key, metric: cfg.metric, value: r.celebrate })
  }
  for (var i = 0; i < repos.length; i++)
    if (repos[i].milestone && repos[i].milestone.on) check(repos[i].repo, [repos[i]], repos[i].milestone, repos[i].seen || {})
  if (combined && combined.on && repos.length > 0) check("", repos, cleanMilestone(combined), combinedSeen || {})
  return { seen: seen, celebrations: celebrations }
}

// ── formatting ────────────────────────────────────────────────────────

function compact(n) {
  n = safeCount(n)
  if (n >= 1e9) return (n / 1e9).toFixed(n >= 1e10 ? 0 : 1).replace(/\.0$/, "") + "B"
  if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1).replace(/\.0$/, "") + "M"
  if (n >= 1e4) return (n / 1e3).toFixed(n >= 1e5 ? 0 : 1).replace(/\.0$/, "") + "K"
  return String(n)
}

function grouped(n) {
  return String(safeCount(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

// "551", "152 unique", or "551 · 152 unique" for the count-mode setting.
function countText(count, uniques, mode) {
  if (mode === "unique") return grouped(uniques)
  if (mode === "both") return grouped(count) + " · " + grouped(uniques)
  return grouped(count)
}

// "1,406 clones", "383 unique clones", or "1,406 clones (383 unique)".
function countWords(count, uniques, mode, noun) {
  if (mode === "unique") return grouped(uniques) + " unique " + noun
  if (mode === "both") return grouped(count) + " " + noun + " (" + grouped(uniques) + " unique)"
  return grouped(count) + " " + noun
}

function periodLabel(period) {
  return { "7d": "7 days", "14d": "14 days", "30d": "30 days" }[period] || "All time"
}
