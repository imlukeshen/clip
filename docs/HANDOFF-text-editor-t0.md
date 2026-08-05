# Handoff — Phase T (Text Editor) T0 + two UI fixes

> **Completion update (2026-08-03):** The Xcode continuation is complete. The
> missing TextKit 2 workspace, line-number gutter, inspector, navigation and
> undo routing, editing commands, scratch-buffer create/restore flow, ADRs, and
> automated regressions described below are now implemented on this branch.
> This document remains as the checkpoint history that defined the pickup work.

**Branch:** `feat/text-editor-t0`
**Written:** 2026-08-03
**Machine constraint that produced this handoff:** this Mac has **CommandLineTools only, no
Xcode.app**. `xcodebuild` refuses to run, so the **app target (`App/Reel`) has never been
compiled or launched with the current changes**. Pure Swift packages build/test via
`bash scripts/swift-test-clt.sh <package>`. Continue on a machine with full Xcode.

> ⚠️ **The app target does NOT compile right now.** `MainWindow.swift:201` references
> `TextView(model:)`, but `App/Reel/Sources/Reel/Workspaces/Text/` was never created. This is a
> **work-in-progress checkpoint commit**, not a green build. First job on the Xcode machine is to
> create the missing views (below) so it compiles.

Plan of record: `/Users/luke.shen/.claude/plans/virtual-leaping-tiger.md` (milestones T0–T7).

---

## First thing to do on the Xcode machine

```bash
make generate          # regenerate Clip.xcodeproj (gitignored)
make run               # xcodebuild + launch — WILL FAIL until the views below exist
```

Expect a compile error at `MainWindow.swift:201` (`cannot find 'TextView' in scope`). Fix by
creating the missing views, then `make lint && make test`.

---

## What is DONE (committed on this branch)

### CoreModel (compiles + tested via CLT)
- `Document/TextDocument.swift` — `TextDocument: EditableDocument` + `TextPatch: DocumentPatch`
  (six cases: addFile/removeFile/setMainFile/setLanguage/setSettings/renameFile), each returns its
  inverse; `TextFile`, `EditorSettings`, `LanguageID`, `LineEnding`, `TextDocumentError`.
- `Tests/CoreModelTests/TextPatchInverseTests.swift` — I3 inverse round-trip property tests.

### TextEngine (new package — compiles + tested via CLT)
- `LanguageDetector.swift` — `detect(path:contents:)`; `recognizedExtensions: Set<String>` is the
  **single source of truth** for text extensions, shared by ingest / probe / routing.
