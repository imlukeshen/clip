# CoreModel

`CoreModel` owns Reel's deterministic document graph, time representation,
effects, event sidecars, JSON interchange, and transactional patch engine. It
imports Foundation only and must never depend on UI, storage, or media
frameworks.
