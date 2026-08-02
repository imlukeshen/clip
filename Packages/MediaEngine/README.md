# MediaEngine

`MediaEngine` owns deterministic timeline composition, AVFoundation playback
assembly, Core Image frame compositing, pure effect evaluation, and atomic
hardware-backed export. It depends only on `CoreModel` and Apple media
frameworks; it must never import app UI, storage, conversion, or AI packages.