- `TextFileLoader.swift` — `LoadedTextFile {text, encoding, lineEnding}`, `load(from:)`, 50 MB cap.
- `TextEngineError.swift` — `Sendable & Equatable`.
- Tests: `LanguageDetectorTests`, `TextFileLoaderTests`.
- **Skeleton only** — no Tree-sitter/Tectonic vendoring yet (that's T1/T3).

### LibraryStore
- `AssetKind.swift` — added `.text`.
- `LibraryLayout.swift` — `.reel/text` (overlays) + `.reel/scratch` dirs.
- `LibraryStore.swift` — `saveTextContents(...)`: the **one sanctioned writable path into `Media/`**
  (I5 exception for text assets — imported 644 not 444, saved in place, contentHash recomputed).
- `Tests/LibraryStoreTests/TextAssetWritableTests.swift`.

### ReelAppCore
- `Text/TextEditorViewModel.swift` — `@MainActor @Observable`. Splits content (NSTextView native
  UndoManager, I4 exception) from structure (`TextPatch`); both share one `UndoManager`. Content
  autosaves in place every 2 s; structure persists to `.reeltext`.
- `AppRuntime.swift` — `textDocument(for:)`, `saveTextDocument(_:for:)`, `loadTextContents(for:)`,
  `saveTextContents(_:for:contentHash:)`, private `textDocumentURL(for:)` (`.reel/text/<id>.reeltext`).
- `AppModel.swift` — `textEditor` property, `openTextEditor(for:)`, `closeTextEditor()` (+ in
  `closeOpenEditors()`), `.text` in `assetCount`, `activateAsset` route, `showsEditorInspector`,
  all editor-nil guards extended.
- `Ingest/AVFoundationMediaProbe.swift` — `probeText(...)` for recognized extensions; maps
  `TextEngineError` → `IngestError`.
- `Ingest/IngestPipeline.swift`, `AVFoundationDerivativeGenerator.swift`,
  `Ingest/SampledFileHasher.swift` (added `Data` overload), `Conversion/ConversionQueueItem.swift`,
  `Shell/Workspace.swift` (`.text` case), `Shell/WorkspaceRouter.swift`,
  `Commands/AppCommandRouter.swift` (`navigation.text` in menuCommandIDs/availability/run;
  `asset.search` guard extended), `Library/BrowserState.swift`.

### AIKit
- `CommandRegistry.swift` — `navigation.text` command registered.

### App views (partial — see gaps)
- `Shell/MainWindow.swift` — full-bleed predicate + `case .text: TextView(model: model)` ← **needs
  the view to exist.**
- `Shell/Titlebar.swift`, `Shell/LibrarySidebar.swift` (Text smart row),
  `Shell/WorkspaceDropZone.swift` (title/detail/allowedContentTypes), `Workspaces/AssetGrid.swift`
  (`.text` icon), `Workspaces/AssetInfoPopover.swift`, `Workspaces/Convert/ConvertView.swift`.

### Unrelated UI fix bundled in (asked for this session)
- `Workspaces/AssetGrid.swift` — **drag-preview overlap fix**. `LazyVGrid` auto-generated the drag
  image from the full `AssetCard` at unclamped size, so it sprawled over neighbors. Added a
  `.draggable { dragPreview(for:) }` closure returning a fixed 44pt chip (thumbnail + name, or
  "N items" for multi-select). Lint-clean; **not compile-verified.** Verify visually after build.

---

## What is NOT done (pick up here, in order)

### 1. Create the missing Text workspace views (UNBLOCKS COMPILE)
`App/Reel/Sources/Reel/Workspaces/Text/` — does not exist. Clone the PDF workspace as template
(`Workspaces/PDF/PDFView.swift` is the exact pattern):
- **`TextView.swift`** — workspace root: `if let editor = model.textEditor { <editor> } else { <library drop/grid> }`.
- **`CodeEditor.swift`** — `NSViewRepresentable` over `NSTextView` + `NSTextLayoutManager` +
  `NSTextContentStorage`, custom `NSRulerView` gutter, `NSTextFinder`. Binds to
  `editor.text`; uses `editor.undoManager`.
- **`TextInspector.swift`** — the `.text` inspector panel.

### 2. Wire remaining app surfaces
- `ReelApp.swift` — add `navigation.text` menu Button between the `navigation.pdf` and
  `navigation.convert` buttons (~line 57–60), matching the existing pattern:
  ```swift
  Button(commandTitle("navigation.text")) { AppCommandRouter.run("navigation.text", in: model) }
  ```
- `Shell/UnifiedInspector.swift` — add a `.text` branch (currently falls to `EmptyView()`;
  the `.text` matches in the grep above are the **image-layer** TextLayer, a different type — do
  not confuse them).

### 3. Docs (task #10)
- Write `docs/adr/0008-text-editing-uses-native-undo.md` (I4 exception rationale).
- Write `docs/adr/0009-text-assets-are-writable.md` (I5 exception rationale).
- Patch `docs/PHASE-5-EDITOR.md:44` ADR ref `0007-` → `0008-`.

### 4. Verify
- `make lint && make test` (packages + app).
- `bash scripts/swift-test-clt.sh Packages/CoreModel` etc. for fast package loops.
- Manually: open a 5 MB text file, edit, undo ~50 steps, save; confirm no main-thread stall
  (T0 acceptance criterion).
- Confirm the **AssetGrid drag-preview fix** renders correctly (drag a selected card — the drag
  image should be a small chip, not an oversized overlapping card).

---

## Environment notes for whoever continues
- `xcodes` CLI was installed here via Homebrew (`brew install xcodes`) to attempt an Xcode install;
  the install itself was never run (needs interactive Apple ID). Safe to `brew uninstall xcodes` if
  unwanted — it is just the installer helper, not Xcode.
- No Xcode.app was ever installed on this machine.
- `swift build` of the app target fails only on `#Preview` macros (`PreviewsMacros plugin not
  found`) — that is an Xcode-only macro, **not** a real code error. Real source compiles.
