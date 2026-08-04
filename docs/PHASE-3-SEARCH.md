# Clip — Phase S: Search & Indexing

> **Delivery status:** S0–S5 are complete and validated. S6 remains the roadmap's
> explicit evidence-gated experiment and is not required for R5 completion.

Slots into [`ROADMAP.md`](./ROADMAP.md) as R5. The indexing pipeline is backend
work independent of the shell; the search UI needs R3's shell to land first.

---

## 1. Three capabilities

| Capability | Source | Cost |
|---|---|---|
| **Text search** — find where words appear on screen | Vision OCR | Low, on-device, always on |
| **Spoken search** — find where words were said | Existing on-device transcripts | Free, already generated |
| **Semantic search** — find what something is *about* | Embeddings over OCR, transcript, summaries | Low; embedding is cheap |
| **Visual summaries** — what the frame depicts | Local VLM | High, opt-in, last |

Plus **Live Text**: selectable, copyable text over a paused video frame or a
photo, as in Apple Photos.

### 1.1 Scoping honesty

Screen recordings are text-dense. OCR captures menu labels, error messages, code,
URLs, table contents — verbatim, with positions. A vision model adds "a settings
page with a sidebar," which is weaker than what OCR already extracted.

**Ship tiers 0–2 first and measure whether tier 3 adds anything** before building
the VLM queue. My expectation is it earns its place for screenshots of diagrams
and for footage with little text, and not much else.

---

## 2. Indexing pipeline

### 2.1 Tiers

```
Tier 0  metadata        instant      always
Tier 1  OCR             ~1–4 s/asset always
Tier 2  embeddings      ~50 ms/chunk always
Tier 3  VLM summary     ~5–30 s      opt-in, requires local model
```

Runs after ingest, in the background, resumable across launches.

```swift
public actor IndexPipeline {
    public func enqueue(_ assetID: AssetID, stages: Set<IndexStage>) async
    public func resumePending() async          // on launch
    public func cancel(_ assetID: AssetID) async
    public func rebuild(scope: IndexScope) async
    public nonisolated var progress: AsyncStream<IndexProgress> { get }
}

public enum IndexStage: String, Sendable, CaseIterable {
    case metadata, ocr, transcript, embedding, summary
}
```

### 2.2 Scheduling

Indexing must never make the app feel slow.

- Runs at `TaskPriority.background` on a dedicated actor.
- **Pauses entirely** during playback, export, or conversion.
- Checks `ProcessInfo.processInfo.thermalState` — stops above `.fair`.
- Checks `isLowPowerModeEnabled` — defers tier 3 entirely.
- Progress appears in the sidebar footer, never as a modal.
- Every stage is a row in `index_job` with state and attempt count, so a crash
  resumes rather than restarts.

### 2.3 Frame sampling for video

You cannot OCR every frame — five minutes at 60 fps is 18 000 frames. Screen
recordings are mostly static, so sample intelligently:

1. Decode at **1 fps** via `AVAssetReader` with a stride (not
   `AVAssetImageGenerator`, which is slower for sequential access).
2. Downscale each sampled frame to 32×32 grayscale, compute a perceptual hash.
3. OCR a frame only when its Hamming distance from the last OCR'd frame exceeds a
   threshold (~8% of bits).
4. **Always OCR frames near click events.** The event track already marks where
   the screen changed — this is free signal you've already paid for.
5. Always OCR the first frame.
6. Cap at 12 OCR'd frames per minute of source.

A typical five-minute walkthrough yields 30–60 distinct screens rather than
18 000 frames.

### 2.4 Temporal deduplication

Text visible from 0:12 to 0:48 must be **one row with a time range**, not 36
rows. After OCR, collapse consecutive frames whose text blocks match (normalized,
case-folded, ≥90% Jaccard similarity on tokens) into a single span.

Without this the index bloats and search returns 36 hits for one thing.

### 2.5 OCR configuration

```swift
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true      // false for code-heavy content
request.minimumTextHeight = 0.008          // catch small UI labels
request.recognitionLanguages = Locale.preferredLanguages
request.revision = VNRecognizeTextRequestRevision3
```

Keep observations with `confidence > 0.3`; store the top candidate plus the
normalized bounding box. Language correction hurts on code and identifiers —
expose it as a per-folder setting for people recording terminals.

---

## 3. Storage

