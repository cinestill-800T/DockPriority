# Changelog

All notable changes to DockPriority are documented here.

## [0.1.0] - 2026-07-20

### Added

- One persistent global display-priority list, with automatic fallback and
  restoration when active displays change.
- One-click, non-persistent temporary display selection and Return to Priority
  actions in the main window and menu bar.
- Event-driven reconciliation plus a five-second Protection watchdog.
- Public-API-only display, Accessibility, and event-relocation implementation.
- Unit/UI coverage, physical-display acceptance checklist, reproducible
  universal ad-hoc release packaging, and GitHub Actions CI.

### Distribution

- The `v0.1.0` artifact is universal but ad-hoc signed. It is not Developer ID
  signed or notarized; see the README before launching it.
