pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// HowIsMyPlug? data: GitHub sign-in, the tracked repos and their history,
// polling, and the state file. One instance for every monitor's bar; the
// view lives in Panel.qml / PlugView.qml.
//
// Security rules (see SECURITY.md):
// - The GitHub token lives only in the system keyring and in `_token` here.
//   It reaches secret-tool on stdin, and GitHub in an Authorization header
//   sent straight from this process (XMLHttpRequest). It is never on a
//   command line, in a file, in a log line or in an error message.
// - Requests go only to the hosts below, over HTTPS.
// - Every response is sanitized by Model.js before it is used or shown.
Singleton {
  id: root

  readonly property string clientId: "Iv23liNYpgF5dSPSM5qD"
  readonly property string appSlug: "howismyplug"
  readonly property string keyService: "io.github.gsottnick.howismyplug"

  // Tests point every host at a local fake; nothing else is accepted.
  readonly property string testBase: {
    var b = String(Quickshell.env("HOWISMYPLUG_TEST_BASE") || "")
    return /^http:\/\/127\.0\.0\.1:\d{2,5}$/.test(b) ? b : ""
  }
  readonly property string apiHost: testBase ? testBase + "/api" : "https://api.github.com"
  readonly property string loginHost: testBase ? testBase + "/login" : "https://github.com"
  readonly property string marketHost: testBase ? testBase + "/market" : "https://api.omarchyplugins.com"

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/howismyplug"

  // ── public surface ──────────────────────────────────────────────────
  property var state: Model.cleanState(null)
  property bool stateLoaded: false
  readonly property var repos: state.repos

  property string _token: ""
  property bool keyringChecked: false
  readonly property bool signedIn: _token !== ""
  readonly property string authMethod: signedIn ? state.authMethod : ""   // "app" or "token", for the label only

  property bool signingIn: false
  property string userCode: ""
  property string verifyUri: ""
  property string authError: ""

  property bool polling: false
  property int _pending: 0
  property string pollError: ""
  property double now: Date.now()

  // Defaults for repos added from now on (each repo keeps its own afterwards).
  property string defaultCheckGithub: "daily"
  property string defaultCheckListing: "daily"

  readonly property string installUrl: "https://github.com/apps/" + appSlug + "/installations/new"
  readonly property string tokenHelpUrl: "https://github.com/settings/personal-access-tokens/new"

  function applySettings(checkGithub, checkListing) {
    root.defaultCheckGithub = Model.cleanCheck(checkGithub)
    root.defaultCheckListing = Model.cleanCheck(checkListing)
  }

  // ── repos ───────────────────────────────────────────────────────────
  // -> "" on success, or why not.
  function addRepo(input) {
    var name = Model.normalizeRepo(input)
    if (!name) return "Use owner/repo or a GitHub link, like yourname/my-omarchy-plugin"
    for (var i = 0; i < state.repos.length; i++)
      if (state.repos[i].repo.toLowerCase() === name.toLowerCase()) return "Already tracked"
    if (state.repos.length >= 100) return "That's the limit of 100 repos"
    var s = copyState()
    s.repos.push(Model.newRepo(name, Date.now(), { checkGithub: root.defaultCheckGithub, checkListing: root.defaultCheckListing }))
    commit(s)
    pollRepo(name)
    schedule()
    return ""
  }

  function removeRepo(name) {
    var s = copyState()
    s.repos = s.repos.filter(function(r) { return r.repo !== name })
    commit(s)
    schedule()
  }

  // A repo's own check intervals and milestone settings.
  function setRepoOption(name, key, value) {
    var s = copyState()
    var r = Model.findRepo(s.repos, name)
    if (!r) return
    if (key === "checkGithub" || key === "checkListing") r[key] = Model.cleanCheck(value, r[key])
    else if (key === "milestone") r.milestone = Model.cleanMilestone(value)
    else return
    commit(s)
    // A new schedule starts with a check right now, so no day can slip
    // between the old schedule and the new one.
    if (key === "checkGithub") pollRepo(name)
    else if (key === "checkListing") pollMarket([name])
    schedule()
  }

  // Milestones due now (see Model.milestoneCheck); records the counts last
  // seen and returns the ones to celebrate.
  function takeMilestones(combined) {
    var r = Model.milestoneCheck(state.repos, combined, state.seenValue, Model.dayKey(Date.now()))
    var keys = Object.keys(r.seen)
    if (keys.length > 0) {
      var s = copyState()
      keys.forEach(function(k) {
        var target = k === "" ? s.seenValue : (Model.findRepo(s.repos, k) || {}).seenValue
        if (target) for (var m in r.seen[k]) target[m] = r.seen[k][m]
      })
      commit(s)
    }
    return r.celebrations
  }

  function copyState() { return JSON.parse(JSON.stringify(state)) }

  function commit(s) {
    root.state = s
    saveState()
  }

  function updateRepo(name, change) {
    var s = copyState()
    for (var i = 0; i < s.repos.length; i++) if (s.repos[i].repo === name) change(s.repos[i])
    root.state = s
  }

  // ── HTTP ────────────────────────────────────────────────────────────
  // Every request answers exactly once: with the server's reply, or with
  // status 0 after 20 s, when the reply grows past its size cap, when the
  // queue is full, or when it can't be sent. A reply that never comes (a
  // stalled reused connection) must not stop a sign-in or a check without a word.
  // At most maxInflight run at once; the rest wait their turn in _queue.
  readonly property int maxInflight: 6
  readonly property int maxQueued: 512          // 100 repos x 3 requests, with room
  readonly property int maxReplyChars: 1048576  // GitHub replies here are a few KB
  readonly property int maxMarketChars: 8388608 // all marketplace stats, ~400 KB in 2026
  property var _inflight: []
  property var _queue: []
  function request(method, url, headers, body, done, maxChars) {
    var entry = { method: method, url: url, headers: headers, body: body || null, done: done,
                  max: maxChars || root.maxReplyChars, x: null, started: 0, answered: false }
    if (root._queue.length >= root.maxQueued) { done(0, ""); return }
    root._queue = root._queue.concat([entry])
    pumpRequests()
  }

  function pumpRequests() {
    while (root._inflight.length < root.maxInflight && root._queue.length > 0) {
      var entry = root._queue[0]
      root._queue = root._queue.slice(1)
      sendRequest(entry)
    }
  }

  function sendRequest(entry) {
    var x = new XMLHttpRequest()
    entry.x = x
    entry.started = Date.now()
    root._inflight = root._inflight.concat([entry])
    // LOADING fires for each chunk that arrives, so an oversized reply is
    // dropped as soon as it passes the cap instead of after it is all buffered.
    // shortcut: the cap is checked per network chunk, so one chunk can overshoot it; QML's XHR has no read limit.
    x.onreadystatechange = function() {
      if (entry.answered) return
      if (x.readyState === XMLHttpRequest.HEADERS_RECEIVED && Number(x.getResponseHeader("Content-Length")) > entry.max) return answerRequest(entry, 0, "")
      if (x.readyState === XMLHttpRequest.LOADING && x.responseText.length > entry.max) return answerRequest(entry, 0, "")
      if (x.readyState !== XMLHttpRequest.DONE) return
      var reply = x.responseText
      if (reply.length > entry.max) answerRequest(entry, 0, "")
      else answerRequest(entry, x.status, reply)
    }
    try {
      x.open(entry.method, entry.url)
      for (var k in entry.headers) x.setRequestHeader(k, entry.headers[k])
      x.send(entry.body)
    } catch (err) {
      answerRequest(entry, 0, "")
    }
  }

  function answerRequest(entry, status, body) {
    if (entry.answered) return
    entry.answered = true
    root._inflight = root._inflight.filter(function(e) { return e !== entry })
    // Abort on the next turn: aborting inside XHR's own LOADING callback frees
    // the reply while Qt is still reading it (a crash). `answered` ignores the rest.
    var x = entry.x
    if (status === 0 && x) Qt.callLater(function() { try { x.abort() } catch (err) {} })
    entry.done(status, body)
    pumpRequests()
  }

  Timer {
    interval: 2000
    running: root._inflight.length > 0
    repeat: true
    onTriggered: {
      var now = Date.now()
      root._inflight.filter(function(e) { return now - e.started >= root.requestTimeoutMs })
                    .forEach(function(e) { root.answerRequest(e, 0, "") })
    }
  }
  property int requestTimeoutMs: Number(Quickshell.env("HOWISMYPLUG_TEST_TIMEOUT_MS")) > 0 && root.testBase ? Number(Quickshell.env("HOWISMYPLUG_TEST_TIMEOUT_MS")) : 20000

  function github(path, done) {
    var h = { "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "HowIsMyPlug" }
    if (root._token) h["Authorization"] = "Bearer " + root._token
    request("GET", root.apiHost + path, h, null, done)
  }

  // ── polling ─────────────────────────────────────────────────────────
  // Each repo has its own GitHub and listing intervals; one timer wakes for
  // whichever is due next. The refresh button checks everything now.
  function pollNow() {
    if (!stateLoaded) return
    root.now = Date.now()
    root.pollError = ""
    var names = state.repos.map(function(r) { return r.repo })
    names.forEach(pollRepo)
    pollMarket(names)
    var s = copyState(); s.lastPoll = root.now; commit(s)
    schedule()
  }

  function tick() {
    if (!stateLoaded) return
    root.now = Date.now()
    // A plugin id that couldn't be looked up yet (network trouble): try again.
    state.repos.forEach(function(r) { if (!r.idChecked) root.lookUpPluginId(r.repo, "/repos/" + Model.repoPath(r.repo)) })
    var github = root.signedIn ? Model.dueRepos(state.repos, "github", root.now) : []
    var listing = Model.dueRepos(state.repos.filter(function(r) { return r.pluginId !== "" }), "listing", root.now)
    github.forEach(pollRepo)
    if (listing.length > 0) pollMarket(listing)
    if (github.length + listing.length > 0) { var s = copyState(); s.lastPoll = root.now; commit(s) }
    schedule()
  }

  function pollRepo(name) {
    var path = "/repos/" + Model.repoPath(name)
    if (!path || path === "/repos/") return
    var repo = Model.findRepo(state.repos, name)
    if (!repo) return
    if (!repo.idChecked) lookUpPluginId(name, path)
    if (!root.signedIn) return
    var started = Date.now()
    // Days that fell out of GitHub's 14-day window since this repo's last check.
    updateRepo(name, function(r) { r.missed = Model.missedRange(r.lastGithub, started); r.lastGithub = started })
    var kinds = ["clones", "views"]
    kinds.forEach(function(kind) {
      begin()
      github(path + "/traffic/" + kind, function(status, body) {
        if (status === 200) {
          var t = Model.parseTraffic(body, kind)
          if (t) updateRepo(name, function(r) {
            r[kind] = Model.recordTraffic(r[kind], t, Date.now())
            r.access = "ok"
          })
        } else if (status === 401) {
          root.pollError = "GitHub no longer accepts the sign-in. Sign in again."
        } else if (status === 403 || status === 404) {
          updateRepo(name, function(r) { r.access = status === 404 ? "missing" : "denied" })
        } else {
          root.pollError = "GitHub didn't answer (" + status + "). Trying again next time."
        }
        finish()
      })
    })
  }

  // A repo's manifest.json names its plugin id, which the marketplace stats use.
  function lookUpPluginId(name, path) {
    begin()
    github(path + "/contents/manifest.json", function(status, body) {
      var id = ""
      if (status === 200) {
        var p = Model.parseJson(body)
        var content = p && typeof p.content === "string" && p.encoding === "base64" ? p.content.replace(/\s/g, "") : ""
        if (content.length > 0 && content.length < 200000) {
          id = Model.pluginIdFromManifest(Model.decodeBase64(content))
        }
      }
      // Only a definite answer is remembered; a network error asks again next poll.
      if (status === 200 || status === 404) updateRepo(name, function(r) { r.pluginId = id; r.idChecked = true })
      if (id) { pollMarket([name]); schedule() }
      finish()
    })
  }

  // Fresh listing numbers for these repos (one request covers them all).
  function pollMarket(names) {
    var wanted = state.repos.filter(function(r) { return r.pluginId !== "" && names.indexOf(r.repo) >= 0 })
    if (wanted.length === 0) return
    var ids = wanted.map(function(r) { return r.pluginId })
    var started = Date.now()
    var s0 = copyState()
    s0.repos.forEach(function(r) { if (names.indexOf(r.repo) >= 0 && r.pluginId) r.lastListing = started })
    root.state = s0
    begin()
    request("GET", root.marketHost + "/v1/stats", { "Accept": "application/json" }, null, function(status, body) {
      var stats = status === 200 ? Model.parseMarket(body, ids) : null
      if (stats) {
        var today = Model.dayKey(Date.now())
        var s = copyState()
        s.lastMarket = Date.now()
        s.repos.forEach(function(r) {
          if (names.indexOf(r.repo) >= 0 && stats[r.pluginId]) r.market = Model.recordMarket(r.market, stats[r.pluginId], today)
        })
        root.state = s
      }
      finish()
    }, root.maxMarketChars)
  }

  property double _pollStarted: 0
  function begin() {
    if (root._pending === 0) root._pollStarted = Date.now()
    root._pending++
    root.polling = true
  }
  function finish() {
    root._pending = Math.max(0, root._pending - 1)
    if (root._pending === 0) {
      root.polling = false
      root.now = Date.now()
      // Adding a repo or signing in checks through here, not pollNow/tick,
      // so the footer would otherwise stay "Checked never" after real numbers.
      var s = copyState(); s.lastPoll = root.now; commit(s)
    }
  }

  function schedule() {
    if (!stateLoaded) return
    var d = Model.nextDelay(state.repos, Date.now(), root.signedIn)
    // Unknown plugin ids are retried hourly.
    if (state.repos.some(function(r) { return !r.idChecked })) d = d < 0 ? 3600000 : Math.min(d, 3600000)
    if (d < 0) { pollTimer.stop(); return }
    pollTimer.interval = Math.max(1000, d)
    pollTimer.restart()
  }

  Timer {
    id: pollTimer
    repeat: false
    onTriggered: root.tick()
  }

  function panelOpened() {
    root.now = Date.now()
  }

  // ── GitHub sign-in (device flow) ────────────────────────────────────
  // Poll a second later than GitHub asks: right at its limit, timing jitter
  // reads as too early, each "slow_down" adds 5 s, and the loop never ends.
  readonly property int pollMarginMs: 1000
  property string _deviceCode: ""
  property double _deviceDeadline: 0

  function signIn() {
    root.authError = ""
    root.signingIn = true
    request("POST", root.loginHost + "/login/device/code",
            { "Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded" },
            "client_id=" + encodeURIComponent(root.clientId),
            function(status, body) {
      var d = status === 200 ? Model.parseDeviceCode(body) : null
      if (!d) { root.signingIn = false; root.authError = "Couldn't reach GitHub. Try again."; return }
      root.userCode = d.userCode
      root.verifyUri = d.uri
      root._deviceCode = d.deviceCode
      root._deviceDeadline = Date.now() + d.expiresMs
      devicePoll.interval = d.intervalMs + root.pollMarginMs
      devicePoll.restart()
      copy(d.userCode)
      Qt.openUrlExternally(d.uri)
    })
  }

  function cancelSignIn() {
    devicePoll.stop()
    root.signingIn = false
    root.userCode = ""
    root._deviceCode = ""
  }

  Timer {
    id: devicePoll
    repeat: false
    onTriggered: {
      if (Date.now() > root._deviceDeadline) { root.cancelSignIn(); root.authError = "The code expired. Sign in again."; return }
      root.request("POST", root.loginHost + "/login/oauth/access_token",
                   { "Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded" },
                   "client_id=" + encodeURIComponent(root.clientId) + "&device_code=" + encodeURIComponent(root._deviceCode)
                   + "&grant_type=" + encodeURIComponent("urn:ietf:params:oauth:grant-type:device_code"),
                   function(status, body) {
        if (!root.signingIn) return
        // No answer or a server hiccup: keep asking until the code expires.
        if (status !== 200) { devicePoll.restart(); return }
        var r = Model.parseTokenPoll(body)
        if (r.token) { root.cancelSignIn(); root.useToken(r.token, "app"); return }
        if (r.error) { root.cancelSignIn(); root.authError = r.error; return }
        if (r.slowDown) devicePoll.interval = r.intervalMs + root.pollMarginMs
        devicePoll.restart()
      })
    }
  }

  // A pasted fine-grained token works the same way as the sign-in.
  // -> "" on success, or why not.
  function submitToken(text) {
    var t = String(text || "").trim()
    if (!/^[A-Za-z0-9_]{20,255}$/.test(t)) return "That doesn't look like a GitHub token"
    useToken(t, "token")
    return ""
  }

  function useToken(token, method) {
    root._token = token
    root.authError = ""
    var s = copyState(); s.authMethod = method; commit(s)
    root._keyPending = token
    root._clearQueued = false
    keyringNext()
    for (var i = 0; i < state.repos.length; i++) pollRepo(state.repos[i].repo)
    schedule()
  }

  function signOut() {
    cancelSignIn()
    root._token = ""
    root._keyPending = ""
    root._clearQueued = true
    keyringNext()
    schedule()
  }

  // Keyring writes run one at a time, newest wish last: a token saved or a
  // sign-out while secret-tool is still busy waits for it instead of racing it.
  property bool _clearQueued: false
  property string _keyPending: ""
  function keyringNext() {
    if (keyStore.running || keyClear.running) return
    if (root._clearQueued) {
      root._clearQueued = false
      startHelper(keyClear)
    } else if (root._keyPending !== "") {
      keyStore.stdinEnabled = true
      startHelper(keyStore)
    }
  }

  // Every helper below is finite: `timeout` ends it, and `_began` tells a
  // program that never started (Quickshell then reports no exit at all) from
  // one that ran.
  property var _began: ({})
  function startHelper(proc) {
    root._began[proc.objectName] = false
    proc.running = true
  }
  function began(proc) { root._began[proc.objectName] = true }
  function neverBegan(proc) { return !proc.running && root._began[proc.objectName] === false }

  function copy(value) {
    root._clip = String(value)
    if (!clipboard.running) { clipboard.stdinEnabled = true; clipboard.running = true }
  }

  // Links built only from validated names, opened in the browser.
  function openRepoPage(name) {
    var path = Model.repoPath(name)
    if (path) Qt.openUrlExternally("https://github.com/" + path)
  }
  function openListing(id) {
    if (Model.validPluginId(id)) Qt.openUrlExternally("https://plugins.omarchy.org/plugin.html?id=" + encodeURIComponent(id))
  }

  function openUrl(url) {
    if (url === root.installUrl || url === root.tokenHelpUrl || url === root.verifyUri) Qt.openUrlExternally(url)
  }

  // ── keyring (secret-tool, from libsecret; GNOME Keyring ships with Omarchy) ──
  // A keyring that is locked, missing or stuck leaves the user signed out
  // (they can sign in again), never waiting forever.
  Process {
    id: keyLookup
    objectName: "keyLookup"
    command: ["timeout", "-k", "2", "15", "secret-tool", "lookup", "service", root.keyService, "account", "github"]
    stdout: StdioCollector { id: keyText; waitForEnd: true }
    onStarted: root.began(keyLookup)
    onExited: function(code) {
      var t = code === 0 ? String(keyText.text || "").trim() : ""
      if (/^[A-Za-z0-9_]{20,255}$/.test(t)) root._token = t
      root.keyringLookedUp()
    }
    onRunningChanged: if (root.neverBegan(keyLookup)) root.keyringLookedUp()
  }

  function keyringLookedUp() {
    if (root.keyringChecked) return
    root.keyringChecked = true
    root.tick()
  }

  Process {
    id: keyStore
    objectName: "keyStore"
    command: ["timeout", "-k", "2", "15", "secret-tool", "store", "--label=HowIsMyPlug? GitHub sign-in", "service", root.keyService, "account", "github"]
    onStarted: {
      write(root._keyPending)
      root._keyPending = ""
      stdinEnabled = false
      root.began(keyStore)
    }
    onExited: function(code) {
      if (code !== 0) root.authError = "Couldn't save the sign-in to the keyring. It works until you log out."
      root.keyringNext()
    }
    onRunningChanged: if (root.neverBegan(keyStore)) {
      root._keyPending = ""
      stdinEnabled = false
      root.authError = "Couldn't save the sign-in to the keyring. It works until you log out."
      root.keyringNext()
    }
  }

  Process {
    id: keyClear
    objectName: "keyClear"
    command: ["timeout", "-k", "2", "15", "secret-tool", "clear", "service", root.keyService, "account", "github"]
    onStarted: root.began(keyClear)
    onExited: root.keyringNext()
    onRunningChanged: if (root.neverBegan(keyClear)) root.keyringNext()
  }

  // ── bounded paste ───────────────────────────────────────────────────
  // The text fields paste through here instead of letting Qt read the whole
  // clipboard: at most maxPasteChars of text, within 3 s, or nothing.
  // done(text) with the text, or done(null, why) when there is nothing to paste.
  readonly property int maxPasteChars: 4096
  property var _pasteDone: null
  property string _pasteText: ""
  property bool _pasteTooLong: false
  function readClipboard(done) {
    if (pasteRead.running) { done(null, ""); return }
    root._pasteDone = done
    root._pasteText = ""
    root._pasteTooLong = false
    startHelper(pasteRead)
  }

  function pasteFinished(ok) {
    var done = root._pasteDone, text = root._pasteText
    root._pasteDone = null
    root._pasteText = ""
    if (!done) return
    if (root._pasteTooLong) done(null, "That's too long to paste")
    else done(ok ? text : null, "")
  }

  Process {
    id: pasteRead
    objectName: "pasteRead"
    command: ["timeout", "-k", "1", "2", "wl-paste", "--no-newline", "--type", "text"]
    stdout: SplitParser {
      splitMarker: ""   // every chunk as it arrives, so the cap holds before it is all read
      onRead: function(chunk) {
        if (root._pasteTooLong) return
        root._pasteText += chunk
        if (root._pasteText.length > root.maxPasteChars) {
          root._pasteTooLong = true
          root._pasteText = ""
          pasteRead.running = false
        }
      }
    }
    onStarted: root.began(pasteRead)
    onExited: function(code) { root.pasteFinished(code === 0) }
    onRunningChanged: if (root.neverBegan(pasteRead)) root.pasteFinished(false)
  }

  property string _clip: ""
  Process {
    id: clipboard
    command: ["wl-copy"]
    onStarted: {
      write(root._clip)
      root._clip = ""
      stdinEnabled = false
    }
  }

  // ── state file ──────────────────────────────────────────────────────
  Component.onCompleted: readState()

  // 100 repos with years of daily numbers stay far below this.
  readonly property int maxStateChars: 67108864
  property string _stateRaw: ""
  property bool _stateTooBig: false
  function readState() {
    if (stateLoaded || stateRead.running) return
    root._stateRaw = ""
    root._stateTooBig = false
    startHelper(stateRead)
  }

  // Until the file is read, nothing is saved, so a read that fails never
  // overwrites the history: it is tried again every 30 s.
  function stateReadFailed() {
    root._stateRaw = ""
    root.pollError = root._stateTooBig
      ? "The history file is too large to read: " + root.stateDir + "/history.json. Move it away to start fresh."
      : "Couldn't read the saved history. Trying again…"
    if (!root._stateTooBig) stateRetry.restart()
  }

  Timer { id: stateRetry; interval: 30000; onTriggered: root.readState() }

  Process {
    id: stateRead
    objectName: "stateRead"
    command: ["timeout", "-k", "2", "15", "cat", root.stateDir + "/history.json"]
    environment: ({ LC_ALL: "C" })   // so the "No such file" below is in English
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root._stateTooBig) return
        root._stateRaw += chunk
        if (root._stateRaw.length > root.maxStateChars) {
          root._stateTooBig = true
          root._stateRaw = ""
          stateRead.running = false
        }
      }
    }
    stderr: StdioCollector { id: stateErr; waitForEnd: true }
    onStarted: root.began(stateRead)
    onExited: function(code) {
      if (code === 0 && !root._stateTooBig) root.loadState(root._stateRaw)
      else if (!root._stateTooBig && /No such file/.test(stateErr.text)) root.loadState("")   // a first run
      else root.stateReadFailed()
    }
    onRunningChanged: if (root.neverBegan(stateRead)) root.stateReadFailed()
  }

  function loadState(raw) {
    if (stateLoaded) return
    root._stateRaw = ""
    root.pollError = ""
    root.state = Model.cleanState(raw)
    root.stateLoaded = true
    startHelper(keyLookup)
    schedule()
  }

  // History can outgrow a command-line argument, so it goes in on stdin.
  property string _saveQueued: ""
  function saveState() {
    if (!stateLoaded) return
    root._saveQueued = JSON.stringify(root.state)
    if (!stateWrite.running) { stateWrite.stdinEnabled = true; startHelper(stateWrite) }
  }

  // A save that fails or can't start leaves the old file in place (the write
  // goes to a temporary file first); the next change saves the whole state again.
  Process {
    id: stateWrite
    objectName: "stateWrite"
    command: ["timeout", "-k", "2", "15", "sh", "-c", 'umask 077 && mkdir -p "$1" && cat > "$1/history.json.tmp" && mv -f "$1/history.json.tmp" "$1/history.json"', "sh", root.stateDir]
    onStarted: {
      write(root._saveQueued)
      root._saveQueued = ""
      stdinEnabled = false
      root.began(stateWrite)
    }
    onExited: if (root._saveQueued !== "") { stdinEnabled = true; root.startHelper(stateWrite) }
    onRunningChanged: if (root.neverBegan(stateWrite)) stdinEnabled = false
  }

  // Keeps "updated 3 h ago" honest while the bar sits there, and unsticks a
  // check whose request never came back (XHR has no reliable timeout here).
  Timer {
    interval: 60000; running: true; repeat: true
    onTriggered: {
      root.now = Date.now()
      // After the computer sleeps, the schedule timer can be late: anything
      // already due is checked now.
      if (!root.polling && root.stateLoaded && Model.nextDelay(root.state.repos, root.now, root.signedIn) === 0) root.tick()
      if (root.polling && root.now - root._pollStarted > 120000) {
        root._pending = 0
        root.polling = false
        root.pollError = "GitHub didn't answer. Trying again next time."
        root.saveState()
      }
    }
  }
}
