# Architecture decision records

One page per decision: context, decision, consequences, and what would make us
revisit it. Newer records override older prose anywhere else in the repo.

| ADR | Decision | Status |
|---|---|---|
| [0007](0007-global-clipboard-hotkey.md) | A global Command-Shift-C clipboard hotkey via Carbon | Accepted |
| [0008](0008-text-editing-uses-native-undo.md) | Text content edits use AppKit's native undo | Accepted |
| [0009](0009-text-assets-are-writable.md) | Text assets are edited in place | Accepted |
| [0010](0010-bundled-tree-sitter-grammars.md) | Pinned, bundled Tree-sitter grammars | Accepted |
| [0011](0011-markdown-preview-is-offline-and-sanitized.md) | Markdown preview is offline and sanitized | Accepted |
| [0012](0012-untrusted-tex-compilation.md) | LaTeX compiles as untrusted input | Accepted |
| [0013](0013-imported-files-are-edited-in-place.md) | Imports are referenced and saved back in place | Accepted |
| [0014](0014-assistant-computer-use.md) | The assistant may see and operate the screen | Proposed |
| [0015](0015-running-code.md) | Run code in the direct build only | Accepted |

ADRs 0001–0006 predate this folder and were never written down. `CLAUDE.md`
records their decisions as rules (no in-app recorder, FFmpeg linked in-process
and LGPL-only, no hardcoded shortcuts); write the ADR when you next change one
of those areas.
