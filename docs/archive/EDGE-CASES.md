# Reel — Edge Cases & Correctness Pass

Gaps found reviewing `PHASE-3-SEARCH.md` and `PHASE-4-CONVERT.md`, plus
cross-phase issues. **Each item here is a change to those documents, not a
suggestion.** Implementers should treat this as errata.

---

## 1. Phase S — Search

### 1.1 CJK and non-segmenting scripts — a real gap

`PHASE-3-SEARCH.md` §3 specifies `tokenize='unicode61 remove_diacritics 2'`.
**Unicode61 splits on whitespace and punctuation, so Chinese, Japanese, and Thai
index as one enormous token per sentence and become unsearchable.**

Fix: a second FTS table using the `trigram` tokenizer for CJK content, selected
by script detection at index time.

```sql
CREATE VIRTUAL TABLE ocr_fts_cjk USING fts5(
  text, content='ocr_span', content_rowid='id',
  tokenize='trigram'
);
```

At index time, detect the dominant script per span (`CFStringTokenizer` or Unicode
block ranges). Insert into `ocr_fts`, `ocr_fts_cjk`, or both for mixed content.
At query time, detect script in the query and search the corresponding table.
Trigram requires queries of at least 3 characters — fall back to `LIKE` below
that.

Same applies to `transcript_fts`.

### 1.2 FTS5 query injection

User input goes straight into `MATCH`. Characters `" * ( ) : - ^` are FTS5 syntax
and unescaped input either throws `SQLITE_ERROR` or silently means something else.
Searching `C++` currently errors.

Fix: escape by wrapping each user token in double quotes with internal quotes
doubled, and only honour operators the parser extracted deliberately (§4.1
filters). Never pass raw user text to `MATCH`.

```swift
func ftsQuote(_ token: String) -> String {
    "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
```

### 1.3 Index lifecycle gaps

| Case | Fix |
|---|---|
| Asset deleted | `ON DELETE CASCADE` on `ocr_span`, `transcript_span`, `asset_summary`, `embedding`. **`embedding` and `transcript_span` are missing it in §3 — add.** FTS5 external-content tables need explicit `DELETE` triggers; add `ocr_fts_delete` and equivalents. |
| Asset moved | Keyed by `asset_id`, unaffected. Correct as written. |
| Asset replaced (same path, new content) | Content hash differs → new `AssetID` → old index cascades away. Correct. |
| Indexing failed 3 times | Cap `attempts` at 3, set `state = 'failed'`, stop retrying. §2.1 has the column but no cap — add. |
| OCR produced nothing | `state = 'skipped'`, not `'failed'`. A photo of a landscape legitimately has no text; retrying it forever is wrong. |
| Embedding model changed | Queries filter `WHERE model = <current>`. Partial reindex means mixed models coexist safely — results just improve as it progresses. Do **not** delete old vectors until the reindex completes. |
| Vision OCR revision changed (OS update) | Record `revision` on `ocr_span`. On mismatch, mark stale and reindex in the background at lowest priority. Don't block search. |
| Search runs while indexing | Return results with an `isComplete: false` flag; the UI shows "still indexing". Never silently return partial results as if complete. |

### 1.4 Scale and resource limits

- **Long videos.** §2.3 caps at 12 OCR frames per minute, which for a 2-hour
  recording is 1 440 frames. Add an absolute cap of **400 frames per asset**,
  distributed by hash-distance ranking rather than truncating at the end.
- **Query length.** Cap at 512 characters; longer input is almost always a
  mis-paste.
- **Empty query.** Return recent assets, not an error and not everything.
- **Vector buffer memory.** §3.1 assumes it stays in memory. Add a ceiling — above
  200 000 chunks, page from disk in blocks. Log a warning when crossed so it's
  visible before it's a problem.
- **Duplicate assets.** Same content hash means one `AssetID` already, so one
  index. Correct as written.

### 1.5 Missing media

An asset marked `missing` (`PHASE-2.md` §2.4) keeps its index rows. Search still
returns it, marked unavailable, and clicking offers Locate. Deleting the index for
missing assets would mean losing search over an archive on an unplugged drive —
exactly when you most need it.

---

## 2. Phase V — Conversion

### 2.1 Same-path and same-format — currently unhandled

| Case | Fix |
|---|---|
| Output path equals input path | **Refuse at plan time.** `ConversionPlan` gains `validate(input:output:) throws`. Never write in place, even via temp-and-replace — an interrupted conversion would destroy the original, violating I5. |
| Input format equals output format | Offer explicitly: *Copy* (no processing) or *Re-encode* (apply options like resize or metadata strip). Don't silently no-op. |
| Two inputs resolve to the same output name in a batch | Conflict policy applies **within** the batch, not just against existing files. Auto-suffix `-1`, `-2`. Detect before starting, not on collision. |

### 2.2 Lossy transitions needing explicit warnings

The `warnings` field exists in §2.2 but the content isn't specified. Minimum set:

| Transition | Warning |
|---|---|
| Alpha → no alpha (png → jpeg) | "Transparency will be flattened" + background colour option |
| HDR → SDR | "HDR will be tone-mapped to SDR" |
| Wide gamut → sRGB | "Colours outside sRGB will be clipped" |
| Multi-page → single-image | "Only page 1 will be converted" or produce N files |
| Animated → static | "Only the first frame will be used" |
| Lossy → lossy (jpeg → webp) | "Re-encoding a lossy source compounds artefacts" |
| Any → GIF | "Reduced to 256 colours" |
| Video with chapters/subtitles → format lacking them | "Chapters and subtitle tracks will be dropped" |

