# SearchEngine

`SearchEngine` owns on-device indexing and retrieval: OCR, transcripts, text
content, embeddings, and the exact, keyword, and semantic queries over them. It
reads the library through `LibraryStore` and uses Apple's Vision,
NaturalLanguage, AVFoundation, and Accelerate. Nothing it indexes leaves the
Mac.
