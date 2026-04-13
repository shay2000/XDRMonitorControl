# Handoff: XDRMonitorControl (MonitorControlXDR)

This document summarizes the changes made in this working session, the user-reported issues we debugged, and how they were resolved.

## What Changed

### Branding and Naming
- Renamed the app branding to **XDRMonitorControl** across the repo (README and UI strings).
- Updated README author/attribution from `@shayprasad` to `@shay2000`.
- Updated bundle identifiers to:
  - `com.shay2000.XDRMonitorControl`
  - `com.shay2000.XDRMonitorControlHelper`

Primary files:
- `README.md`
- `MonitorControl.xcodeproj/project.pbxproj`
- `MonitorControl/Info.plist`
- `MonitorControlHelper/Info.plist`

### App Icon Refresh
- Updated the app icon to a brighter “sun / XDR brightness” feel.
- Fixed the AppIcon asset catalog warnings by ensuring every icon PNG matches the exact pixel dimensions Xcode expects.
- Updated the README/social image to show the new icon.

Primary files:
- `MonitorControl/Assets.xcassets/AppIcon.appiconset/*`
- `.github/Icon-cropped.png`
- `README.md`

### Build/Distribution Improvements
- Updated the build script to consistently output `build/XDRMonitorControl.app`.
- Added robust handling for environments with **no valid Developer ID / Apple Development code signing identity**:
  - If a signing identity exists, prefer a properly signed build.
  - Otherwise, fall back to **ad-hoc signing** for local running/testing.
- Improved the copy/sign process to avoid macOS bundle metadata issues after copying:
  - Uses `ditto --norsrc` where appropriate.
  - Strips extended attributes recursively (xattrs) that can break app validity.

Primary file:
- `build/build.sh`

### Accessibility Prompt/Behavior Improvements
- Updated the accessibility permission prompt copy to reference the **actual app name** dynamically and guide users to remove/re-add the app if it was already enabled for a different build.

Primary file:
- `MonitorControl/Support/MediaKeyTapManager.swift`

## Issues Reported and How They Were Solved

### 1) “Accessibility is enabled but I still get the error”

Root cause:
- This machine has **no valid code signing identities** available, so builds are **ad-hoc signed**.
- On macOS, Accessibility trust can behave unexpectedly across rebuilds/copies when the app’s identity changes (common with ad-hoc signed bundles). Users often need to remove and re-add the exact app bundle they are running.

Fixes:
- Ensured bundle identifiers are correct and stable (`com.shay2000.*`) in `project.pbxproj`.
- Updated `MediaKeyTapManager.acquirePrivileges()` to:
  - Use the real app name in the alert.
  - Provide explicit guidance to remove/re-add the app in Accessibility.
- Ensured the actual runnable app is the one in `build/XDRMonitorControl.app` (not an older copy elsewhere).

Verification steps:
- Remove any prior Accessibility entry for the app.
- Add the exact `build/XDRMonitorControl.app` bundle.
- Quit/relaunch that same app bundle.

### 2) “Double-clicking the app does nothing”

There were two overlapping reasons:

1. The app is an **LSUIElement menu bar app**, so double-clicking will not open a normal window. The UI appears in the menu bar.

2. The app was **launching and immediately dying** due to Sparkle library validation on ad-hoc signed builds:
   - macOS logs showed Library Validation rejecting `Sparkle.framework` because the host process and the framework mapping did not satisfy AMFI/library validation requirements for that ad-hoc signed bundle.

Root cause:
- Debug already had an entitlements file that disables library validation, but Release did not.
- Release configuration was missing `CODE_SIGN_ENTITLEMENTS`, so the ad-hoc signed Release build didn’t carry `com.apple.security.cs.disable-library-validation`.

Fix:
- Added `CODE_SIGN_ENTITLEMENTS = MonitorControl/MonitorControlDebug.entitlements` to the Release build configuration in `MonitorControl.xcodeproj/project.pbxproj`.
- Updated build/sign steps so the final app bundle is signed (even ad-hoc) with entitlements applied.

