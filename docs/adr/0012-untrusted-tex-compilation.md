# ADR 0012: Compile LaTeX as untrusted content

- Status: Accepted
- Date: 2026-08-03

## Context

LaTeX source can request filesystem access, spawn commands through shell escape,
run indefinitely, and produce unexpectedly large output. Clip also ships through
both direct and App Store channels, so relying on a system TeX installation would
make compilation unavailable or inconsistent for most users.

## Decision

Clip bundles the pinned official arm64 Tectonic 0.16.9 executable as the default
engine. Every compile runs in Tectonic's untrusted mode with shell escape
disabled, restrictive `openin_any` and `openout_any` settings, an isolated copy
of the explicitly declared project files, a hard timeout, cancellation by process
termination, and a 500 MB PDF output ceiling.

Tectonic's package cache lives in the active Clip library. Network package
resolution is disabled until the user makes a one-time explicit choice; allowed
attempts are recorded in the egress ledger. A local bundle may be supplied for
offline compilation. The direct build may explicitly opt into a detected
`latexmk` installation, but that adapter also disables shell escape and is never
used by the App Store build.

## Consequences

LaTeX compilation works without installing MacTeX and a failed or hostile source
cannot write into the original project. The app grows by roughly 48 MB and must
audit and sign the nested Tectonic executable during distribution builds.
Tectonic package availability still depends on either prior cache population,
explicit network consent, or a local bundle.
