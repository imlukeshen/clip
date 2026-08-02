# MediaEngine

`MediaEngine` owns deterministic timeline composition, AVFoundation playback
assembly, Core Image frame compositing, and pure effect evaluation. It depends
only on `CoreModel` and Apple media frameworks; it must never import app UI,
storage, conversion, or AI packages.
