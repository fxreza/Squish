# Squish Raycast script commands

Five [Raycast Script Commands](https://developers.raycast.com/basics/create-a-script-command) that
wrap the `squish` CLI.

**Each script is fully standalone** - the `squish` binary lookup is inlined into every file, not
shared from a `lib/` directory. Raycast's own model is that people copy individual `.sh` files
into their own Script Commands folder, so a script that `source`s a sibling file breaks the
moment it's copied alone. Feel free to grab just the one or two commands you want; you don't need
this whole `raycast/` folder.

## Install

1. Open Raycast, go to **Settings → Extensions → Script Commands**.
2. Click **Add Directory** and point it at this folder (`raycast/` inside the Squish repo,
   or wherever you cloned/installed Squish - e.g. `/Applications/Squish.app` doesn't contain
   these, they live alongside the source) - or copy individual `.sh` files anywhere you like,
   including into another Script Commands directory of your own.
3. The commands appear immediately, searchable by title from Raycast's root.

Each script contains its own `locate_squish()` lookup, which finds the `squish` binary in order:
1. `$SQUISH_BIN`, if set and executable - an explicit override, and the easiest way to run
   these scripts by hand before installing (Raycast itself won't set this).
2. `command -v squish` - whatever's on `PATH`, when the calling shell does inherit one.
3. `/usr/local/bin/squish` (symlinked there by `scripts/install.sh`)
4. `/Applications/Squish.app/Contents/Resources/bin/squish`
5. `$HOME/Applications/Squish.app/Contents/Resources/bin/squish`

Raycast runs script commands with a minimal environment (no shell profile, often a stripped
`PATH`), so the absolute paths (3-5) are the primary mechanism in practice - 1 and 2 mainly make
the scripts testable from a terminal. If none of the five resolve, the command prints a clear
error instead of failing silently.

## Commands

| Command | What it does |
|---|---|
| **Compress Clipboard Image** | Compresses the image currently on the clipboard (`jpeg` mode) and puts the result back on the clipboard. |
| **Compress Clipboard to WebP** | Same, but via `webp` mode. |
| **Compress Clipboard (Visually Lossless)** | Same, but via `vlossless` mode. |
| **Compress Finder Selection** | Compresses whatever's selected in the frontmost Finder window, using your default mode (set in Squish's Preferences). |
| **Compress Last Screenshot** | Finds the newest screenshot in your screenshot folder (`~/Desktop` unless you've changed `screencapture`'s location) and compresses it with your default mode. |

All commands print a one-line summary in Raycast's compact result view.

The two file-based commands report a percentage saved, measured against the real file size:

```
Screenshot 2026-09-02 at 9.14.02 AM.png · 8.7 MB → 793.3 KB · saved 91%
```

The three clipboard commands do **not** show a percentage. AppKit's pasteboard carries an
uncompressed TIFF representation, so `bytesIn` in the CLI's JSON is the TIFF size, not the size
of whatever the user actually copied - a percentage against that number reads as a wildly
inflated (and meaningless) saving no matter what was on the clipboard. Instead they lead with
the number that actually matters when you're about to paste the result somewhere:

```
Compressed → 736 KB  (JPEG, q84)
Compressed → 6.4 KB  (WebP, q82)
Compressed → 5.5 KB  (vlossless, score 100)
```

## Notes

- The clipboard commands rely on `squish <mode> --clipboard --json`, which reads an image from
  the pasteboard and writes the compressed result back to it - no temp files to clean up.
- "Compress Finder Selection" and "Compress Last Screenshot" read Squish's saved default mode
  from `defaults read com.fxreza.squish defaultMode`, falling back to `jpeg` if Squish.app has
  never been opened / no preference has been set.
