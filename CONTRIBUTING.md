# Contributing to Mllama

Thanks for your interest. Mllama is a single-developer side project, but contributions are welcome.

## Setup

```bash
git clone https://github.com/Mirxa27/mllama
cd mllama

# debug build (faster compile, no -O)
./build.sh

# launch
./build.sh debug --run

# release build with optimization
./build.sh release
```

Requirements:

- macOS 13.0 (Ventura) or newer
- Xcode 15+ command-line tools (Swift 5.9 or newer)

The build script compiles every `.swift` under `src/` into one Mach-O binary, patches `Info.plist`, copies the privacy manifest, and ad-hoc codesigns. There's no Xcode project — open `src/` in your editor of choice.

## Tests

```bash
swift Tests/verify.swift
```

Pure-function tests (no XCTest harness needed). Covers:

- `DiffusionFamily.detect` — filename → model family recognition
- `ScriptedTool` shell escaping & template substitution
- `prettifyModelName` — pill-label cleanup
- `UpdateChecker.isNewer` — semantic-version comparison

Tests run automatically on every push via `.github/workflows/ci.yml`.

When you add new pure logic, add a test next to it in `Tests/verify.swift`. For SwiftUI views and side-effecting code, manual testing in the running app is currently the bar.

## Code style

- Swift 5.9, dark-first SwiftUI, target macOS 13+
- **Many small files > few large files.** Aim for <500 lines per file; split when a file grows past 800.
- **Immutability by default.** Prefer `let` over `var`. Prefer structs/enums over classes.
- **Sendable + actor isolation.** All shared mutable state goes behind an `actor` or `@MainActor`.
- **No `print` / `NSLog`.** Use `Log.<category>` from `src/Logging.swift`, with `privacy:` interpolation tags.
- **No force unwrap (`!`)** without a one-line comment explaining why.
- **Comments answer "why", not "what".** Identifier names cover what.
- **Run the test suite before pushing.**

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the directory tour, subsystem map, and key invariants.

## Pull requests

- One topic per PR.
- Run `./build.sh release` locally — CI repeats this, but iterating in CI is slow.
- For UI changes, include a screenshot in the PR description.
- For new subsystems, update `ARCHITECTURE.md`.

## Releases

Maintainer-only (the `release.yml` workflow needs Developer ID secrets). Bump version in `Mllama.app/Contents/Info.plist`, push a `vX.Y.Z` tag, and the workflow signs, notarizes, staples, and uploads the DMG.

## License

By contributing you agree your work is released under the MIT license (see [LICENSE](./LICENSE)).
