# CLAUDE.md

Project context for Claude Code. Read this before touching anything.

---

## What this is

Reel is a local-first screen demo editor for macOS, written in Swift 6.4,
targeting macOS 14+. Captures come from the **system** screenshot tools — there
is no in-app recorder. The app ingests them, stitches them on a timeline, edits
non-destructively, converts formats, and exposes an AI assistant that operates
the editor through tool calls.

Open source, Apache-2.0, distributed both direct and via the Mac App Store.

## Read in this order

1. `README.md` — what the product is
2. `docs/DESIGN.md` — low-level design, data model, services, **milestones**
3. `docs/STACK.md` — tech stack, repo layout, build config, conventions
4. `docs/API.md` — package APIs, provider contracts, tool schemas, file formats
5. `docs/UI.md` — design tokens, components, screen specs
6. `docs/prototypes/*.html` — interactive visual reference

The prototypes are **reference, not source**. They are HTML; the app is SwiftUI
and AppKit. Read them for hierarchy, states, and interaction feel. Take every
number from `docs/UI.md` §2 instead of measuring them.

---

## Before writing ANY UI code — read this first

**The shipped app's UI is the source of truth, not `docs/UI.md`.** The UI has been
improved by hand since that document was written. `docs/UI.md` is now a historical
reference describing intent, not current state. Do not implement from it, and do
not "fix" the app to match it.

Run this protocol before your first UI change, once, and record the result:

1. **Read `Packages/DesignSystem/` in full.** Enumerate every token, component,
   modifier, and preview that exists. This is the real vocabulary.
2. **Grep the app target for hardcoded values** — hex literals, raw spacing
   numbers, font sizes. Where they exist, they represent either drift or a
   deliberate choice the design system doesn't cover yet. Note them; don't change
   them.
3. **Build and screenshot** each workspace at 1440×900 in both appearances.
4. **Write `docs/UI-CURRENT.md`**: actual token values, component inventory with
   observed states, layout metrics, spacing rhythm, and anything that differs
   from `docs/UI.md`. Report the differences — do not resolve them.
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

**I1 — The video track is gapless and starts at zero.** Timeline position is
derived from preceding items' durations, never stored.

**I2 — Effect ranges are in clip-local source time**, never timeline time.
Storing timeline time means every ripple edit silently invalidates every effect.

**I3 — `apply(patch)` returns the inverse, and applying the inverse restores the
document exactly.** Property-tested. Every new `GraphOp` needs an inverse.

**I4 — There is exactly one mutation path into the document.** UI, assistant, and
automation all build a `GraphPatch` and call `EditorViewModel.perform(_:)`. Undo,
autosave, and change notification are implemented once, at `apply`. Never mutate
`ProjectDocument` directly.

**I5 — Assets are immutable.** `chmod 444` on import, opened read-only. Any code
path that writes to `Assets/` is a bug.

Plus two structural rules CI enforces:

- **`CoreModel` imports nothing but Foundation.** No AVFoundation, no SwiftUI.
- **`AIKit` must not depend on `MediaEngine` or `LibraryStore`.** It emits
  `ToolInvocation`; the App layer executes. That edge is what makes the assistant
  untestable.

---

## Commands

```bash
make bootstrap      # toolchain deps — run once
make generate       # Project.yml → Reel.xcodeproj (the project file is gitignored)
make test-packages  # fast: packages only, no Xcode, ~90s — use this while iterating
make test           # packages + app targets
make lint           # swift-format lint --strict
make format         # swift-format --in-place
make ffmpeg         # rebuild vendored LGPL FFmpeg — rarely needed
```

Run `make lint && make test-packages` before proposing any change. Do not edit
build settings in Xcode — they live in `App/Reel/Config/xcconfig/`.

---

## How to work through this

`docs/DESIGN.md` §14 defines milestones M0–M9. **Work one at a time, in order.**
Each has an explicit acceptance criterion. Do not start the next until the
current one's criterion is demonstrably met and `main` is green.

M0 (CoreModel) has no UI and must be complete first. It is tempting to start with
a screen because progress is visible; don't. Everything else codes against the
model, and changing it later touches every package.

For each milestone:

1. Re-read the relevant `DESIGN.md` section in full
2. Write the tests from the acceptance criterion **before** the implementation
3. Implement the smallest thing that satisfies them
4. `make lint && make test`
5. Commit with a Conventional Commit scoped to the package

Prefer many small commits over one large one. If a milestone is taking more than
a few hundred lines, propose splitting it.

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
  this is what keeps App Store distribution legal. See `docs/adr/0003`.
- **A hardcoded keyboard shortcut in the UI.** Shortcuts are read from
  `com.apple.symbolichotkeys` or not shown at all. CI greps for literal `⌘⇧⌃⌥`
  outside `DesignSystem` and fixtures. See `docs/adr/0006`.
- **`CGSGetSymbolicHotKeyValue`** or any other private API. It will fail review.
- **A new third-party dependency** without justification in the PR description.
  Current count is four; that is deliberate.
- **A hex colour outside `DesignSystem`.** Use `Theme` tokens.
- **Adding `ScreenCaptureKit`.** v1 has no in-app recorder by design, and that
  decision buys us a full OS version of reach. See `docs/adr/0001`.
- **Transcoding on ingest.** `AVMutableComposition` is time-based; concatenating
  variable-frame-rate clips does not drift. See `DESIGN.md` §5.5 — this is a
  correction to a common wrong intuition.
- **Spawning `ffmpeg` as a subprocess.** It is linked in-process. A bundled
  binary inherits the sandbox and cannot open user files. See `docs/adr/0002`.

---

## Things that are genuinely undecided

Listed in `DESIGN.md` §15. Do not resolve these unilaterally — surface the
tradeoff and ask.

1. **Capture-window detection reliability.** Polling for the `screencapture`
   process at 5 Hz is the weakest link in the design. M7 has an explicit kill
   criterion: if exact alignment lands below 80 % across 20 real recordings, drop
   the process watcher and ship estimation-only.
2. **Right rail: pinned or collapsible.** Decide during M5 with real layout.
3. **Undo coalescing window** for continuous trim gestures.
4. **HDR captures.** v1 tone-maps to sRGB; may need to become a real pipeline
   decision.
5. **The name.** "Reel" is a placeholder throughout every document.

---

## Known gaps in the docs

Be honest about these rather than inventing answers:

- The five ADRs referenced above are **not written yet**. Write them as the
  corresponding decisions get implemented, one page each: context, decision,
  consequences, what would make us revisit.
- `docs/SCHEMA.md` is generated from `CoreModel` and does not exist until M0.
- Photo workspace editing operations (annotate, crop, redact) are specified only
  at the level of "which chips exist." The interaction model needs designing
  before M-photo, which is not currently in the milestone list.
- Caption editing UI is unspecified. `generateCaptions` produces segments; how a
  user corrects them is an open design question.

If you hit something the docs don't cover, say so and propose an option rather
than picking silently. A wrong guess buried in an implementation is much more
expensive than a question.
