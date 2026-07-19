# DockPriority repository instructions

## Authority and scope

- `docs/IMPLEMENTATION_SPEC.md` is the product and architecture authority for
  version 0.1.0. Do not preserve a copied DockAnchor behavior when it conflicts
  with that specification.
- Use only public macOS APIs. Do not add private frameworks, Dock process killing,
  shell commands, or AppleScript as relocation shortcuts.
- Keep macOS 15.4 as the deployment target and do not add dependencies without
  explicit approval.
- Preserve the MIT grant, Bradley Wyatt attribution, and `NOTICE.md`.
- Do not implement profiles or automatically import DockAnchor preferences.

## Change discipline

- Separate display discovery, Dock inspection, Dock relocation, persistence,
  scheduling, coordination, and UI through the seams specified in the design.
- Serialize policy state in the `@MainActor` coordinator. Asynchronous callbacks
  must return through the coordinator and validate its generation before acting.
- Do not hard-code marketing/build versions in Swift or a checked-in Info.plist.
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode build settings
  are authoritative and generate the application Info.plist.
- Subagents editing in parallel must own disjoint files according to the work
  packages in the implementation specification. One agent integrates; another
  independently reviews the integrated diff.

## Validation

Run a no-sign build after every integrated production change:

```sh
xcodebuild build -project DockPriority.xcodeproj -scheme DockPriority \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Run unit tests for policy or adapter changes:

```sh
xcodebuild test -project DockPriority.xcodeproj -scheme DockPriority \
  -destination 'platform=macOS' -only-testing:DockPriorityTests \
  CODE_SIGNING_ALLOWED=NO
```

Before a release, also run the UI suite in a signed local environment, complete
the physical dual-display matrix in `docs/IMPLEMENTATION_SPEC.md`, inspect the
archive, and verify version, bundle identifier, signature, notarization, ZIP,
and SHA-256 checksum.
