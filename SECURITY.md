# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in Squish, please **do not** open a public GitHub issue.

Instead, report it privately using GitHub's vulnerability reporting:

1. Go to the **Security** tab of this repository
2. Click **"Report a vulnerability"**
3. Fill in the details and submit

### What to include

- A clear description of the vulnerability
- Steps to reproduce it
- Potential impact
- Any suggested fix (optional)

### Response timeline

- **Acknowledgement**: Within 48 hours
- **Status update**: Within 7 days
- **Fix / patch**: As soon as reasonably possible, depending on severity

## Scope

Squish is a native macOS image compressor that shells out to bundled, vendored binaries
(mozjpeg, cwebp, oxipng, pngquant, and a perceptual-metric tool) to do the actual encoding.
Security considerations most relevant to this project:

- **Untrusted image input.** Squish decodes arbitrary, potentially attacker-supplied image files
  through Apple's ImageIO and then feeds them to third-party C/C++/Rust encoder binaries -
  parsers are a classic source of memory-safety bugs. A malformed image causing a crash, hang, or
  worse in `squish`, `Squish.app`, or any of the vendored binaries is in scope.
- **The vendored binaries themselves.** Squish does not patch or fork mozjpeg/libwebp/oxipng/
  pngquant/libjxl - it vendors upstream releases as-is (see `scripts/vendor-codecs.sh` and
  `ATTRIBUTION.md`). A vulnerability in one of those projects should generally be reported
  upstream as well as here, since Squish can only fix it by re-vendoring a patched version.
- **Path and argument handling** in the CLI (`squish`), especially `--out`, `--inplace`,
  `-r`/`--recursive`, and directory traversal over user-supplied paths.
- **Clipboard handling** (`--clipboard`), since it reads and writes the system pasteboard, which
  other running apps can also touch.
- **The Quick Actions and Raycast script commands**, since they run with the invoking user's
  full permissions and resolve the `squish` binary's location by searching several paths (see
  `raycast/README.md`) - a compromised or hijacked binary at one of those paths would run with
  that trust.
- **Code signing.** `Squish.app` is currently ad-hoc signed only (see `RELEASE.md`) - it is not
  notarized and has no Developer ID. Reports about the security implications of that (rather than
  a bug in Squish's own code) are useful context but are a known, documented tradeoff rather than
  a vulnerability Squish itself can silently fix.

## Data Handling

Squish operates entirely locally:

- **No network access** at runtime. Every encoder is bundled inside `Squish.app` - see
  `docs/SPEC.md`'s "zero runtime dependencies" constraint. Homebrew is used only at build time to
  vendor those binaries.
- **No telemetry.** Squish does not collect or transmit usage data, crash reports, or analytics.
- **Files are only written where you tell it to.** Squish never overwrites an input file unless
  you pass `--inplace` explicitly, and writes results next to the input (with a `-squish` suffix
  by default) or into `--out DIR` if given.

## Permissions

- **Full Disk Access / folder access** - macOS's standard file-access prompts apply when Squish
  (or a Quick Action running on its behalf) touches files outside its sandbox-equivalent default
  reach, the same as any file-processing app.
- **Notifications** - Squish requests permission to post native notifications on completion,
  falling back to `osascript -e 'display notification'` if that fails under ad-hoc signing (see
  `docs/SPEC.md`). This is cosmetic; declining it doesn't affect compression.
- **Pasteboard access** is used only when `--clipboard` is passed explicitly.

No other system permissions are required or requested.

## Disclosure Policy

We follow responsible disclosure. Once a fix is released, we will publicly acknowledge the
report (with your permission).
