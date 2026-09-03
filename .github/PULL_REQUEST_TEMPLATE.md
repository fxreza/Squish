## What does this change?

A clear description of what changed and why.

## Where does it touch?

- [ ] `Sources/SquishCore` (decode/encode/metric/pipeline)
- [ ] `Sources/squish` (CLI)
- [ ] `Sources/SquishApp` (AppKit app)
- [ ] `scripts/` (vendoring / build / install)
- [ ] `quickactions/` (Finder Quick Actions)
- [ ] `raycast/` (Raycast script commands)
- [ ] `tests/`
- [ ] `docs/SPEC.md` (the CLI/behavior contract)
- [ ] Something else - please describe above

## Does this change `docs/SPEC.md`'s contract?

If this adds/removes a CLI flag, changes a default, changes the JSON output shape, or changes
mode behavior, `docs/SPEC.md` needs to change in the same PR - it's the source of truth other
code (and other contributors) build against.

- [ ] Yes, and `docs/SPEC.md` is updated in this PR
- [ ] Yes, but `docs/SPEC.md` doesn't need to change (explain why above)
- [ ] No

## Does this touch which codecs get vendored?

If you added, removed, or swapped a binary/library in `scripts/vendor-codecs.sh`, its license
needs checking against `ATTRIBUTION.md` before this merges - Squish currently ships one
GPL-3.0-or-later binary (`pngquant`) deliberately and documented; a new copyleft dependency
showing up unremarked is exactly the kind of thing that's easy to miss in review.

- [ ] N/A - this PR doesn't touch vendored codecs
- [ ] Yes, and I've checked the license and updated `ATTRIBUTION.md`

## Testing

- [ ] `./tests/run-tests.sh` passes
- [ ] `./scripts/verify-vendor.sh` passes (only relevant if you touched vendoring)
- [ ] Tested manually - describe how below

## CHANGELOG

- [ ] Added an entry to `CHANGELOG.md` under `## Unreleased` (for anything user-visible: a new
      mode, flag, entry point, or behavior change)
- [ ] Not needed (internal refactor, docs, tests, CI only)