How we validated:
- Confirmed the built app includes `com.apple.security.cs.disable-library-validation = true` via `codesign -d --entitlements :-`.
- Verified bundle integrity via `codesign --verify --deep --strict`.
- Launched with `open -n build/XDRMonitorControl.app` and confirmed it stays running.

## Operational Notes

### Ad-hoc Signing Caveat
If you rebuild often on a machine with no signing identities:
- The app remains ad-hoc signed.
- Accessibility permission may need to be removed/re-added after rebuilds, and you must add the **exact** app bundle you are running.

### Where the Build Output Goes
- The build script produces: `build/XDRMonitorControl.app`

## Files Modified in This Session (Tracked)
- `.github/Icon-cropped.png`
- `MonitorControl.xcodeproj/project.pbxproj`
- `MonitorControl/Assets.xcassets/AppIcon.appiconset/*`
- `MonitorControl/Enums/PrefKey.swift`
- `MonitorControl/Info.plist`
- `MonitorControl/Model/AppleDisplay.swift`
- `MonitorControl/Model/Display.swift`
- `MonitorControl/Support/AppDelegate.swift`
- `MonitorControl/Support/MediaKeyTapManager.swift`
- `MonitorControl/Support/MenuHandler.swift`
- `MonitorControl/Support/SliderHandler.swift`
- `MonitorControlHelper/Info.plist`
- `README.md`
- `build/build.sh`

## Files Not Intended for Commit
- `build/DerivedData/`
- `build/DerivedDataSigned/`
- `build/XDRMonitorControl.app/`
- `.vscode/`

---

## Session: XDR/HDR force-brightness engine (branch `claude/hdr-xdr-monitor-control-xFD6X`)

