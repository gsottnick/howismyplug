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
    schedule()
  }

  // Milestones due now (see Model.milestoneCheck); records them as seen and
  // returns the ones to celebrate.
  function takeMilestones(combined) {
    var r = Model.milestoneCheck(state.repos, combined, state.seen, Model.dayKey(Date.now()))
    var keys = Object.keys(r.seen)
    if (keys.length > 0) {
      var s = copyState()
      keys.forEach(function(k) {
        var target = k === "" ? s.seen : (Model.findRepo(s.repos, k) || {}).seen
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
  // Every request answers exactly once: with GitHub's reply, or with status 0
  // after 20 s. A reply that never comes (a stalled reused connection) must not
  // stop a sign-in or a check without a word.
  property var _inflight: []
  function request(method, url, headers, body, done) {
    var x = new XMLHttpRequest()
    var entry = { x: x, started: Date.now(), answered: false, done: done }
    x.onreadystatechange = function() {
      if (x.readyState !== XMLHttpRequest.DONE || entry.answered) return
      entry.answered = true
      root._inflight = root._inflight.filter(function(e) { return e !== entry })
      done(x.status, x.responseText)
    }
    root._inflight = root._inflight.concat([entry])
    x.open(method, url)
    for (var k in headers) x.setRequestHeader(k, headers[k])
    x.send(body || null)
  }

  Timer {
    interval: 2000
    running: root._inflight.length > 0
    repeat: true
    onTriggered: {
      var now = Date.now()
      root._inflight.forEach(function(e) {
        if (e.answered || now - e.started < root.requestTimeoutMs) return
        e.answered = true
        try { e.x.abort() } catch (err) {}
        e.done(0, "")
      })
      root._inflight = root._inflight.filter(function(e) { return !e.answered })
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
    })
  }

  property double _pollStarted: 0
  function begin() {
    if (root._pending === 0) root._pollStarted = Date.now()
    root._pending++
    root.polling = true
  }
  function finish() {
    root._pending = Math.max(0, root._pending - 1)
    if (root._pending === 0) { root.polling = false; root.now = Date.now(); saveState() }
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
      keyClear.running = true
    } else if (root._keyPending !== "") {
      keyStore.stdinEnabled = true
      keyStore.running = true
    }
  }

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
  Process {
    id: keyLookup
    command: ["secret-tool", "lookup", "service", root.keyService, "account", "github"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (/^[A-Za-z0-9_]{20,255}$/.test(t)) root._token = t
        root.keyringChecked = true
        root.tick()
      }
    }
    onExited: function(code) { if (code !== 0) root.keyringChecked = true }
  }

  Process {
    id: keyStore
    command: ["secret-tool", "store", "--label=HowIsMyPlug? GitHub sign-in", "service", root.keyService, "account", "github"]
    onStarted: {
      write(root._keyPending)
      root._keyPending = ""
      stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) root.authError = "Couldn't save the sign-in to the keyring. It works until you log out."
      root.keyringNext()
    }
  }

  Process {
    id: keyClear
    command: ["secret-tool", "clear", "service", root.keyService, "account", "github"]
    onExited: root.keyringNext()
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
  Component.onCompleted: stateRead.running = true

  Process {
    id: stateRead
    command: ["cat", root.stateDir + "/history.json"]
    stdout: StdioCollector {
      id: stateText
      waitForEnd: true
    }
    // A missing file is a first run.
    onExited: function(code) { root.loadState(code === 0 ? stateText.text : "") }
  }

  function loadState(raw) {
    if (stateLoaded) return
    root.state = Model.cleanState(raw)
    root.stateLoaded = true
    keyLookup.running = true
    schedule()
  }

  // History can outgrow a command-line argument, so it goes in on stdin.
  property string _saveQueued: ""
  function saveState() {
    if (!stateLoaded) return
    root._saveQueued = JSON.stringify(root.state)
    if (!stateWrite.running) { stateWrite.stdinEnabled = true; stateWrite.running = true }
  }

  Process {
    id: stateWrite
    command: ["sh", "-c", 'umask 077 && mkdir -p "$1" && cat > "$1/history.json.tmp" && mv -f "$1/history.json.tmp" "$1/history.json"', "sh", root.stateDir]
    onStarted: {
      write(root._saveQueued)
      root._saveQueued = ""
      stdinEnabled = false
    }
    onExited: if (root._saveQueued !== "") { stdinEnabled = true; running = true }
  }

  // Keeps "updated 3 h ago" honest while the bar sits there, and unsticks a
  // check whose request never came back (XHR has no reliable timeout here).
  Timer {
    interval: 60000; running: true; repeat: true
    onTriggered: {
      root.now = Date.now()
      if (root.polling && root.now - root._pollStarted > 120000) {
        root._pending = 0
        root.polling = false
        root.pollError = "GitHub didn't answer. Trying again next time."
        root.saveState()
      }
    }
  }
}
