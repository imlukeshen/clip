# CLAUDE.md

Project context for Claude Code. Read this before touching anything.

---

## What this is

clipx is a local-first creative suite for macOS — video timeline, layered photo
editor, PDF editor, and text/LaTeX/Markdown editor — with an AI assistant that
operates every editor through tool calls. It uses Swift 6 language mode and
Swift 6.2 package manifests, targeting macOS 14+. Captures come from the
**system** screenshot tools; there is no in-app recorder.

Open source, Apache-2.0. Distributed as a notarized direct download. An App
Store configuration is kept building but is not published; see
`DISTRIBUTION.md`.

## Read in this order

1. `README.md` — what the product is, how to build and test it
2. `docs/adr/` — every recorded decision, newest last; ADRs override older prose
3. `docs/ROADMAP.md` — what has shipped and what is still open
4. `docs/UI-CURRENT.md` — audited design tokens and layout of the shipped UI
5. `DISTRIBUTION.md` — release channels and signing
6. `Packages/*/README.md` — each package's boundary

The original design documents (DESIGN, STACK, API, UI) were never committed.
Where this file or an older doc mentions them, the code and the ADRs are the
source of truth.

---

## Before writing ANY UI code — read this first

**The shipped app's UI is the source of truth.** `docs/UI-CURRENT.md` records an
audit of it, but `Packages/DesignSystem` (`Theme.swift`) wins where they differ.

Run this protocol before your first UI change, once, and record the result:

1. **Read `Packages/DesignSystem/` in full.** Enumerate every token, component,
   modifier, and preview that exists. This is the real vocabulary.
2. **Grep the app target for hardcoded values** — hex literals, raw spacing
   numbers, font sizes. Where they exist, they represent either drift or a
   deliberate choice the design system doesn't cover yet. Note them; don't change
   them.
3. **Build and screenshot** each workspace at 1440×900 in both appearances.
4. **Update `docs/UI-CURRENT.md`** if what you found differs from it: token
   values, component inventory, layout metrics, spacing rhythm. Report the
   differences — do not resolve them.
5. **Only then** design new surfaces, composing from what already exists.

Standing rules for all subsequent UI work:

- **Never introduce a new colour, radius, spacing step, or font size.** Compose
  from existing tokens. If something genuinely isn't expressible, propose the new
  token and say why, rather than adding it.
- **New components reuse existing primitives.** A new panel should look like it
  was always there.
- **Do not modify existing screens** unless the task is explicitly about them.
  Adding a text editor tab is not licence to restyle the timeline.
- **Improve, don't replace.** If something looks wrong to you, say so and propose
  it separately. Refactoring working UI while adding a feature makes both
  unreviewable.

---

## Non-negotiable invariants

Violating any of these produces bugs that look unrelated to their cause. If a
task seems to require breaking one, stop and ask.

**I1 — Timeline items have explicit, nonnegative project starts.** Gaps are valid,
items within one track must be sorted and non-overlapping, and enabled video
tracks composite bottom to top. Gap closing and downstream time shifts happen
only through explicit ripple operations. The legacy `video` and `audio`
compatibility accessors expose V1/A1; they do not make those tracks implicitly
gapless during ordinary moves.

**I2 — Effect ranges are in clip-local source time**, never timeline time.
Storing timeline time means every ripple edit silently invalidates every effect.

**I3 — `apply(patch)` returns the inverse, and applying the inverse restores the
document exactly.** Property-tested. Every new `GraphOp` needs an inverse.

**I4 — There is exactly one mutation path into the document.** UI, assistant, and
automation all build a `GraphPatch` and call `EditorViewModel.perform(_:)`. Undo,
autosave, and change notification are implemented once, at `apply`. Never mutate
`ProjectDocument` directly.

**I5 — Media assets are immutable unless an ADR says otherwise.** Owned video,
image, audio, and PDF files are `chmod 444` and opened read-only. The documented
exceptions are text assets, which are edited in place (ADR-0009), and referenced
assets, which save back to the user's own file (ADR-0013). Any other code path
that writes to an asset is a bug.

Plus two structural rules:

- **`CoreModel` imports nothing but Foundation.** No AVFoundation, no SwiftUI.
  This is a convention, not a CI check, and two files
  (`ImageDocument.swift`, `PDFEditDocument.swift`) currently import CoreGraphics
  for geometry types.
- **`AIKit` must not depend on `MediaEngine` or `LibraryStore`.** It emits
  `ToolInvocation`; the App layer executes. That edge is what makes the assistant
  testable. CI enforces it with `Scripts/check-aikit-dependencies.sh`.

---

## Commands

```bash
make bootstrap      # toolchain deps — run once
make generate       # Project.yml → clipx.xcodeproj (and removes the stale Reel/Clip projects)
make xcode          # generate and open the one supported Xcode project
make run            # build and launch a Debug copy
make test-packages  # every package plus the app's unit tests, no Xcode — use while iterating
make test           # test-packages plus the dependency, shortcut, and licence gates
make test-ui        # XCUITest suite; needs an unlocked macOS session
make lint           # swift-format lint --strict
make format         # swift-format --in-place
make dmg            # ad-hoc signed DMG, no Apple account needed
make release        # signed, notarized release; needs credentials (DISTRIBUTION.md)
make ffmpeg         # rebuild vendored LGPL FFmpeg — rarely needed
```

