# ADR 0015: Run code only in the direct build, with toolchains already installed

- Status: Accepted
- Date: 2026-09-30

## Context

The text editor highlights, indents, and completes every language it has a
grammar for, and users want to run the short program they are writing without
switching to Terminal. clipx is a lightweight scratch editor, not an IDE: the
goal is "run this file and show what it printed", not debugging, project
builds, or package management.

The App Store build is sandboxed and cannot launch toolchains installed outside
the app (see the Phase 4 and Phase 5 notes on external binaries). Bundling
interpreters and compilers would make Run work there, but costs hundreds of
megabytes and a new third-party dependency per language.

## Decision

Only the direct-download build runs code. Each runnable language has a
`CodeToolchain`: where its tool is usually installed (Homebrew, python.org,
rustup, the Go and Java installers, Xcode or the Command Line Tools) and the
commands that run a file. Shims such as `/usr/bin/swift` and `/usr/bin/clang`
are used only when developer tools are present, because otherwise they open an
install dialog; `/usr/bin/python3` and `/usr/bin/java` are never used for the
same reason.

| Language | Tool | Steps |
|---|---|---|
| Python | `python3` | run |
| JavaScript | `node` | run |
| TypeScript | `bun`, `deno`, or `node` 22.6+ | run with types stripped |
| Swift | `swift` | run |
| Go | `go` | `go run` |
| Rust | `rustc` | build, then run |
| C, C++ | `clang`, `clang++` | build, then run |
| Java | `java` 11+ | single-file source launch |
| Bash | `bash` | run |
| SQL | `sqlite3` | run against an in-memory database |

Markup and data formats (HTML, CSS, JSON, YAML, TOML, XML, Markdown, LaTeX) are
not programs and have no Run button; LaTeX keeps its own build (ADR 0012).

A run stages the buffer, unsaved edits included, in a temporary folder, builds
there when the language needs it, and runs from the file's own folder so
relative paths and sibling imports behave as in Terminal. Output streams into
the terminal panel as it is printed. The program runs as the user with no
standard input, a 60-second limit on build and run together, a 5 MB output
cap, and cancellation by process termination. Unlike LaTeX, the code is the
user's own and is not treated as untrusted content: it has the user's normal
permissions, exactly as it would in Terminal.

## Consequences

Running code needs no new dependency and adds nothing to the app's size. A
missing toolchain is explained with where to get it. App Store users can edit
every language with full highlighting, indentation, and completion but cannot
run it. Programs that read standard input fail at the first read.

## What would make us revisit

Demand for Run in the App Store build (bundle signed interpreters with the
sandbox-inherit entitlement, as Tectonic is), programs that need interactive
input, or multi-file projects that need a real build system.
