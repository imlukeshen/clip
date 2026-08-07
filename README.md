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
- **M5 — Composition and playback foundation:** the original gapless V1
  composition, proxy/full playback rebuilding, a shared-context effect
  compositor, and an AppKit timeline with trim, split, explicit positioning,
  speed, and exact
  undo/redo. The current schema extends that foundation with explicit project
  times and multiple tracks.
- **M6 — Effects and export:** crop, background framing, rounded corners,
  shadows, regional blur, and zoom rendering, plus atomic H.264, HEVC, and
  ProRes exports with live progress and codec-aware presets.
- **M7 — Event track:** opt-in, listen-only click capture, system capture-window
  detection, exact/estimated sidecar alignment, an accessible click lane, and
  deterministic click-cluster auto-zoom applied as one undoable patch.
- **M8 — AI layer:** hosted and local provider adapters, tool schemas and App-only
  execution, undoable chat edits, Keychain credentials, an inspectable egress
  ledger, confirmation policy, provider-specific model settings, local-model
  readiness checks, and on-device captions.
- **M9 — Distribution:** hardened Developer ID and sandboxed App Store channels,
  notarized DMG and App Store Connect release automation, acknowledgements, and
  CI distribution/licence gates.
- **Phase 2 editing foundation:** Finder-safe trash and restore, a shared command
  registry, an explicit-time multi-track schema and renderer, free compatible
  V/A movement, independent track targeting, safe track add/remove, snapping,
  fades, and general keyframes. Track reordering/renaming, richer source routing,
  and true overlapping transitions remain incomplete.
- **Phase 2 workspaces:** nested folders and export destinations, a
  non-destructive layered photo editor with Live Text copy, editable OCR
  replacement layers, and local redaction tools, and a PDFium
  editor with page/text edits, flattened derivative export, font/subset analysis,
  local OCR, calibrated pinch zoom, a safe Command-S derivative workflow, page
  duplication, Add Text, permanent redaction, and layout-aware Markdown.
  Advanced Acrobat parity such as forms, comments, signatures, and arbitrary
  source-object editing remains incomplete.
- **Phase 3 search:** resumable on-device indexing, OCR and Live Text, exact and
  semantic moment search, and agentic search commands.
- **Phase 4 conversion:** a capability-graph planner, image/document backends,
  presets and metadata controls, resilient mixed-file batches, agent commands,
  and optional direct-build LibreOffice integration.
- **Phase 5 text:** a native text editor with syntax highlighting, offline Markdown
  preview, confined LaTeX compilation, SyncTeX diagnostics, multi-file projects,
  rich snippet workflows, direct text indexing, and text-aware agent commands.

### Current timeline model

Project schema v2 stores an explicit, nonnegative project start on every timeline
item. Gaps are valid, items on one track may not overlap, and enabled video tracks
composite bottom to top. Closing a gap is an explicit ripple edit; ordinary move
operations must preserve the time chosen by the user. The `video` and `audio`
array views are compatibility accessors for the primary V1/A1 tracks, not the
current positioning contract.

## Run the app

Build and launch a local Debug copy with:

```bash
make run
```

To work in Xcode, generate and open the canonical project with:

```bash
make xcode
```

Keep only `Clip.xcodeproj` open. The pre-rename `Reel.xcodeproj` and individual
package workspaces refer to the same local Swift packages, so opening them beside
Clip makes Xcode reject the duplicate package ownership.

Clip opens a library picker on first launch. Choose a writable folder; Clip
creates its managed `Media`, `Projects`, `Exports`, and `.reel` structure there.

## Test

```bash
make test
```

Requires macOS 14 or later and a Swift 6 toolchain whose compiler matches its
installed macOS SDK.
Release builds currently target Apple silicon because the pinned FFmpeg
XCFramework is arm64-only.

Run the native interaction suite from an unlocked macOS session with:

```bash
make test-ui
```

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
