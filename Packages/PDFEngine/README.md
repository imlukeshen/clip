# PDFEngine

`PDFEngine` owns PDF reading, page editing, text search, permanent redaction,
OCR hand-off, and Markdown extraction on top of the vendored PDFium build
(`Vendor/pdfium`). It may depend on CoreModel, PDFium, Foundation, and Apple's
CoreGraphics, CoreText, and CryptoKit; never on UI or storage.
