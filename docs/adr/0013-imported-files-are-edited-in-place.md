# ADR-0013: Imported files are referenced and edited in place

- Status: Accepted
- Date: 2026-09-30
- Supersedes: invariant I5 for referenced assets; extends ADR-0009

## Context

Clip copied every import into `Media/` and froze it at `chmod 444` (invariant
I5). Editing produced overlays that referenced those frozen bytes, and the only
way to get an edited file was Export, which wrote somewhere new.

That model is safe but does not match what people expect of a document editor.
A file opened from the Desktop should save back to the Desktop. Instead Clip
grew a second copy inside the library, left the original untouched and stale,
and gave the user two files where they had one. The library folder became a
place things disappeared into rather than a place they were organized.

Text assets already broke I5 for exactly this reason (ADR-0009): their edited
file on disk *is* the deliverable.

## Decision

An asset is either **owned** or **referenced**.

**Referenced** is the default for user imports. The bytes stay where the user
had them; the library stores a security-scoped bookmark and indexes the file
without copying it. Saving writes back to that original path. `AssetRecord`
carries `externalBookmarkKey`; when it is set, the asset's location resolves
through `BookmarkStore` instead of the library root, and library path safety
does not apply because the file was never meant to live inside the library.

**Owned** covers everything Clip creates: notes, projects and documents made in
the app, plus anything explicitly imported by copy. These live in the library
folder as ordinary visible files and folders, so the tree a user builds in the
app is the tree they see in Finder.

Saving a referenced asset **flattens**: the edits are applied to the file and
the overlay is cleared. Non-destructive revision does not survive a save,
because the source the overlay referenced no longer exists. Keeping both would
mean the file on disk and the edit model describe different documents.
"Export as new" remains available and leaves the original untouched.

## Consequences

- Editing a file changes that file. A defect here destroys user data, where
  previously the worst case was a wasted copy. Every write goes through one
  audited API, writes atomically, and refuses to run without a resolved
  security-scoped bookmark.
- Overlays cannot outlive a save. Undo is bounded by the save, as in any
  document editor.
- Referenced files can move or vanish between launches. `missingSince` and the
  existing missing-asset flow already model this and become load-bearing.
- Duplicate detection by content hash weakens: the same bytes may legitimately
  be referenced from two paths.
- The sandboxed builds depend on bookmarks resolving across launches. A failure
  to resolve must surface as a clear "can't reach this file" state, never as a
  silent no-op save.

## What would make us revisit

Evidence that in-place saving loses data in normal use, or that sandbox
bookmark resolution is unreliable enough that saves routinely fail.
