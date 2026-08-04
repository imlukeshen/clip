# Third-party acknowledgements

Clip's conversion framework includes the following dynamically linked
components. The complete corresponding source is available from the linked
upstream release and can be rebuilt with [`Scripts/build-ffmpeg.sh`](Scripts/build-ffmpeg.sh).

## FFmpeg 7.1.2

Copyright © the FFmpeg developers. Licensed under the GNU Lesser General Public
License 2.1 or later. Clip's build disables GPL and nonfree components and does
not include x264 or x265.

- Source: <https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz>
- License: [`Vendor/ffmpeg/LICENSE.LGPL-2.1`](Vendor/ffmpeg/LICENSE.LGPL-2.1)

## libvpx 1.15.2

Copyright © the WebM project authors. Licensed under the three-clause BSD
license.

- Source: <https://github.com/webmproject/libvpx/releases/tag/v1.15.2>
- License: [`Vendor/ffmpeg/LICENSE.libvpx`](Vendor/ffmpeg/LICENSE.libvpx)

## libaom 3.12.1

Copyright © the Alliance for Open Media contributors. Licensed under the
three-clause BSD license.

- Source: <https://aomedia.googlesource.com/aom/+/refs/tags/v3.12.1>
- License: [`Vendor/ffmpeg/LICENSE.libaom`](Vendor/ffmpeg/LICENSE.libaom)

## libwebp 1.6.0

Copyright © the WebP project authors. Licensed under the three-clause BSD
license.

- Source: <https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz>
- License: [`Vendor/ffmpeg/LICENSE.libwebp`](Vendor/ffmpeg/LICENSE.libwebp)

## GRDB.swift 7.11.1

Copyright © 2015–2025 Gwendal Roué. Licensed under the MIT License.

- Source: <https://github.com/groue/GRDB.swift/releases/tag/v7.11.1>
- License: [`Vendor/licenses/GRDB-LICENSE`](Vendor/licenses/GRDB-LICENSE)

## PDFium 152.0.7961.0

Copyright © the PDFium authors. Licensed under the three-clause BSD license;
the pinned non-V8 binary also includes permissively licensed third-party
components whose complete notices are shipped with Clip.

- Source: <https://pdfium.googlesource.com/pdfium/>
- Binary: <https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F7961>
- Licenses: [`Vendor/pdfium/licenses`](Vendor/pdfium/licenses)

## Tree-sitter syntax engine

Clip bundles SwiftTreeSitter 0.25.0, the Tree-sitter 0.25.10 runtime, and pinned
grammars for Bash, C, C++, CSS, Go, HTML, Java, JavaScript, JSON, LaTeX,
Markdown, Python, Rust, SQL, Swift, TOML, TypeScript, XML, and YAML. They run
entirely on-device and do not download grammars or source text.

SwiftTreeSitter is licensed under the three-clause BSD license. The runtime and
grammars are licensed under the MIT license.

- Runtime API: <https://github.com/tree-sitter/swift-tree-sitter>
- Runtime: <https://github.com/tree-sitter/tree-sitter>
- Grammar sources: <https://github.com/tree-sitter/tree-sitter/wiki/List-of-parsers>
- Licenses and copyright notices: [`Vendor/licenses/TREE-SITTER-NOTICES`](Vendor/licenses/TREE-SITTER-NOTICES)

## Swift Markdown 0.8.0

Copyright © 2021–2026 Apple Inc. and the Swift project authors. Swift Markdown
and its Swift cmark dependency are licensed under the Apache License 2.0 with
the Swift Runtime Library Exception. Clip uses the parser entirely on-device.

- Source: <https://github.com/swiftlang/swift-markdown/releases/tag/0.8.0>
- License: [`Vendor/licenses/SWIFT-MARKDOWN-LICENSE`](Vendor/licenses/SWIFT-MARKDOWN-LICENSE)

## KaTeX 0.17.0

Copyright © 2013–2020 Khan Academy and other contributors. Licensed under the
MIT License. Clip bundles the minified renderer and WOFF2 fonts for offline math
preview; no CDN or runtime download is used.

- Source: <https://github.com/KaTeX/KaTeX/releases/tag/v0.17.0>
- Package checksum (SHA-256): `252efd48f892d178136fe3ba3530d3718b2b087ea81c3a40a877227bc61d5256`
- License: [`Vendor/licenses/KATEX-LICENSE`](Vendor/licenses/KATEX-LICENSE)
