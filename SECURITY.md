# Security policy

Please report vulnerabilities privately through GitHub Security Advisories for
this repository. Do not include live API keys, private media, prompts, library
paths, or Keychain exports in a report.

Reel stores provider credentials as generic-password Keychain items accessible
only while the user is unlocked. Credentials must never be added to defaults,
logs, project files, crash reports, or the egress ledger. The ledger contains
only provider, model, purpose, time, and whether media was attached. Media egress
requires explicit per-call consent.

Supported releases receive security fixes on the latest minor version. Direct
downloads are Developer ID signed, notarized, and stapled; App Store builds use
the sandboxed channel. Verify downloaded DMGs with the adjacent SHA-256 file.
