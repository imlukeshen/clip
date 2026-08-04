# Reel — Phase T: Text Editor & LaTeX

Slots into [`ROADMAP.md`](./ROADMAP.md) as R7. Depends on B0 (`EditableDocument`)
and reuses Phase V's conversion graph and Phase S's index.

---

## 1. Scope

One editor serving four uses, which the design has to reconcile:

| Use | Implication |
|---|---|
| Author docs to export | Markdown and LaTeX with live preview; export via Phase V |
| Scratchpad alongside projects | Unsaved buffers that survive quit; zero-ceremony creation |
| View & share snippets | Fast paste, auto-detect language, copy as rich text or HTML |
| Edit library text files | Text files are first-class assets, indexed and searchable |

**LaTeX goes all the way to PDF**, Overleaf-style: split source/preview,
auto-compile, SyncTeX jump-to-source, parsed diagnostics, multi-file projects,
bibliography.

---

## 2. Document model

### 2.1 Text is not a patch graph

`ProjectDocument` and `ImageDocument` mutate through `GraphPatch` because their
operations are coarse. Text is not — routing every keystroke through a patch
produces enormous histories and terrible undo granularity.

**Split the two domains:**

- **Content edits** (typing, paste, find/replace) use `NSTextStorage` and its
  native `UndoManager` registration. This is what AppKit is good at; don't
  reimplement it.
- **Document-level operations** (add file, set main file, change language,
  rename) go through `TextPatch`, honouring invariant I4.

Both register with the **same** `UndoManager` instance for that editor, so they
interleave correctly in one undo stack. This is the only place the patch model is
deliberately not the sole mutation path, and the reason is recorded in
`docs/adr/0008-text-editing-uses-native-undo.md`.

```swift
public struct TextDocument: EditableDocument {
    public var schemaVersion: Int
    public var id: DocumentID
    public var files: [TextFile]           // >1 only for LaTeX projects
    public var mainFileID: FileID?         // LaTeX root; nil otherwise
    public var settings: EditorSettings    // wrap, tabWidth, fontSize, showInvisibles
}

public struct TextFile: Codable, Sendable, Identifiable {
    public var id: FileID
    public var assetID: AssetID?           // nil for scratch buffers
    public var relativePath: String
    public var language: LanguageID        // resolved or user-overridden
    public var languageIsExplicit: Bool    // true = user chose, don't re-detect
    public var encoding: String.Encoding
    public var lineEnding: LineEnding      // .lf | .crlf | .cr | .mixed
}

public enum TextPatch: DocumentPatch {
    case addFile(TextFile), removeFile(FileID)
    case setMainFile(FileID?)
    case setLanguage(FileID, LanguageID)
    case setSettings(EditorSettings)
    case renameFile(FileID, String)
}
```

### 2.2 Where text lives

| Kind | Location | Indexed |
|---|---|---|
| Library text file | `Media/<folder>/notes.md` — a normal asset, `kind = .text` | Yes |
| Scratch buffer | `.reel/scratch/<ulid>.txt`, autosaved every 2 s | Yes, as "Scratch" |
| LaTeX project | A folder under `Media/`, main file recorded in `.reel/tex/<folder>.json` | Yes |

A LaTeX project is **just a folder with a designated main file**. No project file
format, no import step. Point the editor at a folder containing `.tex` files and
it works.

---

## 3. Editor core

### 3.1 TextKit 2, not SwiftUI

SwiftUI's `TextEditor` supports no syntax highlighting, no line numbers, no
gutter, and no custom find bar. This is `NSTextView` with `NSTextLayoutManager`
and `NSTextContentStorage`, wrapped in `NSViewRepresentable`.

```swift
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: LanguageID
    let theme: EditorTheme          // derived from DesignSystem tokens
    let diagnostics: [Diagnostic]
    let onCursorChange: (TextPosition) -> Void
}
```

Components: `NSTextView` for content, a custom `NSRulerView` for line numbers and
diagnostic markers, `NSTextFinder` for find/replace.

### 3.2 Editing features

Shipped: line numbers, current-line highlight, soft wrap toggle, auto-indent,
bracket and quote auto-close, bracket matching, comment toggle (`⌘/`),
indent/outdent (`⌘]` `⌘[`), duplicate line (`⇧⌘D`), move line (`⌥↑` `⌥↓`),
find/replace with regex, go-to-line (`⌘L`), trailing-whitespace trim on save.

Deferred: multiple cursors, code folding, autocomplete. Each is substantial and
none is required by the four use cases.

