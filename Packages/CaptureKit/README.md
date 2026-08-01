# CaptureKit

`CaptureKit` owns events emitted by user-configured macOS capture sources. It
watches an inbox without recording the screen itself and polls the pasteboard
without retaining clipboard history. It also decodes the user's screenshot
shortcuts when the build can read that preference domain.
