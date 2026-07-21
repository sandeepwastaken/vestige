# Architecture

This document explains how Vestige is put together and, more usefully, *why*
the non-obvious parts are the way they are.

## The pipeline

```
┌──────────────────┐   CVPixelBuffer   ┌──────────────┐   CMSampleBuffer
│ ScreenCaptureKit │ ────────────────► │ VideoEncoder │ ─────────────────┐
│    (SCStream)    │    420v, scaled   │ VideoToolbox │   H.264 / HEVC   │
└──────────────────┘                   └──────────────┘                  │
         │                                                               ▼
         │  system audio (PCM)                              ┌────────────────────┐
         └────────────────────────────────────────────────► │    ReplayBuffer    │
                                                            │  ring, in memory   │
                                                            └────────────────────┘
                                                                       │
                                                          hotkey ──► snapshot()
                                                                       │
                                                                       ▼
                                                            ┌────────────────────┐
                                                            │     ClipWriter     │
                                                            │   AVAssetWriter    │
                                                            └────────────────────┘
                                                                       │
                                                                       ▼
                                                                  clip.mp4
```

## Why the buffer holds compressed frames

The central constraint is memory. Two minutes of 1080p60 raw video is about
10 GB, which rules out buffering uncompressed frames entirely.

So encoding runs **continuously**, and the ring buffer holds the encoder's
output. At a derived bitrate of roughly 12 Mbps, two minutes costs about
180 MB — an acceptable resident footprint for a background app.

This has a second, larger benefit: saving a clip becomes a **remux**. The frames
are already compressed, so `ClipWriter` copies them into an MP4 container
without touching a pixel. A two-minute clip writes in well under a second, which
is what makes the hotkey feel instantaneous.

The cost is that the encoder runs the entire time the buffer is armed. That is
why it is configured for sustained low overhead rather than peak quality, and
why hardware encoding matters so much.

## Why trimming is keyframe-aligned

Every frame except a keyframe is encoded as a difference from earlier frames. A
clip that starts anywhere else decodes as garbage.

So `ReplayBuffer` never discards past the newest keyframe that is still older
than the retention window. Keyframes are forced every two seconds, which means
the buffer holds between `duration` and `duration + 2s` of footage, and the
leading edge of a clip has two seconds of granularity.

`ClipWriter` re-checks this rather than trusting it, because a mid-GOP start is
a silent corruption — the file gets a plausible duration and plays as noise.

## Why B-frames are disabled

B-frames reference *future* frames, which makes decode order differ from
presentation order. That would mean a frame is not safely buffered until later
frames arrive, and it complicates trimming. Turning them off costs a few percent
of compression efficiency and removes an entire class of ordering bug.

## Why capture restarts split a clip

Display changes, waking from sleep, and encoder faults all force a new
`VTCompressionSession`, which produces a new format description (different
SPS/PPS). A passthrough track carries exactly one format.

`ClipWriter.usableFrames(in:)` therefore takes the newest contiguous run of
frames sharing the final frame's format, then starts at the first keyframe in
that run. The user pressed the hotkey to capture what *just* happened, so
truncating the older half is the right trade — and it is why a clip is sometimes
shorter than the configured duration.

## Permission checks must never prompt on a timer

This is the subtlest trap in the codebase and it has already caused one bug, so
it is documented rather than left to be rediscovered.

Querying `SCShareableContent` is the only authoritative way to know whether the
capture server will serve this process. But when TCC holds **no decision** for
the running binary, that query *raises the permission dialog*. Vestige polls
every two seconds to notice a permission granted while it is running — and an
early version polled using that authoritative query. The result was a permission
dialog every two seconds, forever, which the user could not escape.

The rule, enforced in `PermissionsManager.probe()`:

- `CGPreflightScreenCaptureAccess()` **never prompts** and returns true only when
  a positive grant already exists for this exact binary. Everything automatic
  goes through it first.
- `SCShareableContent` is only reached *behind* that gate, where it can no
  longer raise a dialog. It can still fail, and that failure is the signal that
  the grant arrived after launch and the process must restart.
- `CGRequestScreenCaptureAccess()` is the sole prompting call, reachable only
  from a button.
- `CaptureEngine.startInternal()` carries the same preflight gate, because its
  restart backoff re-enters on a timer and would otherwise reopen the same hole.

`Vestige --permissions` runs `probe()` five times and reports the result, so a
regression here is demonstrable rather than theoretical.

## Why the grant keeps disappearing between builds

macOS ties Screen Recording to a **code signature**. Ad-hoc signing produces a
different signature on every build, so each rebuild is a new app as far as TCC
is concerned — which is why System Settings can show Vestige switched on while
Vestige is denied. The stale entry has to be removed with the **−** button, or
`Scripts/make-signing-cert.sh` can create a stable local signing identity for
source builds.

`build-app.sh` installs to `/Applications` for the same reason: one canonical
location means one entry in System Settings rather than one per build location.

