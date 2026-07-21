# Contributing to Vestige

Thanks for considering it. Vestige is meant to stay small, fast, and free, and
contributions that keep it that way are very welcome.

## Getting set up

You need macOS 14+ and the Xcode Command Line Tools. A full Xcode install is
optional.

```bash
git clone <repository-url>
cd vestige
./Scripts/build-app.sh --run
```

Prefer working in Xcode? `open Package.swift`.

Before opening a pull request:

```bash
swift build            # must produce no warnings
./Scripts/build-app.sh
./dist/Vestige.app/Contents/MacOS/Vestige --self-test
```

## Project shape

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. It explains the parts
that are non-obvious on purpose — why the ring buffer holds compressed frames,
why trimming is keyframe-aligned, and why `ReplayBuffer` uses a lock instead of
an actor.

The short version: components are independent and know nothing about each
other; all coordination lives in `AppModel`.

## Guidelines

**Swift 6 strict concurrency, zero warnings.** The project builds clean today
and should stay that way. If you need `@unchecked Sendable`, scope it as
narrowly as possible and write a comment stating the invariant that makes it
safe.

**Keep the data plane off the main actor.** Anything that runs per-frame must
not hop to the main thread. At 120 fps this is the difference between invisible
and noticeable while gaming.

**Explain the why, not the what.** Comments should say why the code is shaped
the way it is. `// increment the counter` helps nobody; `// B-frames would make
decode order differ from presentation order` saves the next person an afternoon.

**No new dependencies.** Vestige depends on nothing outside the macOS SDK, and
that is a feature. If something genuinely needs a dependency, open an issue
first.

**No network code, ever.** Not for updates, not for crash reports, not for
analytics. This is the project's central promise and a PR that breaks it will be
declined regardless of how useful the feature is.

**Prefer fewer settings.** Every new toggle is a permanent maintenance cost and
a decision imposed on the user. Bitrate, for example, is derived from resolution
and frame rate rather than exposed.

## Things that would genuinely help

- Testing on Intel Macs — the hardware encoder path differs and is less exercised
- Better game detection heuristics, especially for launchers and Wine/CrossOver wrappers
- Localisation
- Accessibility review with VoiceOver
- Multi-display capture (currently the main display, or the one you pick)

## Reporting bugs

Include:

- Your macOS version and Mac model
- The output of `Vestige --self-test`
- Relevant logs: `log show --predicate 'subsystem == "app.vestige.Vestige"' --last 10m --info`

Vestige has no crash reporting, so a good description is genuinely all we have.

## Code of conduct

Just be decent people.