# Reel — Phase V: Universal Conversion

Replaces `DESIGN.md` §8 (`ConvertKit`). Slots into [`ROADMAP.md`](./ROADMAP.md)
as R6.

---

## 1. What "all in one" can actually mean

### 1.1 Realistic coverage

| Category | Coverage | Backend |
|---|---|---|
| **Video containers** | mp4, mov, mkv, webm, avi, flv, wmv, ts, mpg, ogv, m4v, gif | FFmpeg + AVFoundation |
| **Video codecs** | H.264, HEVC, ProRes, VP8, VP9, AV1, MJPEG, FFV1, DNxHD, Theora | VideoToolbox (H.264/HEVC), FFmpeg (rest) |
| **Audio** | mp3, aac, m4a, wav, flac, opus, ogg, aiff, wma, caf | FFmpeg + AVFoundation |
| **Raster images** | png, jpeg, heic, heif, tiff, gif, bmp, ico, webp, avif | ImageIO + FFmpeg |
| **Camera raw** | CR2, CR3, NEF, ARW, DNG, RAF, ORF — **read only** | ImageIO |
| **PDF** | ↔ images, → text, merge, split, page range | PDFKit |
| **Rich text** | docx, doc, rtf, rtfd, html, txt, webarchive | NSAttributedString |
| **Markdown** | md ↔ html ↔ pdf | Built-in + WebKit |

That is a genuinely broad converter — and everything above needs no dependency
beyond the FFmpeg you already vendor.

### 1.2 The three walls

**Office formats can be read but not written.** `NSAttributedString` on macOS
reads `.docx`, `.doc`, `.rtf`, `.html`, and `.webarchive` natively — so
`docx → pdf/html/rtf/txt/md` works with zero dependencies. It cannot *write*
`.docx`. Real Office output needs LibreOffice: roughly 800 MB, cannot run inside
the App Store sandbox, and would dwarf the app. §7 has the optional path.

**Spreadsheets and presentations have no viable path at all.** `xlsx` and `pptx`
need either LibreOffice or a full OOXML implementation. **Do not promise these.**
An "all in one" converter that silently omits Excel is better than one that
mangles it.

**Vector output isn't conversion.** `png → svg` is image tracing, a different
problem with different quality expectations. Out of scope. Reading SVG to
rasterize is fine and cheap via WebKit.

Everything else on a normal person's list is achievable.

---

## 2. From table to graph

### 2.1 Why the table fails

The current decision table is four hardcoded rows. It can't express:

- `docx → pdf` (two hops: NSAttributedString → HTML → WebKit → PDF)
- `heic → webp` (ImageIO decodes, FFmpeg encodes)
- `raw → jpeg` (ImageIO only, but only in one direction)
- Any new format without editing the table and every UI that reads it

### 2.2 The graph

```swift
public struct FormatID: Hashable, Sendable {
    public var type: UTType
    public var codec: String?          // nil for image/document formats
}

public struct ConversionEdge: Sendable {
    public var from: FormatMatcher     // a set, or a predicate over FormatID
    public var to: FormatID
    public var backend: BackendID
    public var cost: Cost              // .passthrough | .cheap | .hardware | .expensive
    public var isLossless: Bool
    public var warnings: [String]      // "alpha channel will be flattened"
    public var supportedOptions: OptionSet
}

public protocol ConversionBackend: Sendable {
    var id: BackendID { get }
    var isAvailable: Bool { get }              // e.g. LibreOffice detection
    func edges() -> [ConversionEdge]
    func run(_ step: PlannedStep) -> AsyncThrowingStream<Double, Error>
}
```

### 2.3 Planner

```swift
public struct ConversionPlanner: Sendable {
    public func plan(from: FormatID, to: FormatID, options: ConversionOptions)
        -> ConversionPlan?
    public func reachableTargets(from: FormatID) -> [FormatID]   // drives the UI
}

public struct ConversionPlan: Sendable {
    public var steps: [PlannedStep]        // 1–3
    public var estimate: Estimate
    public var isLossless: Bool            // only if every step is
    public var warnings: [String]          // union, deduplicated
}
```

Dijkstra over edges. Cost function:

```
cost(path) = Σ step.cost.weight + (hops − 1) × 40 + (lossyHops × 60)
```

Hop and lossy penalties matter: `mov → mp4` must never route through a
re-encode when passthrough exists. Cap at **3 hops**; beyond that, quality loss
compounds unpredictably and the plan becomes hard to explain.

`reachableTargets` is what makes the UI honest — the format dropdown shows what's
actually possible for *this* input, computed, rather than a static list with
half the entries greyed out.

---

## 3. Backends

| Backend | Handles | Notes |
|---|---|---|
| `PassthroughBackend` | Container swaps at identical codec | `AVAssetExportPresetPassthrough`. Lossless, seconds. |
| `VideoToolboxBackend` | H.264, HEVC, ProRes encode | Hardware. |
| `ImageIOBackend` | png, jpeg, heic, tiff, gif, bmp, ico; raw decode | `CGImageDestination`. |
| `PDFKitBackend` | pdf ↔ image, image → pdf, merge, split, page range | |
| `AttributedStringBackend` | docx/doc/rtf/html/txt read; rtf/html/txt write | Zero dependencies. |
| `WebKitBackend` | html → pdf, svg → raster | `WKWebView.createPDF`. Offline only — block all network loads. |
| `MarkdownBackend` | md ↔ html | |
| `FFmpegBackend` | Everything else audio/video, webp/avif encode | LGPL build. |
| `LibreOfficeBackend` | Office writing | **Optional**, detected, direct build only. §7. |

Each backend declares its edges; nothing is centrally listed. Adding webp support
means adding an edge, not editing a table and three UI files.

