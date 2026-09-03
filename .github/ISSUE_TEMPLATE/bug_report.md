---
name: Bug report
about: Something in Squish (CLI, app, Quick Actions, or Raycast commands) isn't working right
title: ""
labels: bug
assignees: ""
---

## What happened

A clear description of the bug.

## Where it happened

- [ ] `squish` CLI
- [ ] Squish.app (drag-and-drop / preferences / notifications)
- [ ] Finder Quick Action
- [ ] Raycast script command
- [ ] `scripts/vendor-codecs.sh` / `scripts/build-app.sh` / `scripts/install.sh`

## Steps to reproduce

1. …
2. …
3. …

If this is a CLI bug, please include the exact command (including flags) and, if you can share
it, the input file (or what kind of image it is - format, roughly how large, any unusual
properties like an odd ICC profile or orientation EXIF).

## Expected behavior

What you expected to happen instead.

## Actual behavior

What actually happened. Paste the exact error message, stderr output, or (for `--json` output) the
JSON line, rather than paraphrasing it.

## Environment

- Squish version (`squish --version`, or the app's About panel):
- macOS version (`sw_vers`):
- Installed via: [built from source / downloaded release]
- If built from source: was `vendor/bin` populated via `scripts/vendor-codecs.sh`, or did you hit
  this before running it?

## Anything else

Logs, screenshots, or a minimal reproducing image, if you're able to share one.
