# PDFium binary

Pinned non-V8 PDFium build for Apple silicon macOS.

- Upstream: Chromium PDFium
- Binary distributor: `bblanchon/pdfium-binaries`
- Version: 152.0.7961.0
- Archive: `pdfium-mac-arm64.tgz`
- Archive SHA-256: `1193a771e0bd934530afa3df73a0d44551d8f4078442e290054e6dd38ded960f`
- vendored dylib SHA-256: `f2431ccc1b88ab3b940e67cfc8889031fa7ae9516e1d57a346f71b1359392c8a`

The XCFramework was made from the upstream headers and `libpdfium.dylib` with:

```sh
xcodebuild -create-xcframework \
  -library lib/libpdfium.dylib \
  -headers module-headers \
  -output PDFium.xcframework
```

Its install name is rewritten from `./libpdfium.dylib` to
`@rpath/libpdfium.dylib` so SwiftPM test bundles and Reel can embed it safely.

The complete license set from the binary archive is retained in `licenses/`.
