<div align="center">

# clipx

https://youtu.be/m5-lMDYilT4?si=X0fdWsulbCq9VNzn

### Your own AI-powered creative suite. Running on your Mac.

Video, photos, PDFs, and LaTeX — edited by you, or by an AI that clicks the
buttons for you.<br>
**No subscription. No account. No uploads. Open source.**

[**Download for macOS**](https://github.com/imlukeshen/clipx/releases) ·
[Build from source](#build-from-source) ·
[What it does](#what-it-does)

</div>

---

Creative tools moved to the cloud and started charging rent. clipx goes the
other way: the editors you reach for every day, in one native app, on your own
machine, with an assistant that can drive every one of them.

- **One app, four editors.** A multi-track video timeline, a layered photo
  editor, a real PDF editor, and a text/LaTeX editor that compiles as you type.
- **An AI that actually edits.** It doesn't just chat about your files. It
  works the same editor you do, and every change it makes is one Command-Z
  away.
- **Private by default.** Your library is a folder you choose. Point the
  assistant at a local model through Ollama or LM Studio and nothing leaves
  your Mac. Use a hosted one and a ledger shows exactly what was sent.
- **Yours to keep.** Apache-2.0. No account, no subscription, no watermark.

## Just ask

> *"Trim the silences out of this recording."*
>
> *"Redact my name from every page of this PDF."*
>
> *"Why won't my LaTeX build? Fix it."*
>
> *"Turn this screen recording into a GIF."*
>
> *"Find the screenshot with the error message in it."*

The assistant turns each request into the same edits you'd make by hand, on the
same undo stack, so you can watch it work, step back through it, or take over
halfway.

## Get started in a minute

1. Download `clipx-<version>.dmg` from
   [Releases](https://github.com/imlukeshen/clipx/releases) and drag clipx to
   Applications.
2. Pick a folder for your library.
3. Drop in a video, photo, PDF, or text file — or just take a screenshot.

Want the AI fully offline? Install [Ollama](https://ollama.com), then choose
your models in clipx → Settings. clipx can install them for you.

## What it does

- **Video** — a multi-track timeline with trim, split, snapping, fades,
  keyframes, and exact undo. Crop, background framing, rounded corners,
  shadows, regional blur, and zoom, exported to H.264, HEVC, or ProRes.
- **Click track** — opt-in, listen-only capture of your clicks during a
  recording, aligned to the footage and turned into automatic zooms.
- **Photos** — a layered, non-destructive editor with annotation, crop,
  padding, Live Text, and redaction that flattens pixels rather than drawing
  over them.
- **PDFs** — page and text editing on PDFium, permanent redaction, OCR,
  and layout-aware Markdown extraction.
- **Text and LaTeX** — a native editor with syntax highlighting, offline
  Markdown preview, and confined LaTeX compilation with SyncTeX diagnostics.
- **Conversion** — a planner that picks a backend per file, with remux,
  VideoToolbox, ImageIO, and linked LGPL FFmpeg paths.
- **Search** — on-device indexing with OCR, plus exact and semantic search
  across your library.
- **Assistant** — hosted or local models that operate the editor through tool
  calls, with an inspectable egress ledger and undoable edits.

## Install

Download the latest `clipx-<version>.dmg` from
[Releases](https://github.com/imlukeshen/clipx/releases), open it, and drag clipx
to Applications.

clipx needs macOS 14 or later on Apple silicon. The bundled FFmpeg framework is
arm64-only, so there is no Intel build.

**On first launch:** if the download is an unsigned build, macOS refuses to open
it and offers only Move to Trash. Right-click clipx in Applications and choose
**Open**, then confirm. You only need to do this once. Releases built with
Developer ID credentials are notarized and open normally.

clipx asks for a library folder on first launch. Pick somewhere writable; it
creates `Media`, `Projects`, `Exports`, and a hidden `.reel` cache inside.

## Build from source

```bash
make bootstrap   # one-time toolchain check
make run         # build and launch a Debug copy
```

To work in Xcode:

```bash
make xcode
```

Re-run `make xcode` after pulling changes that add, remove, or rename Swift
files — `clipx.xcodeproj` is generated and deliberately not committed, so an
open project will not discover them. Keep only `clipx.xcodeproj` open: the
pre-rename `Reel.xcodeproj` and the individual package workspaces claim the same
local packages, and Xcode rejects the duplicate ownership.

To build an installer locally:

```bash
make dmg
```

That produces an ad-hoc signed `ReleaseBuild/unsigned/clipx-<version>.dmg` with
no Apple Developer account required. `make release` produces the signed and
notarized channel and needs Developer ID and App Store Connect credentials; see
[`DISTRIBUTION.md`](DISTRIBUTION.md).

## Develop

| Command | What it does |
| --- | --- |
| `make test` | Packages, app targets, and the dependency/licence gates |
| `make test-packages` | Packages and app targets only — fast, use while iterating |
| `make test-ui` | Native interaction suite; needs an unlocked macOS session |
| `make lint` | Strict formatter gate |
| `make format` | Apply the formatter |
| `make build` | Build both distribution schemes |
| `make ffmpeg` | Rebuild the vendored LGPL FFmpeg from pinned sources |
| `make licence-audit` | Verify the LGPL-only FFmpeg configuration |

Requires macOS 14+ and a Swift 6 toolchain whose compiler matches its installed
macOS SDK.

Start with [`CLAUDE.md`](CLAUDE.md) for the invariants that matter, then
[`docs/DESIGN.md`](docs/DESIGN.md) for the data model and services.

## Project status

clipx is built milestone-by-milestone against the design in `docs/`. M0–M9 are
complete: the model foundation and patch/undo engine, library and index, ingest,
shell and workspaces, conversion, composition and playback, effects and export,
the event track, the AI layer, and both distribution channels.

Later phases added the multi-track editing foundation, the photo and PDF
workspaces, on-device search, the conversion planner, and the text and LaTeX
editor.

Known incomplete: track reordering and renaming, true overlapping transitions,
and richer source routing in the timeline; forms, comments, signatures, and
arbitrary source-object editing in the PDF workspace.

## Licence

Apache-2.0. FFmpeg is linked as LGPL-only, built without `--enable-gpl`, x264,
or x265; H.264 and HEVC come from VideoToolbox. Third-party notices are
collected in [`ACKNOWLEDGEMENTS.md`](ACKNOWLEDGEMENTS.md).
