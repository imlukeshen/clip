# ADR-0011: Markdown preview is offline and sanitized

- Status: Accepted
- Date: 2026-08-03

## Context

Markdown documents can contain raw HTML, executable script, remote links, and
images that reference either the network or arbitrary local files. Rendering
that input directly in a web view would let merely opening a document disclose
activity, execute document-authored code, or read outside the document folder.
The same renderer also needs to power Phase V exports so preview and exported
output do not drift.

## Decision

`TextEngine` owns one safe Markdown-to-HTML renderer based on Swift Markdown.
It never emits document-authored HTML or script. The generated page uses a
deny-by-default content security policy and only runs Clip's bundled KaTeX and
scroll-synchronization code.

The preview uses a non-persistent `WKWebView`. A content rule list and navigation
delegate block network loads. Relative raster images are served through the
`clip-local` scheme only after canonical-path and symlink checks prove they are
inside the Markdown file's directory. Exports embed approved local raster data
and use the same HTML renderer through ConvertKit.

## Consequences

- Previewing Markdown does not create network traffic or retain web data.
- Raw HTML is intentionally omitted instead of partially sanitized.
- Remote images become a visible blocked-resource placeholder.
- Local SVG is not rendered because active SVG content expands the trust model.
- KaTeX fonts and runtime increase the app bundle, but math remains offline.
- Preview and PDF/HTML conversion share GFM, math, and security behavior.

## Revisit when

Revisit if Clip adopts a separately audited HTML sanitizer, needs a user-approved
remote-resource mode, or can safely isolate SVG rendering into decoded pixels.
