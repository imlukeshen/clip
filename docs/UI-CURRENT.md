# Clip UI — Current Implementation

Audited from the direct Debug build in dark appearance at 1440 × 900 on
2026-08-03, plus the light and dark theme definitions in
`Packages/DesignSystem`. The shipped SwiftUI/AppKit implementation and design
system are the source of truth; `UI.md` remains historical intent.

## Visual language

Clip is monochrome and content-first. Dark mode uses near-black nested surfaces;
light mode uses white and cool-neutral grays. Accent emphasis is neutral rather
than blue. Semantic color is reserved for click tracking, success, and danger.
Edges are hairlines, and controls use continuous rounded corners.

The spacing scale is 4, 6, 10, 14, 20, and 28 points. Radii are 5, 8, 10, 12,
and 16 points. The shared hairline is 0.5 point. Typography ranges from 10-point
section labels to 15-point titles, using regular or medium weight only; numeric
and editor-adjacent metadata use monospaced faces.

## Palette

| Token | Dark | Light |
|---|---:|---:|
| Base | `#0B0B0C` | `#F7F7F8` |
| Panel | `#121213` | `#FFFFFF` |
| Raised | `#1C1C1E` | `#F0F0F2` |
| Sunken | `#08080A` | `#1B1B1E` |
| Primary text | `#EDEDEF` | `#18181B` |
| Secondary text | `#9B9BA3` | `#5C5C66` |
| Tertiary text | `#6A6A72` | `#8A8A94` |
| Accent | `#F2F2F5` | `#1A1A1E` |

Lines are opacity-derived from white in dark mode and black in light mode.

## Shared components

- Asset cards: 1.6:1 thumbnails, metadata footer, hover-open affordance,
  selection badge, ingest progress, and failure/retry states.
- Buttons: plain, icon, bordered, and prominent variants share snappy press
  scale and smooth hover transitions, respecting Reduce Motion.
- Drop zones: compact 46-point rows with idle, hover, drag-target, and rejecting
  states.
- Search: centered 420-point field, expanding to 464 points while focused, with
  outside-click dismissal.
- Supporting primitives: chips, keyboard chips, section labels, status strips,
  backend badges, empty states, toasts, and breadcrumbs.

## Shell and workspace layout

The library sidebar is 232 points wide and runs behind the traffic lights. A
42-point title bar spans the workspace. Library workspaces use a centered content
column capped at 1100 points with 32-point horizontal margins. Editors switch to
full-bleed content and can add a resizable right inspector.

Navigation is the sidebar, not a tab strip: All Media, Videos, Photos, PDFs,
Text, folders, and Convert. Asset metadata is shown on demand rather than in a
persistent browsing inspector.

## Workspace observations

- All Media/Inbox: compact drop target, capture status, shortcut guidance, and
  grid/list browser controls.
- Video: library browser until a recording opens; the editor becomes full-bleed
  with preview, tool rail, timeline, and inspector.
- Photo: library actions lead into a full-bleed canvas editor with focused tools
  and layer inspector.
- PDF: library actions lead into thumbnails, tool rail, document canvas, and PDF
  edit inspector.
- Text: library includes imported text assets and restorable scratch buffers.
  The full-bleed editor uses TextKit 2, a 48-point line-number gutter, document
  header, 26-point status bar, and text settings inspector.
- Convert: queue rows expose source, target, selected backend, progress, and
  completion state.

## Differences from historical `UI.md`

- The top workspace tab strip was removed; the sidebar is primary navigation.
- Borders are lighter and surfaces rely more on depth and spacing.
- Search is wider, centered, rounded, and dismisses focus on an outside click.
- The library inspector was replaced by an on-demand Get Info surface.
- Editors use full-bleed layouts while browsing views retain the centered column.
- The product name and iconography are Clip rather than the former Reel
  placeholder.

## Current hardcoded geometry audit

Some established screens still contain local geometry outside the shared token
scale, especially the timeline, image editor, PDF tools, sidebar indentation,
and fixed inspector controls. These values predate this inventory and were not
changed during the text editor work. New Text workspace surfaces compose from
existing colors, typography, radii, and spacing tokens; its fixed 42-point
header, 48-point gutter, and 26-point status bar match existing shell/editor
geometry.