### 3.3 Syntax highlighting

**Tree-sitter for a core set, regex fallback for the long tail.**

| Approach | Verdict |
|---|---|
| Tree-sitter | Incremental, correct, fast on large files. C dependency, one grammar per language. **Chosen.** |
| highlight.js via JavaScriptCore | 190 languages instantly, but regex-based and unusably slow past ~1 MB. |
| Hand-rolled regex | Fine as a fallback tier only. |

Bundled grammars (18): markdown, latex, swift, javascript, typescript, python,
json, yaml, toml, html, css, rust, go, c, cpp, java, sql, bash, xml. That covers
essentially everything people paste.

Anything else gets a generic regex highlighter — strings, numbers, comments,
keywords from a per-language word list. The dropdown can therefore list ~60
languages without lying about quality; the ones with real grammars show a subtle
indicator.

**Performance rules, both non-negotiable:**

1. **Parse off the main thread.** Tree-sitter parses on a background actor; the
   resulting tree is queried on the main thread for attribute application.
2. **Style only the visible range plus 200 lines of margin**, restyled on scroll.
   Applying attributes across a 10 MB buffer will hang the app regardless of how
   fast the parser is.

Incremental reparse on edit uses `ts_tree_edit` with the changed byte range — a
full reparse per keystroke is what makes naive Tree-sitter integrations feel
sluggish.

### 3.4 Language detection

In order, stopping at the first hit: explicit user override (`languageIsExplicit`)
→ file extension → shebang line → content heuristics (`\documentclass` → LaTeX,
`<?xml` → XML, leading `{`/`[` that parses as JSON) → plain text.

The dropdown sets `languageIsExplicit = true` and persists per file.

---

## 4. Markdown

Split view, source left, rendered right, scroll-synced by nearest block.

- **GitHub Flavored Markdown**: tables, task lists, fenced code with
  highlighting, footnotes, strikethrough, autolinks.
- Rendering is `WKWebView` with **all network loads blocked** and HTML sanitized.
  A markdown file must never be able to fetch a remote resource or execute script.
- Local images resolve relative to the file, through a scoped `WKURLSchemeHandler`
  restricted to the file's directory. No arbitrary filesystem reads.
- Math via KaTeX (bundled, offline) for `$…$` and `$$…$$`.
- Export reuses **Phase V's graph**: `md → html`, `md → pdf`, `md → docx` where
  available. The editor doesn't implement export; it calls `convert.run`.

---

## 5. LaTeX

### 5.1 Engine abstraction

```swift
public protocol TeXEngine: Sendable {
    var id: EngineID { get }
    var displayName: String { get }
    var isAvailable: Bool { get }
    func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error>
}

public struct TeXJob: Sendable {
    public var mainFile: URL
    public var workingDirectory: URL       // scoped temp, see §5.3
    public var format: TeXFormat           // .pdflatex | .xelatex | .lualatex
    public var synctex: Bool
    public var bibliography: BibMode       // .auto | .biber | .bibtex | .none
    public var timeout: Duration           // default 120 s
}

public enum TeXEvent: Sendable {
    case pass(Int, of: Int)
    case logLine(String)
    case diagnostic(Diagnostic)
    case finished(pdf: URL, synctex: URL?)
}
```

Two implementations:

| Engine | Availability | Notes |
|---|---|---|
| `TectonicEngine` | **Bundled, both build channels** | ~40 MB static binary, MIT. Self-contained; resolves packages from a bundle. |
| `SystemTeXEngine` | Detected at `/Library/TeX/texbin/latexmk` | Direct build only — the App Store sandbox cannot spawn external binaries. Power-user path with a full local TeX Live. |

Tectonic is what makes this shippable. MacTeX is ~5 GB and unbundleable;
Tectonic is a single binary that runs in-sandbox given a writable working
directory, which we control.

### 5.2 Package resolution and the network question

Tectonic fetches packages lazily from a remote bundle and caches them. For a
privacy-positioned app that needs explicit handling:

- First compile requiring a fetch shows a one-time explanation and asks.
- Every fetch is recorded in the **egress ledger** with `purpose: "tex-package"`.
- Cache lives at `.reel/tex-cache/`, inspectable, clearable.
- **Offline alternative:** point Tectonic at a locally downloaded bundle file
  (`--bundle <path>`). Document how to get one; don't ship a 4 GB asset.
- If the user declines fetching and has no local bundle, LaTeX compilation is
  unavailable and says so plainly.

