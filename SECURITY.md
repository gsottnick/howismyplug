# Security

HowIsMyPlug? reads traffic numbers. It never writes to GitHub, never runs anything it downloads,
and needs nothing beyond what Omarchy ships (Quickshell, libsecret's `secret-tool`, GNOME Keyring,
`wl-copy`).

## What it can access

- **The HowIsMyPlug GitHub app** asks for two permissions: *Administration: read-only* (GitHub's
  traffic API sits under it) and *Metadata: read-only* (every app gets it). It works only on the
  repos you install it on, and only with your approval. Revoke it any time:
  GitHub → Settings → Applications → Authorized GitHub Apps, and → Installed GitHub Apps.
- **A token you paste instead** has whatever you gave it; the README asks for a fine-grained token
  with Administration: read-only on the repos you track.
- The app has no webhooks and no server. The plugin ships only the app's public client ID; there
  is no client secret anywhere.

## Where the token goes

- Stored only in the **system keyring**, via `secret-tool store`, which receives it **on stdin**.
  Read back with `secret-tool lookup` into the plugin's memory.
- Sent only to **api.github.com**, in an `Authorization` header, straight from the shell process
  (QML `XMLHttpRequest`, HTTPS). No child process ever sees it.
- **Never** on a command line (so never in `/proc/*/cmdline`), never in `shell.json`, never in the
  history file, never in a log, never in an error message.
- **Sign out** deletes it from the keyring (`secret-tool clear`). Revoke it on GitHub too if you
  want it dead everywhere.

## Network

Only these hosts, only over HTTPS:

| Host | Why | Sends |
| --- | --- | --- |
| `github.com` | Sign-in (device flow) | The public client ID and the one-time device code |
| `api.github.com` | Traffic, and each tracked repo's `manifest.json` to find its plugin id | Your token |
| `api.omarchyplugins.com` | Marketplace listing stats (public, no login) | Nothing |

Links the dropdown opens in your browser (never fetched by the plugin): the repo on `github.com`, the
app's install page, GitHub's token page, and the listing on `plugins.omarchy.org`. Each is built only
from a validated repo name or plugin id.

The tests point every request at a local fake server through `HOWISMYPLUG_TEST_BASE`, which is
ignored unless it is exactly `http://127.0.0.1:<port>`.

## Input handling

- Repo names must match `owner/repo` with GitHub's allowed characters and are URL-encoded.
- Every response is checked before use: counts must be non-negative integers, dates real dates,
  plugin ids must match the marketplace's own pattern, and the sign-in page must be on
  `https://github.com/`. Anything else is dropped.
- Everything from the network is displayed as plain text.
- The history file is written with `umask 077` (mode 600) through a temp file and a rename; its
  contents go in on stdin, never on a command line.

## Limits

- **Replies:** at most 6 requests run at once, 512 can wait, and each one ends after 20 s. A reply is
  dropped once it grows past 1 MiB (GitHub) or 8 MiB (marketplace stats), checked as each network
  chunk arrives, before it is parsed.
- **Paste:** the repo and token fields never let Qt read the clipboard. Ctrl+V (and Shift+Insert)
  reads at most 4096 characters of text through `wl-paste`, which is stopped after 2 s. The text is
  inserted only if the same field still has focus and nothing changed meanwhile. Middle-click paste
  and the right-click menu are off in those fields.
- **Helpers:** every `secret-tool`, history read and history write runs under `timeout`. A helper
  that fails to start counts as failed: no keyring means signed out, and a history file that can't
  be read is retried every 30 s and never overwritten. A history file over 64 MiB is not loaded and
  is never overwritten.

## Checks

`tests/security.test.mjs` fails the build if a shipped file contacts another host, uses plain
HTTP, puts the token anywhere but the allowed lines, passes data on a command line, logs, or uses
`sudo`. `tests/panel_test.py` runs the real panel and checks that the token never reaches a
command line, the keyring tool's arguments, the history file or `shell.json`, and is only ever
sent to the GitHub API.

## Reporting a problem

Please use GitHub's private vulnerability reporting on this repository (Security → Report a
vulnerability) rather than a public issue.
