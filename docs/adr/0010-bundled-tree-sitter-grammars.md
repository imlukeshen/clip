# ADR-0010: Bundle a minimal Tree-sitter grammar set

- Status: Accepted
- Date: 2026-08-03

## Context

The text editor needs responsive, incremental syntax highlighting while Clip is
offline. Regular expressions alone cannot reliably represent nested syntax, and
downloading grammars at runtime would make behavior nondeterministic and expose
document metadata to network infrastructure.

Several current grammar repositories expose Swift package manifests that rely
on generated parser files missing from their default branch, or conditionally
discover scanner files using a working-directory assumption SwiftPM does not
guarantee.

## Decision

Clip uses SwiftTreeSitter 0.25.0 and exactly the 19 grammars named by the text
editor plan. Every repository is pinned to an immutable revision. For Swift,
SQL, and LaTeX, Clip pins the upstream revisions that contain generated parser
sources; for CSS, JavaScript, Python, and YAML, it pins the last upstream Swift
manifest that explicitly includes the required external scanner.

Each editor owns an actor-isolated parser and mutable tree. Character edits are
translated from AppKit UTF-16 ranges into Tree-sitter UTF-16 byte points and
applied incrementally. Styling is limited to the visible region plus 200 lines
in each direction. Unknown languages use bounded regular-expression styling,
and plain text receives no syntax attributes.

## Consequences

- Highlighting works without network access and has a reproducible dependency
  graph.
- The binary grows by the compiled parsers, but avoids a much larger universal
  language pack and its unrelated runtime dependencies.
- Updating a grammar requires validating its generated source, scanner linkage,
  ABI compatibility, license, performance, and both release channels.
- The exact package allowlist and bundled acknowledgements make a dependency
  change fail distribution validation until it is reviewed.

## Revisit when

Revisit if SwiftPM grammar packages converge on generated-source releases, or
if a smaller audited packaging format can preserve offline behavior.
