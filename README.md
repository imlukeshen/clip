# Reel

Reel is a local-first screen demo editor for macOS. This repository is being
implemented milestone-by-milestone from the supplied design specification.

Implemented milestones:

- **M0 — Model foundation:** deterministic `CoreModel`, canonical JSON, and the
  transactional patch/undo engine.
- **M1 — Library and index:** immutable assets, security-scoped bookmarks,
  project packages, history, and a fully rebuildable SQLite cache.
- **M2 — Ingest:** inbox and pasteboard sources, stability polling,
  asynchronous media probing, sampled hashing/dedupe, thumbnails, audio peaks,
  and the App-layer ingest coordinator.

## Test

```bash
make test
```

Requires macOS 14 or later and a Swift 6 toolchain.
