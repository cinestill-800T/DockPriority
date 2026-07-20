# DockPriority

DockPriority is a macOS menu-bar utility that keeps the Dock on the highest
priority display currently reported as active by macOS. It is an independent
MIT-licensed derivative of [DockAnchor](https://github.com/bwya77/DockAnchor).

## What it does

- Stores one global, ordered list of displays. There are no profiles and no
  profile switching.
- Chooses the first available display in that order; it falls back when a
  display disconnects and returns when a higher-priority display becomes
  available again.
- Lets you select any connected display with **Show Temporarily On** in one
  click without changing the saved order. **Return to Priority** clears that
  temporary selection.
- Clears a temporary selection after a display configuration change (including
  resolution, refresh rate, HDR, scaling, arrangement, mirroring, main-display,
  sleep, wake, or unlock) and resumes the normal priority rule.
- While Protection is active, responds to display notifications and checks the
  Dock every five seconds to recover from missed notifications.

DockPriority relies exclusively on public macOS APIs. It does not use private
frameworks, kill the Dock, run shell commands, or use AppleScript to move it.
See [the architecture](docs/ARCHITECTURE.md) and the complete
[implementation specification](docs/IMPLEMENTATION_SPEC.md).

## How it differs from DockAnchor

DockPriority is an independent derivative, not a drop-in replacement or an
official DockAnchor release. The projects share the goal of keeping the Dock
predictable on multi-display Macs, but make different trade-offs.

| Area | DockAnchor | DockPriority |
| --- | --- | --- |
| Normal rule | Keeps the Dock anchored to a selected display. | Uses one explicit, ordered display priority: the first display that macOS reports as available wins. |
| When the preferred display returns | Falls back when the anchor is removed. | Automatically returns to the highest-priority available display after a higher-priority display reconnects or macOS reports a display change. |
| Display-mode changes | General real-time display detection. | Resumes the priority rule after reported resolution, refresh-rate, HDR, scaling, arrangement, mirroring, main-display, sleep, wake, or unlock changes. |
| Temporary override | Profile-based configuration is available. | A one-click **Show Temporarily On** override does not alter the saved order and returns to priority mode on the next detectable display change, on request, or after restart. |
| Configuration model | Profiles, including automatic profile switching. | Deliberately no profiles: one global order is always visible and editable. |
| Recovery | Event-driven protection. | Display notifications plus a five-second verification pass help recover when an expected notification is missed. |

For the workflow this project targets—such as a fixed 27-inch work display
with a 38-inch secondary display, a monitor that is sometimes switched through
a KVM, or frequent HDR/resolution changes—the priority model avoids having to
reselect an anchor whenever the preferred display becomes available again.
The temporary override is the escape hatch when macOS cannot observe a KVM or
monitor-power change accurately.

This is not a claim that DockPriority is universally better. DockAnchor offers
features DockPriority intentionally does not, including profiles, automatic
profile switching, visual monitor layout, appearance settings, and start-at-
login controls. DockPriority also has a narrower platform target (macOS 15.4
or later). Both applications require Accessibility permission and can act only
on the display state macOS exposes.

## Requirements

- macOS 15.4 or later
- Xcode 16.4 or later for source builds
- Accessibility permission for Dock inspection, mouse-event monitoring, and
  Dock relocation

On first relocation attempt, grant DockPriority under **System Settings →
Privacy & Security → Accessibility**. Priority editing and display discovery
remain usable without this permission; Dock protection and one-shot relocation
do not.

## KVM and display-switching limitation

DockPriority can react only to the display state macOS reports. If a KVM keeps
the monitor logically connected while it shows another computer, macOS may not
emit a configuration change. In that situation use **Show Temporarily On** to
select a connected display; the saved priority is unchanged. The temporary
choice remains in effect until a detectable display configuration change,
explicit **Return to Priority**, or app restart.

## Build from source

```sh
xcodebuild build \
  -project DockPriority.xcodeproj \
  -scheme DockPriority \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

To run manually, open `DockPriority.xcodeproj` in Xcode and sign it with your
local development identity. A stable, locally signed build is recommended for
Accessibility testing.

Run the unit suite with:

```sh
xcodebuild test \
  -project DockPriority.xcodeproj \
  -scheme DockPriority \
  -destination 'platform=macOS' \
  -only-testing:DockPriorityTests \
  CODE_SIGNING_ALLOWED=NO
```

## Downloadable release and Gatekeeper

The initial GitHub release is a universal (`arm64` + `x86_64`) ZIP containing a
versioned directory with a Hardened Runtime, **ad-hoc-signed**
`DockPriority.app`, `LICENSE`, `NOTICE.md`, and `README.md`, plus a portable
SHA-256 checksum. It is not Developer ID signed or Apple-notarized. macOS
Gatekeeper may therefore warn or block it; inspect the source, verify the
checksum, and decide whether to allow it in System Settings before launching.
Hardened Runtime is an exploit-mitigation setting; neither it nor an ad-hoc
signature proves publisher identity or notarization.

Build the same release artifact locally:

```sh
scripts/package-release.sh --output build/package
```

The command writes a ZIP and matching basename-only `.sha256` file beneath the
supplied directory. It verifies the bundle identifier, version, architectures,
absence of coverage instrumentation, signature/Runtime flags, package layout,
license files, and a clean extraction before returning success. Verify a moved
or downloaded pair again with:

```sh
scripts/package-release.sh --verify \
  DockPriority-0.1.1-macos.zip \
  DockPriority-0.1.1-macos.zip.sha256
```

## Privacy

DockPriority operates locally. Display identifiers and priority order are kept
in this app's UserDefaults only; no DockAnchor preferences are read or
migrated. It does not collect or transmit display data. The optional update
check contacts the public project release endpoint.

## Testing

Automated coverage and a physical-display acceptance checklist are documented
in [docs/MANUAL_TEST_CHECKLIST.md](docs/MANUAL_TEST_CHECKLIST.md). The physical
tests must be performed on a signed build with two or more displays; they are
not substituted by CI.

## License and attribution

DockPriority is distributed under the [MIT License](LICENSE). It includes
required upstream attribution in [NOTICE.md](NOTICE.md). DockPriority is not an
official DockAnchor release and is not endorsed by its upstream author.
