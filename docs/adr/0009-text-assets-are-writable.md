# ADR-0009: Text assets are writable

- Status: Accepted
- Date: 2026-08-03

## Context

Clip normally treats imported media as immutable assets (invariant I5). A text
editor that can open library files but only save copies would make ordinary
notes, source files, Markdown, and LaTeX unexpectedly cumbersome.

Text files differ from captured media: their primary purpose in Clip is direct
editing, and an in-place save is the expected document behavior.

## Decision

Files classified as `AssetKind.text` are the one writable asset class. They are
imported with user-write permission and saved only through
`LibraryStore.saveTextContents`. That method writes atomically, refreshes the
content hash and byte size, and emits the normal library change notification.

Image, audio, video, and PDF source assets remain read-only. Scratch buffers are
not assets and live under `.reel/scratch/` until a later save/import flow makes
them library files.

## Consequences

- Text editing behaves like a native document workflow.
- The library index stays consistent after every in-place save.
- All writable-asset exceptions are concentrated in one audited API.
- Backup and external-file conflict handling become important follow-up work.

## Revisit when

Revisit if user research favors versioned copies, or if file coordination with
external editors cannot make in-place updates reliable.