```sql
CREATE TABLE ocr_span (
  id             INTEGER PRIMARY KEY,
  asset_id       TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
  start_value    INTEGER,          -- NULL for images
  start_scale    INTEGER,
  end_value      INTEGER,
  end_scale      INTEGER,
  text           TEXT NOT NULL,
  bbox           TEXT NOT NULL,    -- JSON normalized rect
  confidence     REAL NOT NULL
);
CREATE INDEX idx_ocr_asset ON ocr_span(asset_id);

CREATE VIRTUAL TABLE ocr_fts USING fts5(
  text, content='ocr_span', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);

CREATE TABLE transcript_span (
  id INTEGER PRIMARY KEY, asset_id TEXT NOT NULL,
  start_value INTEGER, start_scale INTEGER,
  end_value INTEGER, end_scale INTEGER,
  text TEXT NOT NULL
);
CREATE VIRTUAL TABLE transcript_fts USING fts5(
  text, content='transcript_span', content_rowid='id');

CREATE TABLE asset_summary (
  asset_id    TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
  summary     TEXT NOT NULL,
  keywords    TEXT NOT NULL,        -- JSON array
  generator   TEXT NOT NULL,        -- "ollama/moondream:1.8b"
  generated_at REAL NOT NULL
);

CREATE TABLE embedding (
  asset_id    TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  kind        TEXT NOT NULL,        -- ocr | transcript | summary | filename
  start_value INTEGER, start_scale INTEGER,
  vector      BLOB NOT NULL,        -- float32 LE, L2-normalized at write
  dims        INTEGER NOT NULL,
  model       TEXT NOT NULL,
  PRIMARY KEY (asset_id, chunk_index, kind)
);

CREATE TABLE index_job (
  asset_id   TEXT NOT NULL,
  stage      TEXT NOT NULL,
  state      TEXT NOT NULL,         -- pending running done failed skipped
  attempts   INTEGER NOT NULL DEFAULT 0,
  error      TEXT,
  updated_at REAL NOT NULL,
  PRIMARY KEY (asset_id, stage)
);
```

### 3.1 No vector extension

For a personal library — say 20 000 chunks at 384 dimensions — that's about 30 MB
of float32. Brute-force cosine with `vDSP_dotpr` over normalized vectors runs in
single-digit milliseconds.

**Do not add `sqlite-vec` or any ANN index.** Load vectors into a contiguous
`[Float]` buffer at startup, keep it in memory, recompute on change. Revisit only
if a real library crosses ~200 000 chunks, which for this product it won't.

Normalize at write time so search is a dot product, not a cosine.

---

## 4. Search

### 4.1 Hybrid retrieval

Pure semantic search is worse than people expect — exact-match queries ("find
`NSFileManager`") fail badly. Run both and fuse.

```swift
public struct SearchQuery: Sendable {
    public var text: String
    public var filters: SearchFilters      // kind, dateRange, folder, duration, hasAudio
    public var mode: SearchMode            // .auto | .keyword | .semantic
    public var limit: Int
}

public struct SearchHit: Sendable, Identifiable {
    public var assetID: AssetID
    public var score: Double
    public var moments: [Moment]           // timestamps within a video
    public var snippet: AttributedString   // with match ranges marked
    public var sources: Set<HitSource>     // ocr | transcript | summary | filename
}

public actor SearchEngine {
    public func search(_ query: SearchQuery) async throws -> [SearchHit]
    public func searchWithin(_ assetID: AssetID, text: String) async throws -> [Moment]
    public func textAt(_ assetID: AssetID, time: RationalTime) async throws -> [OCRSpan]
}
```

Pipeline:

1. **Parse filters** out of the query string — `kind:video`, `after:2026-07-01`,
   `in:Demos`, quoted phrases. Whatever remains is free text.
2. **FTS5 BM25** over `ocr_fts`, `transcript_fts`, filename, and summary.
3. **Vector search** over `embedding` for the same free text.
4. **Reciprocal Rank Fusion**: `score = Σ 1 / (60 + rank_i)`. Weight OCR and
   transcript hits above summary hits — verbatim beats paraphrase.
5. **Group by asset**, keeping per-moment timestamps.

`.auto` mode runs both. Quoted phrases force keyword-only; that's the escape
hatch when semantic results get in the way.

### 4.2 Results are moments, not files

This is the feature that makes it feel different from Finder. A hit on a video
returns **timestamps**, and clicking one opens the editor with the playhead at
that moment, OCR overlay showing.

"Where did I show the billing table?" → the clip, at 1:23, with `Billing` already
highlighted on screen.

---

## 5. Live Text

Text selection over a paused frame or a photo.

- On pause, look up the nearest `ocr_span` set for that time (within 1 s).
- Render selectable regions as an overlay: hover shows an I-beam, drag selects
  across blocks in reading order, `⌘C` copies.
- `⌘⇧C` copies **all** text on the current frame.
- Right-click a selection → Copy, Search library, Redact this region.
- Detected data types get affordances: URLs open, emails compose, and anything
  matching a secret pattern shows a **Redact** action.

That last one connects to Phase B: OCR plus regex over emails, API keys, IPs, and
JWTs is exactly what `suggestRedactions` needs, and once OCR exists it's nearly
free.

---

## 6. Agentic search

Search is a command in the registry (`PHASE-2-EDITING.md` §2), so it's a tool
automatically.

| Command | Kind | Notes |
|---|---|---|
| `search.library` | read | Full query with filters |
| `search.withinAsset` | read | Moments inside one asset |
| `search.textAt` | read | OCR spans at a timestamp — powers copy |
| `search.similar` | read | Nearest neighbours to a given asset |

The agent's value is **decomposition**. "Find the clip where I showed the error
state and cut everything before it" becomes: `search.library(text: "error", kind:
.video)` → `search.withinAsset` for the exact moment → `clip.trim` at that
timestamp. Three tools, one sentence.

Give the search tool a description that says results include timestamps and that
quoted text forces exact matching — otherwise models default to vague semantic
queries and get vague results.

---

## 7. Local models

### 7.1 Embeddings

| Option | Setup | Quality | Recommendation |
|---|---|---|---|
| `NLContextualEmbedding` | None — built into macOS 14+ | Decent, multilingual | **Default** |
| Ollama `nomic-embed-text` | User installs Ollama | Better | Optional |
| Core ML MiniLM | ~90 MB bundled | Good | Only if the built-in disappoints |

**Store `model` on every embedding row.** Changing models invalidates the entire
vector index — detect the mismatch on launch, tell the user, and offer a
background reindex. Silently mixing embedding spaces produces search results that
are wrong in ways nobody can diagnose.

### 7.2 Vision summaries (tier 3)

Opt-in. Detect Ollama at `http://localhost:11434`; if absent, the feature is
simply unavailable — no download manager, no bundled weights.

