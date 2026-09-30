# ADR-0009: Text assets are writable

- Status: Accepted
- Date: 2026-08-03

## Context

clipx normally treats imported media as immutable assets (invariant I5). A text
editor that can open library files but only save copies would make ordinary
notes, source files, Markdown, and LaTeX unexpectedly cumbersome.

Text files differ from captured media: their primary purpose in clipx is direct
editing, and an in-place save is the expected document behavior.

## Decision

Files classified as `AssetKind.text` are the one writable asset class. They are
imported with user-write permission and saved only through
`LibraryStore.saveTextContents`. That method writes atomically, refreshes the
content hash and byte size, and emits the normal library change notification.

Image, audio, video, and PDF source assets remain read-only.

**Amended 2026-09-30:** a new scratch file is a text asset from the start. "New
scratch" creates `Untitled.txt` in `Media/Inbox/`, so it can be filed, found,
and moved to the Trash like any other file. While it keeps a clipx-given
`Untitled` name, its extension follows the detected language. Because two text
assets can now hold equal bytes (two empty files, or one saved to match
another), the library index no longer requires unique content hashes for text;
imports still deduplicate by hash. Buffers made before this change stay under
`.reel/scratch/`, listed separately, until the user trashes them.

## Consequences

- Text editing behaves like a native document workflow.
- The library index stays consistent after every in-place save.
- All writable-asset exceptions are concentrated in one audited API.
- Backup and external-file conflict handling become important follow-up work.

## Revisit when

Revisit if user research favors versioned copies, or if file coordination with
external editors cannot make in-place updates reliable.
