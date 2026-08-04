# Reel — Roadmap

Three documents define milestones: `DESIGN.md` §14 (v1, shipped), `PHASE-2.md`
(A/B/C), and `PHASE-2-EDITING.md` (E0–E6). **This file is the merged ordering.**
Where it conflicts with those, this wins.

---

## Sequence

| Release | Milestones | Ships | Depends on |
|---|---|---|---|
| **R1** | E0, E1 | Tab fix, delete to Trash, marquee selection, ⌘A | — |
| **R2** | E2, E3 | Command registry; agent reaches every command | — |
| **R3** | A0–A5 | Human filenames, folders, sidebar shell, export destinations | E2 |
| **R4** | B1–B4 | Photo editing that works | B0 |
| **R5** | S0–S5 | OCR, Live Text, keyword + semantic search, agentic search | R3 |
| **R6** | V0–V5 | Universal conversion — capability graph, documents, batch | R3 |
| **R7** | T0–T7 | Text editor, markdown, LaTeX with PDF compilation | B0, V0 |
| **R8** | E5 (partial), then E4/E6 if warranted | Snapping, ripple/roll/slip; multi-track only if needed | R3 |
| **R9** | S6 | Vision summaries — only if R5 shows they add value | R5 |
| **R10** | C | PDF editing | B, V1 |

**`EDGE-CASES.md` is errata, not a phase.** Its corrections apply to whichever
release implements the affected milestone. §4 of that document lists exactly
which sections of which phase docs it amends.

**B0 runs in parallel from now.** It's pure model work — `EditableDocument`,
`ImageDocument`, `ImagePatch`, inverse property tests — with no UI dependency and
no overlap with R1–R3. It unblocks both R4 and R6.

---

## Hard constraints

**E2 before A3.** Phase A rebuilds the menu bar and adds a `⌘K` palette. Both
must be generated from the command registry, not hand-written and migrated later.

**A0 and E4 must not share a release.** A0 migrates the library on disk; E4
migrates the document schema for multi-track. Running both at once means a failure
in either is hard to attribute and hard to revert. Put a shipped release between
them.

**E1 before R3.** Delete and selection are prerequisites for a file browser. A
browser you can't delete from is worse than no browser.

---

## Deliberately deferred pending evidence

**Multi-track (E4).** The single-track editor hasn't been used in anger yet. For
demo videos, missing snapping is the more likely complaint than missing V2, and
snapping costs a fraction as much. Use the editor for a real project first, then
decide. If the answer turns out to be webcam PiP or title overlays, E4 is
justified — otherwise it's a schema migration bought for nothing.

**Vision summaries (S6).** Screen recordings are text-dense, so OCR and
transcripts likely carry most of the search value. Measure search quality with
and without summaries after R5 before building the VLM queue.

**Office format *output* (xlsx, pptx, docx).** Requires LibreOffice — ~800 MB,
cannot run in the App Store sandbox. `PHASE-4-CONVERT.md` §7 offers optional
detection on the direct build only. Reading Office formats works natively.

**Multiple workspace roots, relink workflows, external folder indexing.** Cut in
`PHASE-2.md` §1.2 with reasoning. Revisit only if someone actually asks to point
Reel at an existing archive.

---

## Decisions needed before the release that depends on them

| Decision | Needed by | Reference |
|---|---|---|
| `⌘K` — palette or split? | R2 | `PHASE-2-EDITING.md` §5.1 |
| Can the agent run file deletes, or document edits only? | R2 | `PHASE-2-EDITING.md` §5.3 |
| Smart collections: saved queries or real folders? | R3 | `PHASE-2.md` §5.1 |
| Does the video editor's right rail fold into the unified inspector? | R3 | `PHASE-2.md` §5.3 |
| Does `Inbox` survive as a concept? | R3 | `PHASE-2.md` §5.5 |
| Multi-track: needed at all? | R5 | above |
