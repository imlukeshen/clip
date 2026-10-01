# clipx — Roadmap

## Delivery status

Everything on the committed roadmap has shipped except R9, which is deliberately
gated on evidence.

| Release | Status | Delivery note |
|---|---|---|
| R1–R4 | Complete | Navigation, commands, folders, photo editing, and their acceptance coverage shipped before this roadmap pass. |
| R5 | Complete | S0–S5: resumable indexing, OCR, keyword/moment search, Live Text, semantic retrieval, and agent search. |
| R6 | Complete | V0–V5: conversion graph, native backends, options, batch workflow, agent commands, and direct-build LibreOffice gating. |
| R7 | Complete | T0–T7: native editing, highlighting, Markdown, LaTeX, SyncTeX, projects, snippet workflows, direct text indexing, and text agent tools. |
| R8 | Complete | Multi-track schema, precision editing/snapping, and general keyframes are implemented. |
| R9 | Evidence-gated | S6 remains intentionally deferred until an opt-in local VLM demonstrates measurable search-quality value. |
| R10 | Complete | The PDF document model, PDFium workspace, page editing, OCR, export, and Markdown workflow are implemented. |

## Still open

**Vision summaries (R9 / S6).** Screen recordings are text-dense, so OCR and
transcripts likely carry most of the search value. Measure search quality with
and without summaries before building a local vision-model queue.

**Office-format output (DOCX, XLSX, PPTX).** Needs LibreOffice, which cannot run
in a sandbox. The direct build detects an existing installation and uses it;
clipx never bundles or downloads it. Reading Office formats works natively.

**Timeline.** Track reordering and renaming, true overlapping transitions, and
richer source routing.

**PDF workspace.** Forms, comments, signatures, and arbitrary source-object
editing.

**Text workspace.** A way to correct generated captions (see `CLAUDE.md`,
"Known gaps").

## History

The phase plans for search, conversion, and the text editor, and the errata
written against them, are kept in [`archive/`](archive/) as a record of how
those releases were designed.
