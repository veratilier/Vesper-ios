# ZIPFoundation in Vesper

Vendored from https://github.com/weichsel/ZIPFoundation, release 0.9.20,
commit `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`. The upstream MIT license is
preserved in `LICENSE`. All files under `Sources/` are unchanged.

The package uses the release’s Swift 5.9 manifest as `Package.swift`, with
watchOS 4 raised to watchOS 5 (the minimum accepted by current SwiftPM).
This backports upstream fix `676ffa3df2c4dca955c0a464a443139fe6e45a1d`
without taking unrelated unreleased library changes. Vesper itself targets
watchOS 10. Upstream test targets/fixtures are omitted; Vesper’s
`EPUBImporterTests` exercise the integration.

When updating, replace Sources and LICENSE from a reviewed upstream release,
check its manifest, and run EPUBImporterTests plus iOS and Mac builds.
Do not patch DerivedData/SourcePackages; this checked-in package is the source.
