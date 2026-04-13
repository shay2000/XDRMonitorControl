# CLAUDE.md — XDRMonitorControl

Guidance for Claude (or any LLM agent) working in this repository.

## Repository Overview

This is a fork of [MonitorControl](https://github.com/MonitorControl/MonitorControl)
maintained by [@shay2000](https://github.com/shay2000) as **XDRMonitorControl**,
adding XDR extended-brightness support for MacBook Pro Liquid Retina XDR and
Pro Display XDR displays.

Bundle identifiers:
- App: `com.shay2000.XDRMonitorControl`
- Helper: `com.shay2000.XDRMonitorControlHelper`

## Branch Context

Development happens on branches named `claude/<topic>-xFD6X` in the
**user's own fork**: `shay2000/XDRMonitorControl` (not the upstream
`MonitorControl/MonitorControl` repo).

### Current branch: `claude/hdr-xdr-monitor-control-xFD6X`

This branch adds the **XDR/HDR force-brightness engine** ported from
[BrightIntosh](https://github.com/niklasr22/BrightIntosh) (GPLv3).

**The engine lives in a single file:** `MonitorControl/Support/XDRBrightness.swift`.
All of its symbols are prefixed `XDR*` / `xdr*` to avoid collisions with existing
MonitorControl code.

**Public entry point:** `XDRBrightnessController.shared` (a `@MainActor` singleton).

**Two-part mechanism:**
1. An invisible 1×1 px Metal overlay rendered in `rgba16Float` with
   `extendedLinearSRGB` + `wantsExtendedDynamicRangeContent = true`.
   This signals macOS that HDR content is on screen, keeping the display
   in extended-dynamic-range mode.
2. A gamma-LUT multiplier applied via `CGSetDisplayTransferByTable` that
   scales the full output curve by up to `1.59×` (`1.535×` on M3+).

**Wire-up in the rest of the app:**
- `MonitorControl/Model/AppleDisplay.swift` —
  `setDirectBrightness(_:transient:)` routes values > 1.0 through
  `XDRBrightnessController.shared.setBrightness(value)` while pinning
  `DisplayServicesSetBrightness` at 1.0. `disableXDR()` calls
  `disableXDRController()` (a new extension helper). New `enableXDR()`
  extension method.
- `MonitorControl/Support/AppDelegate.swift` —
  `displayReconfigured()` forwards to
  `XDRBrightnessController.shared.handleScreenParametersChanged()`,
  and `soberNow(dispatchedSleepID:)` forwards to
  `handleScreensDidWake()`.
- `MonitorControl.xcodeproj/project.pbxproj` — `XDRBrightness.swift` is
  registered in the `Support` PBXGroup and the main target's Sources
  build phase.

## Companion Repository

A stripped-down, reusable version of the same engine lives in
`shay2000/brightintosh---removing-iap-merging-with-monitor-control`
on branch `claude/hdr-xdr-monitor-control-xFD6X` under the
`HDRCore/` directory. That isolation removes BrightIntosh's IAP /
trial / Combine / settings-UI dependencies so the engine can be
dropped into any macOS project.

## Things to Know Before Editing

1. **Licensing.** BrightIntosh is GPLv3; this repo is MIT. The
   `XDRBrightness.swift` header preserves BrightIntosh attribution, but
   the licence mismatch is an **unresolved question** — do not ship
   this branch in a production build without resolving it.
2. **`@MainActor` isolation.** `XDRBrightnessController` is
   `@MainActor`-isolated. When calling it from non-main-actor contexts
   (e.g. `setDirectBrightness` which is called from background queues),
   use `Task { @MainActor in ... }`.
3. **Detection is separate from activation.** The display's
   `isXDRCapable` flag is set by
   `AppleDisplay.detectXDRCapability()`, which probes with
   `DisplayServicesSetBrightness(id, 1.01)`. This flag gates whether
   XDR *can* be enabled. Activation is gated by the `.xdrEnabled`
   preference.
4. **Gamma LUT resets on sleep.** macOS restores the default gamma
   table when the screens wake. The `handleScreensDidWake()` hook
   re-applies the XDR multiplier. Do not bypass this — without it, the
   XDR factor silently reverts after the first sleep cycle.
5. **The overlay window must stay on screen.** `XDROverlayWindow` is
   1×1 px, transparent, `ignoresMouseEvents = true`, and pinned to
   `NSWindow.Level.screenSaver`. If you close or hide it, macOS will
   drop the display out of XDR mode.
6. **Device list is model-specific.** `xdrSupportedDevices` and
   `xdrSdr600nitsDevices` in `XDRBrightness.swift` are model
   identifiers returned by `IOPlatformExpertDevice` (e.g.
   `"MacBookPro18,1"`). When new XDR-capable Macs ship, both lists
   must be updated.

## Build Notes

- Build output: `build/XDRMonitorControl.app`
- `build/build.sh` handles ad-hoc signing when no Developer ID is
  available.
- Release builds need
  `CODE_SIGN_ENTITLEMENTS = MonitorControl/MonitorControlDebug.entitlements`
  to carry `com.apple.security.cs.disable-library-validation`,
  otherwise Sparkle.framework fails library validation on ad-hoc
  signed bundles and the app dies silently on launch.

## Further Reading

- `HANDOFF.md` — chronological record of changes made by prior agent
  sessions, including the XDR engine integration.
- `README.md` — user-facing docs (top of file has a branch warning).
- `MonitorControl/Support/XDRBrightness.swift` header comment —
  authoritative description of the mechanism and its sources.