### 2.3 Structural cases

- **Multi-page PDF → image.** Produces N files. The naming template needs a
  `{page}` token, and the plan must declare it emits multiple outputs.
  `ConversionPlan` currently assumes one output — **add `outputCount`**.
- **Multiple images → PDF.** Ordering is the batch order, shown and reorderable
  before running.
- **Animated GIF → video.** Frame timing is per-frame in GIF and must be
  preserved, not averaged.
- **Video → GIF.** Two passes: palette generation then application. A single-pass
  GIF looks terrible and this is the most common conversion people judge a tool by.
- **Rotation metadata.** `preferredTransform` must be applied, not dropped.
  Dropping it produces sideways output and is a classic converter bug.
- **Camera raw as a target.** Raw is decode-only. `reachableTargets` must never
  offer it. §1.1 says read-only; make it an assertion in the edge declaration.

### 2.4 Failure and resource cases

| Case | Fix |
|---|---|
| Disk full mid-conversion | Detect `ENOSPC`, delete the partial temp file, report bytes needed. |
| Corrupt or zero-duration input | Fail at probe with a specific error, before queueing. |
| File over 4 GB → mp4 | Requires 64-bit atoms; enable unconditionally for mp4 output. |
| DRM-protected input | Detect and refuse with a clear message. Do not attempt. |
| Cancellation mid-batch | Kill in-flight, delete partial outputs, keep completed ones. Report what completed. |
| Network volume goes away mid-batch | Fail that item, continue the batch. |
| Symlink or alias input | Resolve; refuse if it resolves outside the library or a user-granted scope. |
| Concurrency × in-process FFmpeg memory | Cap total decoder memory, not just task count. Four concurrent 4K decodes will exhaust memory on an 8 GB machine. Scale concurrency by `physicalMemory`. |
| LibreOffice uninstalled between plan and run | Re-check `isAvailable` at run time, not only at plan time. Fail with "LibreOffice is no longer available". |
| Unicode / very long filenames | Normalize to NFC; cap the generated component at 200 bytes, preserving the extension. |

### 2.5 Planner correctness

- **Cycle safety.** Dijkstra handles cycles, but a badly declared edge set could
  produce a zero-cost cycle. Assert every edge has cost > 0 at registry build
  time, in a test.
- **Ties.** Two equal-cost paths must resolve deterministically — sort by backend
  ID — or the same conversion takes different routes on different runs and bugs
  become unreproducible.
- **`isAvailable` and the graph.** Unavailable backends' edges must be excluded
  at graph construction, not filtered afterwards, or the planner will find paths
  it cannot execute.

---

## 3. Cross-phase

### 3.1 Undo across document types

Three document types now exist: `ProjectDocument`, `ImageDocument`,
`TextDocument`. Each editor owns its own `UndoManager`. `⌘Z` must apply to the
**focused editor**, never a global stack. Closing an editor discards its stack;
warn if unsaved.

### 3.2 Command ID collisions

The registry is keyed by `CommandID` string. Two commands with the same ID is a
silent override. Add a build-time test asserting uniqueness.

### 3.3 Migration ordering — restated

Three migrations now exist: A0 (library layout on disk), E4 (multi-track schema),
and B0/T0 (new document types). **No release may contain more than one.** Document
types are additive and therefore safe alongside one other migration; A0 and E4
must never share a release.

### 3.4 Agent destructive-action boundary

Still open in `PHASE-2-EDITING.md` §5.3, and it now matters more: the agent can
reach `convert.run` (writes files), `asset.delete` (trashes), and `tex.compile`
(spawns a process). Recommendation, to be confirmed:

- Document edits: auto-apply under `confirmDestructive`
- File writes (`convert.run`, `text.export`): confirm
- File deletion (`asset.delete`, `trashFolder`): **always confirm, never
  auto-apply, regardless of policy**
- Process spawning (`tex.compile`): auto-apply — it's sandboxed and produces no
  user-visible side effects outside the temp directory

### 3.5 Egress ledger completeness

Three new network paths exist that must log: Tectonic package fetches
(`purpose: "tex-package"`), Ollama calls if the host is not localhost, and any
cloud VLM summary. **Localhost Ollama should still be logged**, marked as local,
so the ledger is a complete record rather than a partial one.

---

## 4. Additions to existing documents

| Document | Change |
|---|---|
| `PHASE-3-SEARCH.md` §3 | Add `ocr_fts_cjk` and `transcript_fts_cjk`; add `ON DELETE CASCADE` to `embedding` and `transcript_span`; add FTS delete triggers; add `revision` to `ocr_span` |
| `PHASE-3-SEARCH.md` §2.3 | Add absolute 400-frame cap per asset |
| `PHASE-3-SEARCH.md` §4.1 | Add FTS5 escaping; add `isComplete` to results |
| `PHASE-4-CONVERT.md` §2.2 | Add `outputCount` and `validate(input:output:)` to `ConversionPlan` |
| `PHASE-4-CONVERT.md` §2.3 | Add deterministic tie-breaking; exclude unavailable backends at graph construction |
| `PHASE-4-CONVERT.md` §4.1 | Add the warning table from §2.2 above |
| `PHASE-2-EDITING.md` §5.3 | Resolve with §3.4 above |
