# ADR-0007 — Global clipboard hotkey and floating history panel

Status: Accepted · Date: 2026-08-03

## Context

Clip stages every screenshot and recording into a capture history and, as of the
clipboard-manager work, records everything the user copies system-wide (text,
images, file lists). To be a real clipboard manager — the Maccy comparison the
product is measured against — the history has to be reachable from anywhere, not
only when Clip is the frontmost app.

Two things stood in the way:

1. The existing Capture-menu shortcut is a SwiftUI `Commands` key equivalent. It
   only fires when Clip is frontmost, and only opens an in-window sheet.
2. `docs/adr/0006` forbids hardcoded keyboard shortcuts in the UI — shortcuts are
   read from `com.apple.symbolichotkeys` or not shown — and CI greps for literal
   modifier glyphs (`⌘⇧⌃⌥`) outside `DesignSystem`. A global clipboard shortcut
   is a deliberate exception to that rule and needs to be recorded as one.

We also ship to the Mac App Store from a sandboxed target, so whatever mechanism
we pick must work with no extra entitlement and no Accessibility grant. Maccy is
itself a sandboxed MAS clipboard manager that declares no special entitlements,
which is the existence proof this is possible.

## Decision

**Register one fixed global hotkey, Command-Shift-C, via Carbon
`RegisterEventHotKey`.** Carbon hotkeys are sandbox-safe and need no Accessibility
permission (unlike the `CGEvent` tap the click-tracking feature already uses). The
combo is written with integer virtual-key and modifier constants (`kVK_ANSI_C`,
`cmdKey | shiftKey`), never glyph literals, so the ADR-0006 CI grep stays green.
The wrapper (`GlobalHotKey`) mirrors `EventTapRecorder`: an `actor` fronting a
`final class … @unchecked Sendable` context whose handler is guarded by an
`OSAllocatedUnfairLock`, with the C callback reconstructing the context through an
`Unmanaged` opaque pointer.

**Show the history over other apps in a nonactivating `NSPanel`, not the sheet.**
A `.nonactivatingPanel` at `.floating` level with
`[.canJoinAllSpaces, .fullScreenAuxiliary]` collection behaviour appears without
stealing focus, so after the user picks an entry it lands on the pasteboard and
their next paste targets the app they were already in.

**The Carbon hotkey is the single owner of the shortcut.** Because a Carbon
hotkey intercepts the key event ahead of the responder chain, it shadows the
identical menu key-equivalent when Clip is frontmost rather than racing it. The
delegate routes by focus: in-window sheet when Clip is active, floating panel
when it is not. The menu item keeps the shortcut as a visible hint and as the
fallback path if registration ever fails.

**Paste-back is pasteboard-write-only.** Picking an entry writes it to the
pasteboard; the user presses paste themselves. Synthesising a paste keystroke
(`CGEventPost`) would require Accessibility — the exact permission this design
avoids — so auto-paste is out of scope.

## Consequences

- The clipboard manager works identically on the direct and MAS builds with
  **zero entitlement changes**.
- The shortcut is fixed. It is not yet remappable and does not participate in the
  ADR-0006 system-settings model; making it remappable later is a known follow-up.
- If another app already holds Command-Shift-C system-wide, registration fails and
  `GlobalHotKey.register` throws `CaptureError.hotKeyUnavailable`; the delegate
  logs it and the in-window menu shortcut still works when Clip is frontmost.
- Ownership of the hotkey and panel lives on an `NSApplicationDelegate`
  (`ClipAppDelegate`) wired through `@NSApplicationDelegateAdaptor`, since neither
  a process-lifetime hotkey nor an over-other-apps panel fits the SwiftUI `Scene`
  model.

## What would make us revisit

- Users needing to remap the shortcut, or a conflict with a common third-party
  binding — either pushes us toward the ADR-0006 system-settings path.
- A demand for true auto-paste, which would force the Accessibility question this
  ADR deliberately sidesteps.
- Apple restricting Carbon `RegisterEventHotKey` (long deprecated in spirit though
  still supported), which would mean finding another sandbox-safe global-hotkey
  mechanism.
