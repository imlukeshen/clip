# CaptureKit

`CaptureKit` owns events emitted by user-configured macOS capture sources. It
watches an inbox without recording the screen itself and polls the pasteboard
only after the user enables clipboard history, filters sensitive/transient
pasteboard items, and stores a size-bounded seven-day history. It also decodes
the user's screenshot shortcuts when the build can read that preference domain.

The optional event track runs as a listen-only session event tap on its own
run loop, downsamples cursor motion to 60 Hz without dropping clicks, and keeps
a five-minute rolling buffer. Capture-window detection and the pure alignment
algorithm associate that buffer with system recordings; denied Accessibility
access remains a supported, non-blocking state.