Suggested models, smallest first: `moondream` (~1.8 GB), `llava:7b`,
`qwen2-vl:7b`. Let the user pick from what they have installed.

Input: 3–6 representative frames chosen by the same perceptual-hash spread used
for OCR sampling, plus the OCR text as context. Prompt for one sentence of
purpose and 5–8 keywords, returned as JSON.

Queue at the lowest priority. A 200-asset backlog at 15 s each is 50 minutes —
fine overnight, unacceptable if it blocks anything.

---

## 8. Privacy

**The index is more sensitive than the media.** OCR over screen recordings
extracts API keys, tokens, email addresses, customer names, and internal URLs
into plain, greppable text. Treat it accordingly:

- Store inside the library, never in `~/Library/Caches`.
- **Excluded from the diagnostics bundle**, absolutely, alongside keys and prompts.
- Per-folder **Exclude from index** toggle, and a global exclusion list.
- **Clear index** command that removes all OCR, transcript, embedding, and
  summary rows.
- Tiers 0–2 are entirely on-device. Tier 3 is on-device via Ollama. **No search
  feature ever sends content to a remote provider by default.** If someone points
  a cloud model at summaries, it logs to the egress ledger with
  `media_attached = 1`.
- Show what's indexed: an asset's inspector lists which stages ran and when.

---

## 9. Milestones

| Milestone | Status |
|---|---|
| S0 — Pipeline skeleton | Complete |
| S1 — OCR | Complete |
| S2 — Keyword search | Complete |
| S3 — Live Text | Complete |
| S4 — Semantic search | Complete |
| S5 — Agentic search | Complete |
| S6 — Vision summaries | Evidence-gated; deliberately deferred |

**S0 — Pipeline skeleton.** `IndexPipeline`, `index_job` table, scheduling,
resume-on-launch, sidebar progress.
*Accept:* enqueue 100 assets, quit mid-run, relaunch — indexing resumes from
where it stopped with no duplicated work. Indexing pauses during playback.

**S1 — OCR.** Frame sampling, click-event anchoring, Vision requests, temporal
dedup, FTS5.
*Accept:* a 5-minute screen recording produces fewer than 80 OCR spans, and
searching a word visible at 3:12 returns that timestamp. Images index in one pass.

**S2 — Keyword search.** Query parsing with filters, BM25 across OCR, transcript,
filename; results as moments; search bar in the shell.
*Accept:* `kind:video after:2026-07-01 "billing table"` returns the right clip at
the right timestamp in under 150 ms over 1 000 assets.

**S3 — Live Text.** Overlay, selection, copy, data-type actions, Redact hand-off.
*Accept:* pause a video, drag-select text on screen, `⌘C`, paste elsewhere —
matches what's visible.

**S4 — Semantic search.** `NLContextualEmbedding`, chunking, in-memory vector
buffer, RRF fusion, model-change detection.
*Accept:* "the part where I set up billing" finds a clip whose OCR contains
"Subscription" and "Payment method" but not the query words. Changing embedding
model prompts a reindex rather than corrupting results.

**S5 — Agentic search.** The four commands, tool descriptions, decomposition.
*Accept:* "find where I showed the error state and split there" completes as
search → search-within → split, undone by one `⌘Z`.

**S6 — Vision summaries.** Ollama detection, frame selection, queue, opt-in UI.
*Accept:* with Ollama running, 50 assets summarize in the background without the
UI dropping a frame; without Ollama, the feature is cleanly unavailable.

---

## 10. Open questions

1. **Does tier 3 justify itself?** Measure after S4 — compare search quality with
   and without summaries on a real library before building S6.
2. **Chunking strategy for embeddings.** Per OCR span is too granular; per asset
   loses timestamps. Probably per 30-second window, merging OCR and transcript.
   Test both at S4.
3. **Should indexing be opt-in on first run?** Silent background OCR of everything
   might unsettle exactly the users this app's positioning attracts. Leaning
   toward on-by-default with a visible first-run explanation, but it's a
   judgement call.
4. **Reindex triggers.** A new OCR revision in a macOS update improves results but
   reindexing a large library is expensive. Prompt, or silently reindex over time?
5. **Search scope default** — current folder or whole library? Finder defaults to
   folder and people find it maddening.
