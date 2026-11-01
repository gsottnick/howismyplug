// Static guards for SECURITY.md: what the files users receive may and may
// not contain. The panel tests check the same rules at run time.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const shipped = ["Panel.qml", "PlugView.qml", "PlugStore.qml", "Model.js", "DecryptText.qml", "Confetti.qml",
  "TokenRain.qml", "Sparkle.qml", "qmldir", "manifest.json"]
const read = (file) => readFileSync(join(root, file), "utf8")

test("only the expected hosts, and only over HTTPS", () => {
  const allowed = [
    "https://api.github.com",
    "https://github.com",
    "https://api.omarchyplugins.com",
  ]
  for (const file of shipped) {
    for (const [url] of read(file).matchAll(/https?:\/\/[^\s"'`)\\]+/g)) {
      if (url === "http://127.0.0.1:") continue   // the test-only base, checked below
      assert.ok(url.startsWith("https://"), `${file}: ${url} is not HTTPS`)
      const origin = url.match(/^https:\/\/[^/]+/)[0]
      assert.ok(allowed.includes(origin), `${file}: unexpected host ${origin}`)
    }
  }
  // The test override accepts nothing but a local port.
  assert.match(read("PlugStore.qml"), /\/\^http:\\\/\\\/127\\\.0\\\.0\\\.1:\\d\{2,5\}\$\//)
})

test("the token only appears where SECURITY.md says", () => {
  const store = read("PlugStore.qml")
  const allowedLines = [
    /^\s*property string _token: ""$/,
    /readonly property bool signedIn: _token !== ""/,
    /if \(root\._token\) h\["Authorization"\] = "Bearer " \+ root\._token/,
    /if \(\/\^\[A-Za-z0-9_\]\{20,255\}\$\/\.test\(t\)\) root\._token = t/,
    /^\s*root\._token = (token|"")$/,
    /^\s*\/\/ - The GitHub token lives only in the system keyring and in `_token` here\.$/,
  ]
  for (const line of store.split("\n").filter((l) => /(?<!\w)_token\b/.test(l))) {
    assert.ok(allowedLines.some((re) => re.test(line)), `unexpected use of the token: ${line.trim()}`)
  }
  for (const file of shipped.filter((f) => f !== "PlugStore.qml"))
    assert.ok(!/(?<!\w)_token\b/.test(read(file)), `${file} touches the token`)
})

test("secrets reach processes only on stdin", () => {
  const store = read("PlugStore.qml")
  for (const [, cmd] of store.matchAll(/command:\s*(\[[^\n]*\])/g))
    assert.ok(!/token|pending|_clip|secret/i.test(cmd.replace(/"secret-tool"/g, "")), `a command line carries data: ${cmd}`)
  // The keyring write hands over the token with write(), then closes stdin.
  assert.match(store, /id: keyStore[\s\S]*?onStarted: \{\s*write\(pending\)\s*pending = ""\s*stdinEnabled = false/)
})

test("nothing logs, escalates, or runs a shell on input", () => {
  for (const file of shipped) {
    const text = read(file)
    assert.ok(!/console\.(log|warn|error|info|debug)/.test(text), `${file} logs`)
    assert.ok(!/\bsudo\b|\bpkexec\b/.test(text), `${file} escalates privileges`)
    assert.ok(!/execDetached/.test(text), `${file} starts detached processes`)
  }
  // The one shell command takes its directory as an argument, never spliced in.
  const shells = [...read("PlugStore.qml").matchAll(/\["sh", "-c", '([^']*)', "sh", ([^\]]*)\]/g)]
  assert.equal(shells.length, 1)
  assert.ok(!shells[0][1].includes("+"), "the shell script is a constant")
})

test("text from the network is shown as plain text", () => {
  const view = read("PlugView.qml")
  // Every Text bound to repo names, errors or codes declares PlainText.
  for (const marker of ["text: modelData.repo", "text: root.repoError", "text: PlugStore.userCode", "text: root.tokenError || PlugStore.authError", "text: root.repoLine(modelData)"]) {
    const at = view.indexOf(marker)
    assert.ok(at > 0, `missing ${marker}`)
    const block = view.slice(at, view.indexOf("}", at))
    assert.match(block, /textFormat: Text\.PlainText/, `${marker} is not PlainText`)
  }
})

test("shipped files hardcode nothing about a user or machine", () => {
  const forbidden = [
    [/\/home\/[^/\s"']+/, "a home directory"],
    [/\/run\/user\//, "a runtime path"],
    [/[\w.+-]+@(?!example\.com)[\w-]+\.[a-z]{2,}/, "an email address"],
    [/gh[opsu]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}/, "a GitHub token"],
  ]
  for (const file of shipped) {
    const text = read(file)
    for (const [pattern, what] of forbidden) {
      const match = pattern.exec(text)
      assert.equal(match, null, `${file} contains ${what}: ${match && match[0]}`)
    }
  }
})
