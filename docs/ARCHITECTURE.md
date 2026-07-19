# Architecture

DockPriority separates system integration from display-selection policy so the
priority rule can be tested without real displays, Accessibility permission, or
timers.

```text
System display / sleep / unlock notifications
                     │
                     ▼
       SystemDisplayInventory ──► DisplaySnapshot[]
                     │
                     ▼
      DockPriorityCoordinator (@MainActor)
       │ priority store    │ temporary selection
       │ watchdog          │ protection state
       ▼                   ▼
UserDefaults store    Dock locator / relocator
                              │
                              ▼
                    Public AX and CGEvent APIs
```

## Display identity and priority

The app persists an ordered `StoredPriorityState`, not a runtime display ID.
It prefers a non-zero EDID vendor/product/physical-serial tuple and falls back
to a CoreGraphics display UUID. Identical EDID tuples visible at the same time
are treated as a collision and fall back to UUIDs. A runtime display ID, name,
or connection order is never used as a persistent key.

Newly detected displays are appended. The normal target is the first remembered
display that is active. The priority order is the only durable user preference;
there are no profiles, default anchors, or DockAnchor preference migration.

## Reconciliation

`DockPriorityCoordinator` is the sole policy owner and runs on the main actor.
It serializes changes with a generation number, cancels stale work, and permits
only one relocation at a time. Reconciliation:

1. Reads active displays and merges them into persistent priority state.
2. Clears a temporary target when the observed event is a configuration,
   sleep/wake, or unlock change.
3. Chooses an active temporary target, otherwise the highest-priority active
   display.
4. When Protection is active (or for a user-requested one-shot move), locates
   the Dock and relocates it only when needed or when its location is unknown.
5. Verifies the resulting location. Failures update status but never rewrite
   the priority list or discard a valid temporary target.

Protection starts a five-second watchdog with a 0.5-second tolerance. Stopping
Protection stops the watchdog and event suppression, but display notifications
still update the list and clear invalid temporary state. Explicit temporary and
Return to Priority actions each make one relocation attempt while stopped.

## System boundaries and privacy

`SystemDisplayInventory` uses CoreGraphics, AppKit, and workspace notifications
to discover active displays and report changes. `AccessibilityDockLocator` reads
the Dock window with the public Accessibility API. `CGEventDockRelocator` uses
public CoreGraphics mouse events and restores the cursor on success, failure,
or cancellation. No private frameworks, Dock termination, AppleScript, or shell
relocation path is used.

The sole persisted value is `displayPriority.state.v1` in DockPriority's own
UserDefaults domain. Temporary targets, Dock location, runtime IDs, and
Protection state are process-local. Identifiers and display names are not sent
to a service.
