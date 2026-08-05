# ADR-0008: Text editing uses native undo

- Status: Accepted
- Date: 2026-08-03

## Context

Clip routes document mutations through invertible patches so undo, autosave, and
assistant actions share one path. Character-by-character text edits are a poor
fit for that model: patches would duplicate `NSTextStorage`, grow rapidly, and
lose the typing-group behavior people expect from a macOS editor.

TextKit already registers typing, paste, deletion, and find/replace with an
`UndoManager`. Document-level text changes such as language and editor settings
still need exact `TextPatch` inverses.

## Decision

The active `NSTextView` owns character mutations and registers them with its
native undo machinery. `TextEditorViewModel` applies structural changes only
through `TextPatch`. Both use the same editor-scoped `UndoManager`, so content
and structural actions remain one ordered undo history.

This is the sole documented exception to invariant I4. Code outside the AppKit
text surface must not mutate the buffer behind the editor's back.

## Consequences

- Typing and find/replace retain native macOS undo grouping and performance.
- Every structural mutation remains exactly invertible under invariant I3.
- App commands must route undo and redo to the text editor while it is open.
- Text automation must operate through editor commands rather than replacing
  the on-disk file directly.

## Revisit when

Revisit if TextKit can no longer share an external `UndoManager`, or if a future
collaborative editing model requires operation-based character histories.
