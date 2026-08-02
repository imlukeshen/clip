# AIKit

AIKit owns provider adapters, tool schemas, keychain credentials, the egress
ledger, and on-device transcription. It may import `CoreModel`, Foundation,
Security, and Speech. It must never import `MediaEngine` or `LibraryStore` and
never receives a `ProjectDocument`; tool execution belongs to the App layer.
