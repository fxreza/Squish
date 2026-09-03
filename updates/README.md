# Update feed

`latest.json` is what a running copy of Squish checks to learn whether a newer
version exists. It is read from `raw.githubusercontent.com`, so **editing this
file and pushing is the whole release-notification step** - there is no server,
and you do not have to cut a GitHub release before users can be told.

## Publishing an update

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `scripts/build-app.sh`.
2. Build and notarise (or at least build) the new `Squish.app`, zip it, and attach
   it to a GitHub release tagged `vX.Y.Z`.
3. Edit this file: set `version`, `build`, and point `notes` and `download` at that
   release. Push.

Users see it on their next automatic check (at most 24 hours) or immediately when
they choose **Squish > Check for Updates…**.

## Fields

| field | meaning |
|---|---|
| `version` | Compared against the running `CFBundleShortVersionString`, component by component. |
| `build` | Informational only. |
| `critical` | `true` overrides a user's "Skip This Version" and shows a sterner alert. Use it to recall a broken build. |
| `notes` | Page opened if `download` is missing. |
| `download` | What the Download button opens. |
| `minimumSystemVersion` | Shown in the alert so someone on an older macOS knows why to hold off. |

## If you ship something broken

Set `critical: true` and point `version` at the fixed release. Anyone who skipped
the bad one still gets prompted. That is the reason this is a plain file in the
repo rather than the GitHub Releases API - you can correct it in seconds.
