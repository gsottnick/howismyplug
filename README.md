# HowIsMyPlug?

![HowIsMyPlug? in the Omarchy bar](preview.png)

An Omarchy bar plugin for people who publish Omarchy plugins. It shows how your plugins are doing:

- **Clones and repo views** from GitHub, for every repo you track. GitHub only keeps 14 days of
  traffic; HowIsMyPlug? saves each day on your machine, so you keep the full history for free.
- **Listing views, install-command copies and hearts** from your Omarchy marketplace listing.
- **Milestones**: open the dropdown after you pass 100 clones (or any number and stat you pick)
  and it celebrates, once.

Pick a period (7, 14 or 30 days, or all time) and total, unique or both counts in the dropdown.

## Quick start

1. Add the plugin from the Omarchy plugin marketplace, or:
   `omarchy plugin add https://github.com/gsottnick/howismyplug`
2. Open the dropdown and type a repo you own (`owner/repo`). Marketplace numbers show right away.
3. For clones and repo views, click **Sign in with GitHub** (the **?** button in the dropdown shows these
   steps too). The code is copied for you: paste it
   on the page that opens and click Authorize. Then click **Give access** (or **Choose repos**)
   and pick your repos. Picking "All repositories" means you never have to do it again.

That's all. No API key to create, no server, no account with anyone but GitHub.

### Prefer a token?

Click **Use a token instead** and paste a
[fine-grained token](https://github.com/settings/personal-access-tokens/new) with
*Repository permissions → Administration: Read-only* for the repos you track. GitHub files traffic
under "administration"; read-only can't change anything.

## Settings

Everything is in the dropdown. **⚙** opens the settings, **?** the help, and each repo in the list
opens its own page.

**Each repo** (tap it in the list): its own numbers for the chosen period, how often to check GitHub
traffic and the listing (every hour, day, 2 days, week or 2 weeks; changing it checks right away), its own milestones (on/off, which stat,
every how many), and links to the repo and its listing.

**Settings page**:

| Setting | Choices | Default |
| --- | --- | --- |
| Bar number comes from | all repos combined, or any one repo | all repos |
| Bar number shows | clones, unique clones, repo views, unique repo views, listing views, copies, hearts | clones |
| Dropdown size | compact, normal, tall (the height is fixed; long lists scroll) | normal |
| Highlight colour | theme accent, text, alert | accent |
| Clones and views | total, unique, both | both |
| Animations | on, off | on |
| Show combined totals | on, off | on |
| Combined milestones | on/off, which stat, every how many | on, clones, 100 |
| New repos start with | GitHub and listing check intervals | daily, daily |

The period (7, 14, 30 days or all time) is picked at the top of the overview and each repo page. The
same settings also appear in Omarchy's widget settings.

## Good to know

- **History starts when you add a repo**, plus the 14 days GitHub still has at that moment.
- **Totals** (clones, views) add up day by day: each day is stored once and replaced, never added, when
  a later check sees it again, so overlapping 14-day windows can't double count.
- **Unique numbers**: lifetime starts with GitHub's 14-day unique number at the first check, then adds
  each new day's unique number as GitHub reports it (100 at the start + 20 over the next days = 120).
  "14 days" shows GitHub's own number, the same as its traffic page: different people. The other periods
  are unique per day, so one person on several days counts more than once. GitHub's window rolls (a day
  in, a day out) and every day is saved before it drops out. `tests/math.test.mjs` proves this against
  simulated traffic on every schedule.
- **Computer off?** Every number is stored under its date. The next check fills in the days that were
  missed, as long as it happens within 14 days.
- **Gaps**: if the computer is off (or the shell isn't running) for more than 14 days, the days
  GitHub dropped in between are gone. The dropdown says which ones.
- **Marketplace numbers** are the marketplace's own lifetime counts; periods show the growth
  since HowIsMyPlug? started watching.
- "Every 2 weeks" checks every 13 days, so no day falls out of GitHub's 14-day window.

## Privacy and security

Your GitHub sign-in stays in your system keyring and only ever goes to GitHub. The app can only
read traffic on the repos you choose, and you can revoke it any time on GitHub
(Settings → Applications). Nothing is sent anywhere else. The full list is in
[SECURITY.md](SECURITY.md).

Where things live:

| What | Where |
| --- | --- |
| GitHub sign-in or token | System keyring (GNOME Keyring), item "HowIsMyPlug? GitHub sign-in" |
| Traffic history | `~/.local/state/howismyplug/history.json` (only you can read it) |
| Settings | Omarchy's `shell.json`, like every bar widget |

To start over: Sign out in the dropdown, then delete `~/.local/state/howismyplug`.

## Requirements

Nothing to install beyond Omarchy itself. This release is tested on Omarchy 4.0.6, the current stable release, and on Omarchy 4.5.0-rc3, the current 4.5 prerelease. On 4.5 the bar draws the number and follows the system animation switch. On 4.0.6 the plugin draws the number.

The plugin uses what Omarchy ships:

- Omarchy's shell (Quickshell) to run and to talk to GitHub and the marketplace
- `secret-tool` (libsecret) and GNOME Keyring to keep your GitHub sign-in
- `wl-copy` (wl-clipboard) to copy the sign-in code

It talks to `api.github.com` and `github.com` (your traffic, sign-in) and `api.omarchyplugins.com`
(public listing stats). Signing in uses the **HowIsMyPlug** GitHub app, which can only read traffic on the
repos you choose. See [SECURITY.md](SECURITY.md).

## Remove

```bash
omarchy plugin remove io.github.gsottnick.howismyplug
```

That removes the plugin and its bar entry. To also remove what it saved:

1. Before removing, open the dropdown, then ⚙ and **Sign out** (deletes the sign-in from your keyring), or
   afterwards: `secret-tool clear service io.github.gsottnick.howismyplug account github`
2. Delete the saved history: `rm -r ~/.local/state/howismyplug`
3. Optionally revoke the app on GitHub: Settings → Applications → Authorized GitHub Apps → HowIsMyPlug
   (and Installed GitHub Apps → HowIsMyPlug → Uninstall).

## Contributing

Tests, the preview image and how changes are made: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