### 5.3 Compilation is sandboxed — security critical

**A `.tex` file is executable content.** Treat compilation as running untrusted
input.

1. **Shell escape disabled, always.** `\write18` lets a document run arbitrary
   commands. Tectonic disables it by default; `SystemTeXEngine` must pass
   `-no-shell-escape` explicitly and reject any job requesting otherwise.
2. **Filesystem confinement.** Set `openin_any=p` and `openout_any=p` so
   `\input{/etc/passwd}` and writes outside the working directory fail.
3. **Scoped working directory.** Copy project files into a temp directory under
   the app container, compile there, copy the PDF back. TeX litters `.aux`,
   `.log`, `.out`, `.toc`, `.bbl`, `.fls` — none of that belongs in the user's
   folder.
4. **Timeout and cancellation.** Default 120 s, hard-killed. A document can loop
   forever (`\loop\repeat`) or exhaust memory; both must be survivable.
5. **Output size cap.** Refuse to copy back a PDF above a configurable ceiling
   (default 500 MB).

### 5.4 SyncTeX

The feature that makes it feel like Overleaf rather than a compile button.

- Compile with `--synctex`; parse the gzipped `.synctex.gz`.
- **Forward search**: cursor at `main.tex:142` → scroll the PDF to that page and
  flash a highlight over the matching rectangle. Bound to `⌘⇧J`, and automatic
  after compile if the setting is on.
- **Inverse search**: `⌘`-click in the PDF → jump the editor to that source line,
  including the correct file in a multi-file project.
- When SyncTeX data is missing or stale, both actions degrade to "no mapping
  available" rather than jumping somewhere wrong.

### 5.5 Diagnostics

TeX logs are famously unstructured. Parse defensively:

- `! LaTeX Error: <msg>` and `! <TeX error>` blocks, with the following `l.NNN`
  giving the line.
- `LaTeX Warning:`, `Package <name> Warning:`.
- `Overfull \hbox (Npt too wide)` / `Underfull` with line references.
- Missing-file errors → offer the package name.
- Anything unparsed still appears in a raw log pane. **Never swallow output you
  couldn't parse.**

Diagnostics render in a bottom panel grouped by file, with severity, and in the
editor gutter. Clicking one jumps to the line. Errors from an included file
resolve to that file, not the main one.

### 5.6 Compile scheduling

- **Auto-compile**: debounce 1.5 s after typing stops, and only if content
  changed. In-flight compiles are cancelled when a new edit lands.
- **Manual**: `⌘B` always available.
- Setting: auto / on save / manual only.
- The previous successful PDF stays visible during a failed compile, with a
  "showing last successful build" banner. Blanking the preview on every syntax
  error is the most irritating possible behaviour.
- Auto-compile pauses on battery below 20 % and above `.fair` thermal state,
  matching the index pipeline's discipline.

### 5.7 Multi-file projects

- Resolve `\input`, `\include`, `\subfile`, `\bibliography`, `\addbibresource`
  to build a dependency graph.
- Editing any file in the graph compiles the **main file**, never the open one.
- Main file is inferred from `\documentclass` presence, overridable, persisted.
- The file tree shows project membership; files not reachable from main are
  marked.
- Bibliography: `.auto` inspects for `\bibliography` (bibtex) or
  `\addbibresource` (biber) and runs the right passes. Tectonic handles multi-pass
  internally; `SystemTeXEngine` uses `latexmk`, which also does.

---

## 6. Pastebin-style features

- Paste into an empty buffer → detect language → highlight, no save prompt.
- **Copy as rich text** — `NSAttributedString` → RTF on the pasteboard, so
  pasting into Mail, Notes, or Keynote keeps colours.
- **Copy as HTML** — standalone fragment with inline styles.
- **Export as HTML** — self-contained file, inline CSS, no external assets.
- **Copy with line numbers**, and copy a selection annotated `file.swift:12–28`.
- Wrap-in-code-fence for the current selection with the detected language tag.

There is no server, so no shareable link. Export produces a file; sharing is the
user's business.

---

## 7. Integration with existing phases

**Phase S (search).** Text assets index directly — no OCR, no sampling. Add a
`text` stage that reads content, chunks it, and embeds. Text files become the
highest-quality search targets in the library.

**Phase V (convert).** The editor adds edges rather than its own export:
`md → html`, `md → pdf`, `tex → pdf` (via `TeXEngine`), `html → md`. The
converter's `tex → pdf` and the editor's compile button share one backend.