This session ported the core "force-XDR" mechanism out of
[BrightIntosh](https://github.com/niklasr22/BrightIntosh) and wired it into
MonitorControl so that the existing `xdrEnabled` preference actually drives
the display above 100% brightness. Prior to this, the fork had XDR
*detection* and *preferences* infrastructure but no engine to activate
extended brightness.

### What Changed

#### New: `MonitorControl/Support/XDRBrightness.swift`
A single, self-contained Swift file (~420 lines) that ports BrightIntosh's
mechanism. All new types are prefixed `XDR*` / `xdr*` so nothing collides
with existing MonitorControl symbols. Contents:

- **Device support** — `xdrSupportedDevices`, `xdrSdr600nitsDevices`,
  `xdrExternalDisplays`, `xdrGetModelIdentifier()`,
  `xdrIsBuiltInDeviceSupported()`, `xdrGetDeviceMaxBrightness()`
  (returns `1.535` on M3+, `1.59` otherwise), `xdrGetEligibleScreens()`.
- **Metal overlay** — `XDRMetalOverlay: MTKView` renders a 1×1 px
  `rgba16Float` clear-colour in `extendedLinearSRGB` with component values
  above 1.0. Its backing `CAMetalLayer` has
  `wantsExtendedDynamicRangeContent = true`. This is the signal that tells
  macOS "HDR content is on screen" and keeps the display in XDR mode.
- **Overlay window** — `XDROverlayWindow: NSWindow` +
  `XDROverlayWindowController: NSWindowController` pin the MTKView into a
  transparent, mouse-ignoring, screen-saver-level corner of every XDR screen.
- **Gamma LUT multiplier** — `XDRGammaTable` snapshots the display's
  current gamma table via `CGGetDisplayTransferByTable` and reapplies it
  multiplied by a factor up to `xdrGetDeviceMaxBrightness()` via
  `CGSetDisplayTransferByTable`.
- **Orchestration** — `XDRGammaTechnique` manages per-display overlay
  controllers and gamma tables. `XDRBrightnessController.shared` is the
  `@MainActor` singleton the rest of the app talks to. Public API:
  `enable()`, `disable()`, `brightness` getter/setter,
  `setBrightness(_:)`, `onlyOnBuiltIn`, `handleScreenParametersChanged()`,
  `handleScreensDidWake()`.

#### Modified: `MonitorControl/Model/AppleDisplay.swift`
- `setDirectBrightness(_:transient:)` now splits the input: values ≤ 1.0
  go to `DisplayServicesSetBrightness` as before; values > 1.0 pin
  `DisplayServices` at 1.0 and route the headroom through
  `XDRBrightnessController.shared.setBrightness(value)`. This avoids the
  display service clamping at 1.0 while the gamma LUT provides the extra
  ~600 nits of headroom.
- `disableXDR()` now also calls the new `disableXDRController()` helper,
  which tears down the shared controller only when no *other* Apple
  display still has `xdrEnabled` set.
- New extension methods: `enableXDR()` and `disableXDRController()`
  (both `@MainActor`).

#### Modified: `MonitorControl/Support/AppDelegate.swift`
- `displayReconfigured()` forwards to
  `XDRBrightnessController.shared.handleScreenParametersChanged()` so the
  overlay window and gamma table follow screens as they hotplug / move.
- `soberNow(dispatchedSleepID:)` forwards to
  `XDRBrightnessController.shared.handleScreensDidWake()` so the gamma
  multiplier is reapplied after macOS resets the LUT on wake.

#### Modified: `MonitorControl.xcodeproj/project.pbxproj`
- Registered `XDRBrightness.swift` in:
  - `PBXBuildFile` section
  - `PBXFileReference` section
  - The `Support` `PBXGroup` children list
  - The main target's `PBXSourcesBuildPhase` (`56754EA71D9A4016007BCDC5`)

### How It Works at Runtime
1. On app launch, `AppleDisplay.detectXDRCapability()` (unchanged) probes
   each built-in display with `DisplayServicesSetBrightness(id, 1.01)`
   and flips `isXDRCapable` when the value sticks.
2. When the user enables XDR for a display, `AppleDisplay.enableXDR()`
   calls `XDRBrightnessController.shared.enable()`, which:
   a. Snapshots each eligible screen's gamma LUT.
   b. Opens a 1×1 px transparent `XDROverlayWindow` at the top-left
      corner of each screen, hosting an `XDRMetalOverlay` that renders
      EDR clear-colour at ~5 fps.
   c. Applies `brightnessFactor` (default 1.0) to the LUT.
3. When the user moves the brightness slider above 1.0,
   `setDirectBrightness(_:)` calls
   `XDRBrightnessController.shared.setBrightness(value)`, which
   multiplies the snapshotted LUT by `value` and reinstalls it.
4. On wake / reconfigure, the forwarded notifications reinstall the
   overlay windows and LUTs (macOS resets LUTs across sleep/wake cycles).

### Known Risks / Follow-ups
- **GPLv3 vs MIT licence mismatch.** The ported code originates from
  BrightIntosh, which is GPLv3. The file header preserves attribution,
  but the repository is MIT-licensed. The licence question needs to be
  resolved before this branch can be released.
- **Not yet verified on real XDR hardware** from this branch.
- **`detectXDRCapability()` side effect.** The existing detection step
  momentarily sets brightness to `1.01`, which can visibly flash on a
  display that is already below full brightness. Pre-existing, unchanged.
- **Heat / battery.** The extended LUT drives panels above their rated
  SDR brightness. Prolonged use will increase temperature and shorten
  battery life.
- **Colour accuracy.** Because the engine multiplies the gamma LUT, any
  calibration loaded via ColorSync will be scaled linearly while XDR is
  active. Disabling XDR restores the original LUT via
  `CGDisplayRestoreColorSyncSettings()`.

### Files Modified in This Session
- `MonitorControl/Support/XDRBrightness.swift` (new)
- `MonitorControl/Model/AppleDisplay.swift`
- `MonitorControl/Support/AppDelegate.swift`
- `MonitorControl.xcodeproj/project.pbxproj`
- `README.md` (top-of-file branch warning)
- `CLAUDE.md` (new, records branch development context)
- `HANDOFF.md` (this section)

### Companion Branch
- `shay2000/brightintosh---removing-iap-merging-with-monitor-control`
  branch `claude/hdr-xdr-monitor-control-xFD6X` holds the same engine
  isolated as a standalone `HDRCore/` Swift module, stripped of
  BrightIntosh's IAP / trial / settings UI.