## Capture targets

`CaptureTarget` is either a display or a specific application's window.

For window capture, `ShareableContentProvider.makeFilter(for:)` finds the
largest on-screen window belonging to the game's process — games commonly open
splash screens, hidden helpers, and anti-cheat overlays, so "largest" is a far
better heuristic than "first", and windows under 200pt are rejected outright so
a helper window cannot win before the real one appears.

Two details that are easy to get wrong:

- **Pixel size comes from the filter**, via `contentRect` × `pointPixelScale`,
  not from the window's frame. A window dragged to a non-Retina external display
  has a different scale from the same window on the built-in panel.
- **Shadows and corner masks are excluded** (`ignoreShadowsSingleWindow`,
  `ignoreGlobalClipSingleWindow`, `shouldBeOpaque`), or clips get translucent
  edges instead of a clean rectangle.

A window target that cannot be resolved falls back to display capture. An
unexpected full-screen clip is a much better failure than a buffer that silently
holds nothing.

## Concurrency model

Vestige builds under **Swift 6 strict concurrency** with no warnings.

**The control plane runs on the main actor.** `AppModel`, `CaptureEngine`,
`ClipStore`, `SettingsStore`, and every manager are `@MainActor @Observable`.
They are driven by the UI and drive the UI back, so this removes almost all
synchronisation questions.

**The data plane never touches the main actor.** ScreenCaptureKit delivers
frames on its own queue straight into `VideoEncoder`, and VideoToolbox's
callback pushes them straight into `ReplayBuffer`. At 120 fps, a frame arriving
does not wake the main thread.

### Why `ReplayBuffer` is a lock, not an actor

Frames arrive from two threads and order within each stream must be preserved
exactly. Appending to an actor requires wrapping each call in a `Task`, and
concurrent tasks are **not guaranteed to reach an actor in creation order** —
that would silently interleave frames. An `NSLock` keeps appends synchronous on
the calling thread, which preserves ordering by construction and costs less per
frame.

### Non-`Sendable` framework types

AVFoundation, ScreenCaptureKit, and UserNotifications predate strict
concurrency. Where their types are genuinely confined to one context, the file
uses `@preconcurrency import` or a narrowly scoped `@unchecked Sendable` wrapper
with a comment stating the invariant that makes it safe. `ShareableContent.swift`
goes further and projects ScreenCaptureKit's object graph into plain `Sendable`
structs at the boundary, so those classes never cross an actor at all.

### Cleanup and `deinit`

Swift 6 forbids a `deinit` from touching main-actor state. Types that own
resources needing guaranteed release — Carbon hot keys, `DispatchSource`
watchers, `NotificationCenter` tokens — delegate them to a small nonisolated
class whose own `deinit` does the cleanup. This is why `CarbonRegistration`,
`DirectoryWatcher`, and `NotificationObservers` exist as separate types.

## Modules

| Module | Responsibility |
|---|---|
| `App` | `AppModel` (root view model), entry point, app delegate |
| `Capture` | `SCStream` lifecycle, recovery, `Sendable` projections of SCK types |
| `Encoding` | `VideoEncoder` (VideoToolbox), `ClipWriter` (muxing) |
| `ReplayBuffer` | The ring buffer and its frame types |
| `Storage` | `ClipStore`, the `Clip` model, directory watching |
| `Hotkeys` | Carbon registration and the binding model |
| `Permissions` | Screen Recording status, recovery, relaunch |
| `Settings` | Persisted preferences, capture option types, login item |
| `Notifications` | `UNUserNotificationCenter` wrapper |
| `GameDetection` | Heuristics for "is a game running" |
| `Diagnostics` | `--self-test` |
| `UI` | SwiftUI views |
| `Utilities` | Logging, formatters, observer lifetime helpers |

Components do not know about each other. `CaptureEngine` knows nothing about
games or notifications; `ClipStore` knows nothing about capture. All coordination
lives in `AppModel`, which keeps the app's actual behaviour readable in one file.

## Reliability

`CaptureEngine` restarts itself with exponential backoff (capped at 30s) when
the stream stops, the encoder faults, the display configuration changes, or the
machine wakes from sleep. It tears down cleanly on sleep rather than letting the
capture server drop the session underneath it.

`ClipWriter` falls back to writing a video-only clip if the audio track fails to
encode — a silent clip is a far better outcome than no clip. `ClipStore` moves
deleted clips to the Trash rather than unlinking them. `AppModel` refuses to
start a save when free space is below 512 MB, and removes any partial file if a
write fails.

## Testing

`Vestige --self-test` runs the encoder, buffer, and muxer against synthetic
frames and verifies the resulting MP4 decodes. It covers the logic most likely
to break subtly and least visible in the UI.

XCTest is not used because it ships with Xcode rather than the Command Line
Tools, and the project deliberately builds with only the latter.
