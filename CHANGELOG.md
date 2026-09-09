# Changelog

Notable changes, newest first. Versions follow [semver](https://semver.org); the format follows [Keep a Changelog](https://keepachangelog.com).

`scripts/release.sh <version>` reads the section matching that version and uses it verbatim as the GitHub release notes, so write the section before cutting the release.

## [0.1.0] - 2026-09-09

First release.

### Added

- Menu-bar app that samples the frontmost application and its focused window title every 2 seconds, and tallies the time into per-minute buckets in a local SQLite database.
- Idle detection after 2 minutes without input, and screen-lock detection, both of which override app attribution so time away is never credited to whatever happened to be in front.
- Active tab URL capture for Safari and Chromium browsers (Chrome, Brave, Edge, Vivaldi, Arc), cached so the AppleScript round trip only happens when the page changes.
- Dashboard in a regular window: a continuous timeline where every minute is a slice colour-coded by category, showing the activity that owned most of that minute. Hovering gives the time, the application, the activity and the category.
- App icons drawn onto the timeline, one per unbroken stretch of the same application.
- Zoom and horizontal scroll, defaulting to 2 pixels per minute scrolled to the present, and zoomable out to the whole day.
- Click any bucket to drill into it, with a breadcrumb back out to the whole day.
- Category totals and a ranked activity table, with spans under 5 minutes rolled into a single hidden line.
- List view: one row per distinct activity, in the order each was first seen, grouped by day or by hour.
- User-editable regex rules that assign a category and a display label from the application, window title and URL. Rules are applied when data is read, never when it is written, so editing one reshapes the entire history.
- Rules editor with a live view of the raw observations, so a rule can be seeded from something the sampler actually recorded.
- App icon: the menu-bar bar-chart symbol with each bar in one of the default category colours, drawn by `scripts/make-icon.swift` so it stays editable.
- `scripts/make-signing-cert.sh`, which creates a stable self-signed certificate so macOS stops dropping the Accessibility grant on every rebuild.