`WebKitBackend` must run with a content policy that blocks every network request.
Converting an HTML file should never fetch a remote resource.

---

## 4. Options

### 4.1 Per category

**Video** — resolution, frame rate, codec, quality (CRF-like scale or bitrate),
audio codec and bitrate, trim range, mute, strip metadata, two-pass.

**Image** — quality, resize (longest side, exact, percentage), background colour
for alpha flattening, strip EXIF/GPS, colour profile.

**Document** — page range, rasterization DPI, page size, margins, embed fonts.

**Global** — strip all metadata, output naming template, conflict policy
(rename / overwrite / skip).

`strip metadata` deserves prominence given the app's positioning. GPS coordinates
in screenshots and camera raw are a real leak, and this is the natural place to
offer removal.

### 4.2 Presets

Named bundles of target plus options. Ship a small set and let users save their
own:

- **Web-ready MP4** — H.264, 1080p, capped bitrate, faststart
- **Slack GIF** — 480p, 15 fps, palette-optimized, under 8 MB
- **Email PDF** — 150 DPI rasterization, metadata stripped
- **Archive ProRes** — ProRes 422, no re-encode of audio
- **Lossless shrink** — same codec, container swap only

Presets are `Command`s in the registry (`PHASE-2-EDITING.md` §2), so the agent
gets them for free.

---

## 5. Batch UX

The Convert workspace takes mixed input and stays legible:

- Drop 40 files of six types. Rows group by input category with a header per
  group.
- **Set target per group or per file.** Bulk-set is the common case.
- Each row shows its resolved plan: `docx → html → pdf · 2 steps · WebKit`.
  Multi-hop must be visible, not hidden.
- Warnings render inline: *alpha will be flattened*, *metadata will be stripped*.
- Output destination uses `ExportDestination` from `PHASE-2.md` §2.5 — same
  templates, same picker.
- Concurrency defaults to `min(4, activeProcessorCount / 2)`, user-adjustable.
- **A failure never stops the batch.** Failed rows stay with their error and a
  Retry action.
- Per-file and aggregate progress; cancel individually or all.
- On completion: reveal, copy paths, or nothing, per preference.

Unreachable pairings simply don't appear in the dropdown, because
`reachableTargets` computes it. No greyed-out entries with no explanation.

---

## 6. Agent integration

Commands in the registry:

| Command | Kind | Notes |
|---|---|---|
| `convert.listTargets` | read | Reachable formats for an input |
| `convert.plan` | read | Steps, cost, lossless, warnings — no side effects |
| `convert.run` | confirm | Executes; writes files, so always confirms |
| `convert.presets` | read | Available presets |

`convert.plan` being separate and side-effect-free matters: the agent can answer
"can you turn these into GIFs, and will quality suffer?" without converting
anything. Its result includes `isLossless` and `warnings`, so the agent can
report the tradeoff instead of discovering it afterward.

---

## 7. LibreOffice — the optional path

For people who genuinely need `→ docx`, `→ xlsx`, `→ pptx`:

- Detect at `/Applications/LibreOffice.app/Contents/MacOS/soffice`.
- **Direct-download build only.** The sandboxed App Store build cannot spawn an
  external app, so `LibreOfficeBackend.isAvailable` is `false` there and its
  edges never enter the graph.
- Never bundle, never prompt to download, never auto-install.
- Surface it as: *"Install LibreOffice to enable Office format output."*

This is the only place the two build channels diverge in capability. Document it
in the App Store listing rather than letting people discover it.

---

## 8. Milestones

**V0 — Graph and planner.** `FormatID`, `ConversionEdge`, `ConversionBackend`,
Dijkstra planner, `reachableTargets`. Existing backends re-expressed as edges.
*Accept:* `plan(mov, mp4/h264)` returns a single passthrough step; `plan(docx,
pdf)` returns two steps; every v1 conversion still produces byte-identical output.

**V1 — Image and document backends.** ImageIO extended, PDFKit,
NSAttributedString, WebKit, Markdown.
*Accept:* `docx → pdf`, `md → pdf`, `pdf → png`, `heic → webp`, and
`raw → jpeg` all succeed with correct content.

**V2 — Options and presets.** Per-category options, the five shipped presets,
metadata stripping.
*Accept:* Slack GIF preset produces a file under 8 MB from a 30-second 1080p60
source; strip-metadata output has no EXIF or GPS.

**V3 — Batch UX.** Grouping, per-group targets, plan display, concurrency,
partial failure, destination integration.
*Accept:* 40 mixed files convert with two deliberate failures; the batch
completes, failures are actionable, successes land in the templated destination.

**V4 — Agent commands.** The four commands with descriptions.
*Accept:* "convert these four screenshots to web-optimized JPEGs under 500 KB"
plans, reports the tradeoff, confirms, and executes.

**V5 — LibreOffice.** Detection, edges, channel gating.
*Accept:* with LibreOffice installed on the direct build, `pdf → docx` appears
and works; on the App Store build it never appears.

---

## 9. Open questions

1. **AVIF and WebP encode paths.** ImageIO's write support varies by macOS
   version. Probe capability at runtime rather than gating on version numbers,
   and fall back to FFmpeg. Verify during V1.
2. **Quality scale.** Codecs express quality incompatibly (CRF, bitrate, quality
   0–1). A single normalized 0–100 slider mapped per codec is friendlier but
   lossy in meaning. Probably worth it, with an advanced field underneath.
3. **Do we convert audio-only files at all?** It's nearly free given FFmpeg, but
   it widens the product's identity beyond screen demos.
4. **Preset sharing.** Presets are JSON; exporting and importing them is trivial
   and useful for teams. Not scoped.
5. **Should `convert.run` ever be auto-approved?** It writes files but never
   destroys them. Possibly auto-approve when the destination is empty and the
   input is untouched.