Run `make lint && make test-packages` before proposing any change. Do not edit
build settings in Xcode — they live in `App/Reel/Config/xcconfig/`.

---

## How to work through this

The original milestones (M0–M9) and the later releases R1–R8 and R10 have
shipped; `docs/ROADMAP.md` has the status. For any new piece of work:

1. Read the ADRs and code it touches
2. Write the tests first — swift-testing for logic, XCUITest for interaction
3. Implement the smallest thing that satisfies them
4. `make lint && make test-packages`
5. Commit with a Conventional Commit scoped to the package

Prefer many small commits over one large one. If a change is taking more than a
few hundred lines, propose splitting it. A decision worth remembering gets an
ADR in `docs/adr/`.

---

## Conventions

- Swift 6 strict concurrency, `-strict-concurrency=complete`. Never silence a
  concurrency warning with `@unchecked Sendable` — if a type needs it, redesign it.
- Default `internal`. `public` needs a reason. `final` on classes.
- No force unwrapping in `Sources/`. Allowed in `Tests/`.
- One error enum per package, `Sendable & Equatable`. Never `throw NSError`,
  never swallow with `try?` outside best-effort derivative generation.
- `OSLog` only, never `print`. Keys, prompts, and paths outside the library root
  are `privacy: .private` or omitted. Assume logs get pasted into issues.
- One top-level type per file, named for the type. Directories are domain nouns —
  no `Utils/`, `Helpers/`, `Managers/`, `Extensions/`.
- Doc comments required on every `public` symbol.
- swift-testing (`@Test`), not XCTest, for new tests.
- Conventional Commits, package-scoped:
  `feat(mediaengine): clamp zoom centre to canvas bounds`

---

## Things that will get a change rejected

- **Any GPL code.** FFmpeg is LGPL-only, built without `--enable-gpl`, x264, or
  x265. H.264 and HEVC come from VideoToolbox. CI fails the build otherwise, and
  this keeps App Store distribution possible. A dual-licensed component may be
  used under its non-GPL option; record the election in `ACKNOWLEDGEMENTS`.
- **A hardcoded keyboard shortcut in the UI.** Shortcuts are read from
  `com.apple.symbolichotkeys` or not shown at all. CI greps for literal `⌘⇧⌃⌥`
  outside `DesignSystem` and fixtures.
- **`CGSGetSymbolicHotKeyValue`** or any other private API. It will fail review.
- **A new third-party dependency** without justification in the PR description.
  The reviewed SwiftPM set is in `Scripts/allowed-package-urls.txt` (GRDB,
  swift-markdown, swift-docc-plugin, and the Tree-sitter runtime with its pinned
  grammars); vendored components are listed in `ACKNOWLEDGEMENTS.md`. Keeping
  that list short is deliberate.
- **A hex colour outside `DesignSystem`.** Use `Theme` tokens.
- **Adding `ScreenCaptureKit`.** v1 has no in-app recorder by design, and that
  decision buys us a full OS version of reach. (ADR-0014 proposes screen
  capture for the assistant only; it is not accepted.)
- **Transcoding on ingest.** `AVMutableComposition` is time-based; concatenating
  variable-frame-rate clips does not drift. This is a correction to a common
  wrong intuition.
- **Spawning `ffmpeg` as a subprocess.** It is linked in-process. A bundled
  binary inherits the sandbox and cannot open user files.

---

## Things that are genuinely undecided

Do not resolve these unilaterally — surface the tradeoff and ask.

1. **Capture-window detection reliability.** Polling for the `screencapture`
   process at 5 Hz is the weakest link in the design. M7 has an explicit kill
   criterion: if exact alignment lands below 80 % across 20 real recordings, drop
   the process watcher and ship estimation-only.
2. **Right rail: pinned or collapsible.** Decide with real layout.
3. **Undo coalescing window** for continuous trim gestures.
4. **HDR captures.** v1 tone-maps to sRGB; may need to become a real pipeline
   decision.
5. ~~**The name.**~~ Settled: the product is **clipx**. Note that this is the
   *product* name only. The Swift modules, the `App/Reel/` directory, and the
   bundle identifier `app.reel.editor` are still the original internal names,
   and renaming them is a separate change — the bundle identifier in particular
   is the app's identity for preferences and TCC grants, so changing it would
   reset both. On-disk state is looked up through
   `AppModel.preferredAppDirectory`, which prefers `clipx` and falls back to
   `Clip` then `Reel`, so a library made under an earlier name keeps working.

---

## Known gaps in the docs

Be honest about these rather than inventing answers:

- Decisions taken before ADRs were kept — linking FFmpeg in-process, LGPL-only
  FFmpeg, no ScreenCaptureKit recorder, and reading shortcuts from
  `com.apple.symbolichotkeys` — have no ADR yet. Write one, one page each
  (context, decision, consequences, what would make us revisit), when you next
  change that area.
- There is no generated schema reference; `CoreModel` is the source of truth.
- Caption editing UI is unspecified. `generateCaptions` produces segments; how a
  user corrects them is an open design question.

If you hit something the docs don't cover, say so and propose an option rather
than picking silently. A wrong guess buried in an implementation is much more
expensive than a question.
