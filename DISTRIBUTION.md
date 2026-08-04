# Distribution

Clip has two generated macOS release channels:

- `Clip` / `Release` is an arm64 Developer ID build with the hardened runtime
  and no App Sandbox. It is exported into a DMG, submitted with `notarytool`,
  and stapled before publication.
- `Clip-AppStore` / `AppStoreRelease` is an arm64 Apple Distribution build with
  App Sandbox, user-selected file access, app-scoped bookmarks, and outbound
  network access. Its export destination is App Store Connect upload.

The direct-download build detects an existing LibreOffice installation and can
write DOCX, XLSX, and PPTX through it. Clip never bundles, downloads, or installs
LibreOffice. The sandboxed Mac App Store build never exposes those external-tool
conversion routes, even when LibreOffice is installed on the Mac. App Store
listing copy must state that Office files can be read, while Office-format output
is available only in the direct build with LibreOffice installed.

Both channels bundle the same pinned Tree-sitter runtime and 19 syntax grammars.
The acknowledgements resource contains their permissive-license notices, and
the release checks reject any Swift package URL outside the reviewed allowlist.

Run `make distribution-check` without credentials to validate both configurations
and their export plists. `make release` performs the real release and requires:

- `DEVELOPMENT_TEAM`: Apple Developer Team ID.
- `NOTARY_KEY`: path to an App Store Connect API `.p8` key.
- `NOTARY_KEY_ID`: key ID.
- `NOTARY_ISSUER`: issuer UUID.
- `RELEASE_VERSION`: a `v`-prefixed release version; `CLIP_RELEASE_DIR` is optional.

The tag workflow imports a protected P12 containing the Developer ID Application
and Apple Distribution identities, materializes the API key, runs all tests,
notarizes the direct DMG, uploads the App Store archive, and publishes the DMG
and SHA-256 checksum to the GitHub release. Configure these release-environment
secrets:

- `MACOS_CERTIFICATE_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_DEVELOPMENT_TEAM`
- `APP_STORE_CONNECT_KEY_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

Uploading a build does not submit its store listing to App Review. Complete the
version metadata, privacy answers, screenshots, export-compliance response, and
review submission in App Store Connect after the workflow's upload passes
processing. Direct downloads use Apple's current `notarytool` and `stapler`
flow; App Store builds do not need separate notarization because App Store
submission performs the equivalent security checks.

Apple references: [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [distributing releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).
