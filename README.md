# Activity Monitor

A small macOS menu-bar app that records which application and window you are actually looking at, and draws the day as a continuous colour-coded timeline.

It exists because the good time trackers are either expensive, cloud-hosted, or have a UI that makes the data hard to look at. This one keeps everything on your machine in a SQLite file, and puts the whole day on one strip you can scrub with the mouse.

<!-- Drop a screenshot at docs/screenshot.png and uncomment:
![The dashboard](docs/screenshot.png)
-->

## What it does

A sampler polls the frontmost application and its focused window title every 2 seconds and adds the elapsed time to a per-minute bucket. Two minutes without keyboard or mouse input counts as **Idle**, and a locked screen counts as **Locked**; both override application attribution, so time away from the machine is never billed to whatever was in front. In Safari and Chromium browsers it also reads the active tab's URL.

Everything you see is computed at read time from **rules** you control. A rule matches on application, window title and URL, and assigns a category plus a display label:

| Category | App | Title pattern | Label |
| --- | --- | --- | --- |
| Deep work | `^Code$` | `^.* — (.+)$` | `$1` |
| Browsing | `^Google Chrome$` | `^(.*?) - Google Chrome` | `$1` |
| Notes | `^Obsidian$` | `^(.*?) - .* - Obsidian` | `$1` |

The first matching rule wins. Because rules are applied when data is read rather than when it is written, editing one **retroactively reshapes every past day** -- you can decide six months from now that a project deserved its own category and the history will agree with you. The raw observations are never modified.

Three views, chosen from the top right:

- **Timeline** -- one slice per minute, coloured by category and stamped with the application's icon. Each minute shows whichever activity owned most of it, which throws away tab-flipping noise. Hover for the time, application, activity and category; click to drill into a bucket.
- **List** -- one row per distinct activity, in the order you first touched it, with start time and total for the day.
- **Rules** -- the rule and category editors, next to a live table of raw observations so you can build a rule from something the sampler actually saw.

Right-click the menu-bar icon for **Reveal Data Folder** and **Quit**.

## Installing

Grab the `.zip` from the [latest release](../../releases/latest), unzip it, and drag `ActivityMonitor.app` into `/Applications`.

The app is **not notarized by Apple** -- notarization needs a paid Apple Developer account. macOS will therefore refuse to open it on the first try. To get past that:

```sh
xattr -dr com.apple.quarantine /Applications/ActivityMonitor.app
```

Or, without the terminal: double-click it, let it be blocked, then go to **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway**.

Then grant permission, or the window titles will all be blank:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Enable **Activity Monitor**.

The app asks for this on first launch. It needs Accessibility because reading another application's window title is exactly what that permission gates. If you use Safari or a Chromium browser, macOS will separately ask for **Automation** permission the first time it reads a tab URL; declining only means browser rows are categorized by page title instead of URL.

To start it automatically at login, add it under **System Settings → General → Login Items**.

## Your data

Everything stays on your machine. There is no network code in this app, no telemetry, and no account.

```
~/Library/Application Support/ActivityMonitor/
  activity.sqlite3    every observation, append-only
  rules.json          your categories and rules
```

Window titles are recorded verbatim, so the database contains the names of documents, repositories, and web pages you had open. Treat it like a diary. Uninstalling the app does not delete it; remove that folder yourself if you want it gone.

The schema is one table and readable with any SQLite client:

```sh
sqlite3 ~/Library/Application\ Support/ActivityMonitor/activity.sqlite3 \
  "SELECT datetime(bucket_start,'unixepoch','localtime'), app_name, title, seconds
   FROM bucket_tally ORDER BY bucket_start DESC LIMIT 20;"
```

## Building from source

Requires macOS 13 or later and the Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not needed.

```sh
bash scripts/make-signing-cert.sh   # once
bash scripts/build.sh
open build/ActivityMonitor.app
```

The certificate step is worth doing before anything else. macOS pins the Accessibility grant to the app's code signature, and an ad-hoc signature is just a hash of the bundle's contents -- so without a stable certificate, every rebuild looks like a brand new app and you re-approve the permission each time. The script creates a self-signed certificate in your login keychain; no Apple Developer account involved.

`scripts/build.sh` honours three environment variables: `AM_SIGN_IDENTITY` (certificate name, or `-` for ad-hoc), `AM_APP_DIR` (output directory), and `AM_UNIVERSAL=1` (build for both arm64 and x86_64).

To iterate on the dashboard without rebuilding, point the app at the source directory:

```sh
AM_RESOURCES="$PWD/Sources/ActivityMonitor/Resources" ./build/ActivityMonitor.app/Contents/MacOS/ActivityMonitor
```

### Layout

| File | What lives there |
| --- | --- |
| `Sampler.swift` | Polling, idle and lock detection, Accessibility and browser URL reads |
| `Store.swift` | SQLite tally, schema migrations |
| `Rules.swift` | Rule matching and the shipped defaults |
| `AppDelegate.swift` | Status item, window, and the read-time aggregation the dashboard asks for |
| `Resources/dashboard.*` | The dashboard, plain HTML/CSS/JS in a WKWebView |
| `Resources/AppIcon.icns` | The app icon, regenerated by `swift scripts/make-icon.swift` |

## Cutting a release

```sh
# 1. Write the notes
$EDITOR CHANGELOG.md          # add a "## [0.2.0] - YYYY-MM-DD" section
git commit -am "Changelog for 0.2.0"

# 2. Ship it
bash scripts/release.sh 0.2.0
```

That builds a universal ad-hoc-signed app into `dist/`, zips it, and shows you exactly what it is about to do. Answer `y` and it writes `VERSION`, commits, tags `v0.2.0`, pushes the branch and the tag, and creates the GitHub release with the changelog section as the release notes. Answer anything else and nothing is pushed.

Every check that can fail -- missing `gh`, dirty tree, tag already taken, no changelog section -- runs before the build, and the build finishes before you are asked to confirm, so you never end up with a tag pointing at something that does not compile. Needs [`gh`](https://cli.github.com) logged in (`gh auth login`).

## Limitations

- Not notarized, so first launch needs the Gatekeeper dance above.
- No launch-at-login toggle in the app; use Login Items.
- The sampler stops when the app is not running. There is no backfill for time it missed.
- Idle threshold, poll interval and the 5-minute noise floor are constants in the source, not settings.
