# Clip

Clip is a local-first screen demo editor for macOS. This repository is being
implemented milestone-by-milestone from the supplied design specification.

Implemented milestones:

- **M0 — Model foundation:** deterministic `CoreModel`, canonical JSON, and the
  transactional patch/undo engine.
- **M1 — Library and index:** immutable assets, security-scoped bookmarks,
  project packages, history, and a fully rebuildable SQLite cache.
- **M2 — Ingest:** inbox and pasteboard sources, stability polling,
  asynchronous media probing, sampled hashing/dedupe, thumbnails, audio peaks,
  and the App-layer ingest coordinator.
- **M3 — Shell and workspaces:** a launchable SwiftUI app, shared design tokens
  and components, type-routed drop zones, Inbox asset grid, and screenshot
  shortcuts read from the user's preferences with a truthful unavailable state.
- **M4 — Conversion:** a pure conversion planner, remux, VideoToolbox, ImageIO,
  and linked LGPL FFmpeg backends, plus a live-planned conversion queue with
  backend badges and bounded batch execution.
- **M5 — Composition and playback:** one-track, gapless AVFoundation
  compositions, proxy/full playback rebuilding, a shared-context effect
  compositor, and an AppKit timeline with trim, split, reorder, speed, and exact
  undo/redo.
- **M6 — Effects and export:** crop, background framing, rounded corners,
  shadows, regional blur, and zoom rendering, plus atomic H.264, HEVC, and
  ProRes exports with live progress and codec-aware presets.
- **M7 — Event track:** opt-in, listen-only click capture, system capture-window
  detection, exact/estimated sidecar alignment, an accessible click lane, and
  deterministic click-cluster auto-zoom applied as one undoable patch.
- **M8 — AI layer:** hosted and local provider adapters, tool schemas and App-only
  execution, undoable chat edits, Keychain credentials, an inspectable egress
  ledger, confirmation policy, and on-device captions.
- **M9 — Distribution:** hardened Developer ID and sandboxed App Store channels,
  notarized DMG and App Store Connect release automation, acknowledgements, and
  CI distribution/licence gates.
- **Phase 2 editing:** Finder-safe trash and restore, a shared command registry,
  multi-track precision editing, snapping, transitions, fades, and general
  keyframes.
- **Phase 2 workspaces:** nested folders and export destinations, a non-destructive
  photo editor with local redaction tools, and a PDFium editor with page edits,
  flattened export, font/subset analysis, local OCR, and layout-aware Markdown.

## Run the app

Build and launch a local Debug copy with:

```bash
make run
```

Clip opens a library picker on first launch. Choose a writable folder; Clip
creates its managed `Media`, `Projects`, `Exports`, and `.reel` structure there.

## Test

```bash
make test
```

Requires macOS 14 or later and a Swift 6 toolchain.
Release builds currently target Apple silicon because the pinned FFmpeg
XCFramework is arm64-only.

Generate and build the native app with:

```bash
make build
```

Run the strict formatter gate with `make lint` and validate both distribution
channels with `make distribution-check`.

The checked-in FFmpeg framework targets Apple Silicon. Rebuild it from pinned,
checksum-verified sources with `make ffmpeg`; validate its LGPL-only
configuration with `make licence-audit`. Third-party notices are collected in
[`ACKNOWLEDGEMENTS.md`](ACKNOWLEDGEMENTS.md).

Validate signing metadata for both release channels with
`make distribution-check`. A credentialed tagged release runs `make release`;
required environment variables and App Store handoff are documented in
[`DISTRIBUTION.md`](DISTRIBUTION.md).
