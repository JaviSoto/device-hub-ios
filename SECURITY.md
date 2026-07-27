# Security Policy

## Reporting a vulnerability

Please use
[GitHub private vulnerability reporting](https://github.com/JaviSoto/device-hub-ios/security/advisories/new)
for security issues. Do not open a public issue for a suspected vulnerability.

Include the affected revision, platform version, protocol stage, expected and
observed behavior, and the smallest safe reproduction. Sanitized traces or a
minimal synthetic fixture are preferable to a full device log.

Do not send pairing PINs, controller or peer keys, pair records, PSKs,
provisioning material, bearer tokens, UDIDs, serial numbers, IP or MAC
addresses, raw packets, screenshots, frames, passcodes, or screen contents.
State that the sensitive artifact exists and arrange a scoped transfer only if
the maintainer confirms it is necessary.

## Supported code

Security fixes target the current `main` branch.

## Security-sensitive areas

Reports are especially useful when they concern:

- Pair Setup, Pair Verify, Bonjour authentication, or controller identity
- Keychain persistence and provisional or committed pair-record ordering
- TLS-PSK, CDTunnel, RTP/RTCP, HEVC, PNG, or HID parser boundaries
- Input authorization, connection-generation isolation, cancellation, or
  release of held input
- Diagnostics redaction, consent, authentication, retention, or storage
- Build signing, provisioning, or artifact provenance

The intended guarantees are documented in
[Protocol and security](Docs/ProtocolSecurity.md). A behavior that contradicts
that contract should be treated as a security issue even when it first appears
to be a reliability bug.

Only test devices you own or are explicitly authorized to control. Do not
weaken authentication, reset another device's pairing state, or publish an
exploit before a coordinated disclosure plan is agreed.
