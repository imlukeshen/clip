# Reel

Reel is a local-first screen demo editor for macOS. This repository is being
implemented milestone-by-milestone from the supplied design specification.

The current implementation contains **M0 — Model foundation**: the
Foundation-only `CoreModel` package, its canonical JSON format, and its
transactional patch/undo engine.

## Test

```bash
make test
```

Requires macOS 14 or later and a Swift 6 toolchain.
