# LibraryStore

`LibraryStore` owns clipx's on-disk library layout, security-scoped bookmarks,
project packages, asset metadata sidecars, and rebuildable SQLite index. Assets
are either owned (inside the library folder) or referenced (left where the user
keeps them, located through a bookmark; ADR-0013). Owned media is read-only;
text assets are the writable exception (ADR-0009). It may depend only on
CoreModel, Foundation, and GRDB.
