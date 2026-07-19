# DockPriority 0.1.0 manual acceptance checklist

Run this checklist on a signed candidate build with Accessibility permission on
a Mac with at least two physical displays. Record macOS version, hardware/KVM,
connection types, build/version, and any deviations. CI does not replace these
tests.

## Setup

- [ ] Confirm the candidate's bundle ID is `io.github.cinestill800t.DockPriority`.
- [ ] Confirm the candidate's version/build and SHA-256 match the release asset.
- [ ] Grant Accessibility permission, launch the app, and record two or more
      connected display names and the configured priority order.
- [ ] Confirm there are no Profiles, Default Anchor, or Auto Relocate controls.

## Priority and temporary selection

- [ ] With two displays, make display A priority 1 and B priority 2. Start
      Protection; the Dock moves to A.
- [ ] Disconnect/power off A. Confirm the Dock is on B within five seconds.
- [ ] Reconnect/power on A. Confirm the Dock returns to A within five seconds
      after the display is stable.
- [ ] In both the main window and menu bar, select B with Show Temporarily On.
      Confirm the order is unchanged and Protection maintains B.
- [ ] Select Return to Priority from both surfaces. Confirm a one-time move to
      the normal target and that the temporary indication disappears.
- [ ] Reorder disconnected remembered displays, then reconnect them and confirm
      the saved order is honoured.

## Display configuration changes

With a temporary target selected, perform each applicable operation and confirm
the temporary target clears immediately and normal priority is restored while
Protection is active. Repeat at least five distinct mode changes in total.

- [ ] Resolution change (repeat at least once).
- [ ] HiDPI/scaling change.
- [ ] Refresh-rate change.
- [ ] HDR enable and disable.
- [ ] Rotation change.
- [ ] Arrangement change.
- [ ] Main-display change.
- [ ] Mirroring enable and disable, if supported.

## Power, KVM, and lifecycle

- [ ] Switch the priority display to another PC through the KVM, then switch it
      back. If macOS reports disconnection, verify normal fallback/return.
- [ ] If the KVM leaves macOS thinking the display is connected, verify that
      Show Temporarily On provides the documented manual workaround.
- [ ] Perform ten sleep/wake cycles. After each wake, confirm the correct target
      is restored after display stabilization and no crash occurs.
- [ ] Lock and unlock the screen; confirm temporary selection clears and normal
      priority resumes when applicable.
- [ ] Restart DockPriority; confirm temporary selection is not restored and the
      persistent priority is retained.
- [ ] Test cable unplug/replug and display power off/on for every display in a
      two-display setup; repeat essential fallback behavior on a three-display
      setup when available.

## Failure paths and stopped protection

- [ ] Stop Protection, then create a display configuration change. Confirm no
      automatic Dock relocation occurs.
- [ ] While stopped, choose a temporary display and Return to Priority. Confirm
      each action attempts exactly one relocation and does not start monitoring.
- [ ] Revoke Accessibility permission while running. Confirm priority editing
      and display listing remain usable and relocation shows actionable failure.
- [ ] Re-grant Accessibility permission and confirm a subsequent explicit or
      Protection action works without restarting the priority state.
- [ ] Test single-display operation, a same-model dual-display setup when
      possible, and an adapter with no physical serial. Confirm no crash.
- [ ] Restart the Dock during Protection, if safe in the test environment, and
      confirm the app reports/retries without changing saved priority.

## Sign-off

- [ ] All automated unit and UI tests passed for the exact candidate.
- [ ] Release ZIP passes `scripts/package-release.sh --verify`; the versioned
      root contains only the app, LICENSE, NOTICE, and README, with no symlinks
      or unsafe paths.
- [ ] App architecture, bundle ID/version, coverage-free executable, ad-hoc
      signature with Hardened Runtime, and portable checksum were verified.
- [ ] Any failures are linked to an issue or explicitly accepted before release.