**Phase E (commands).** New commands, therefore new agent tools automatically:
`text.create`, `text.setLanguage`, `text.format`, `tex.compile`,
`tex.diagnostics`, `text.export`.

This is where the AI-native architecture pays off — "fix the LaTeX errors in this
document" becomes `tex.compile` → `tex.diagnostics` → text edits, with no
editor-specific agent plumbing.

---

## 8. Edge cases

| Case | Handling |
|---|---|
| Paste 50 MB of text | Above 2 MB: read-only, visible-range highlighting only, banner. Above 20 MB: refuse, offer to open externally. |
| Single line of 200 000 chars (minified JS) | Disable soft wrap above 10 000 chars/line; TextKit layout degrades badly. Warn once. |
| Binary file opened as text | Detect null bytes in the first 8 KB → refuse with "this looks like a binary file". |
| Mixed line endings | Detect, show in the status bar, offer normalization. Never silently rewrite. |
| Non-UTF-8 encoding | Attempt UTF-8, then UTF-16, then the system default. Show the detected encoding; allow reopen-as. |
| File changed on disk while open | FSEvents detects; if the buffer is clean, reload silently. If dirty, prompt: keep mine / take theirs / show diff. |
| File deleted while open | Keep the buffer, mark it detached, offer Save As. |
| LaTeX infinite loop | Timeout kills it; diagnostics say so. |
| `\input{/etc/passwd}` | `openin_any=p` blocks it; the error surfaces normally. |
| `\write18{rm -rf ~}` | Shell escape disabled unconditionally. |
| SyncTeX missing after error | Forward/inverse search report "no mapping" instead of guessing. |
| Compile with no TeX available | LaTeX language still highlights; compile button explains what's missing. |
| Scratch buffer never saved, app quits | Autosaved every 2 s to `.reel/scratch/`; restored on launch. |
| Two editors on the same file | Second open focuses the first window rather than creating a divergent buffer. |
| Markdown with a remote image | Blocked; render a placeholder noting the block. |

---

## 9. Milestones

**T0 — Editor core.** TextKit 2 view, gutter, find/replace, editing commands,
`TextDocument`, `TextPatch`, scratch buffers with autosave.
*Accept:* open a 5 MB file, edit, undo 50 steps, save; no main-thread stall over
50 ms measured in Instruments.

**T1 — Highlighting.** Tree-sitter with 19 grammars, regex fallback, detection,
language dropdown, visible-range styling.
*Accept:* paste 2 MB of TypeScript — highlighting appears within 200 ms and
scrolling stays at 60 fps.

**T2 — Markdown.** Split preview, GFM, KaTeX, sanitized offline WebKit,
scroll sync, export via Phase V.
*Accept:* a README with tables, fenced code, and math renders correctly and
exports to PDF; a remote `<img>` is blocked.

**T3 — LaTeX compile.** `TeXEngine`, bundled Tectonic, sandboxed working
directory, all five §5.3 protections, PDF preview, auto-compile.
*Accept:* a document with `\documentclass{article}` and a package requiring
download compiles after consent; `\write18` is refused; an infinite loop times
out cleanly.

**T4 — SyncTeX and diagnostics.** Parsing, forward and inverse search, gutter
markers, diagnostics panel, raw log.
*Accept:* `⌘⇧J` from line 142 highlights the correct PDF region; `⌘`-click in the
PDF lands on the right line of the right included file.

**T5 — Multi-file and bibliography.** Dependency graph, main-file inference,
biber/bibtex.
*Accept:* a three-file project with a `.bib` compiles with correct citations from
any open file.

**T6 — Snippet features.** Copy as rich text and HTML, standalone HTML export,
line-annotated copy.
*Accept:* copy highlighted Swift into Mail and colours survive.

**T7 — Library and agent integration.** Text assets as first-class, `text` index
stage, the six commands.
*Accept:* searching for a phrase in a `.md` file returns it; "fix the LaTeX
errors" completes as compile → diagnostics → edits.

---

## 10. Open questions

1. **Tectonic bundle size vs offline-first.** Bundling the binary is settled;
   whether to also offer a downloadable full package bundle in-app, or just
   document it, is not.
2. **Does the markdown preview need scroll sync by block or by percentage?**
   Block is better and materially harder.
3. **Should scratch buffers appear in search by default?** They're often
   half-formed thoughts; indexing them may add noise.
4. **Grammar set.** Nineteen is a guess. Worth revisiting after real use — SQL and
   Java may not earn their place, while Dockerfile and Makefile might.
