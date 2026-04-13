//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  XDRBrightness.swift
//
//  HDR/XDR brightening mechanism ported from BrightIntosh
//  (https://github.com/niklasr22/BrightIntosh — GPLv3, by Niklas Rousset).
//
//  This file is a single-file, self-contained port of BrightIntosh's core
//  "force-XDR" mechanism. Its goal is to push a Mac's built-in XDR display
//  (and compatible external XDR displays) into the full extended-dynamic-range
//  brightness range at any time — not just during HDR video playback.
//
//  The mechanism has two parts:
//
//  1. An invisible 1×1 px Metal overlay rendered with `rgba16Float` +
//     `extendedLinearSRGB` + `wantsExtendedDynamicRangeContent = true`.
//     macOS sees "there is HDR content on screen" and keeps the display
//     in its extended brightness mode.
//
//  2. A gamma-LUT multiplier applied via `CGSetDisplayTransferByTable`
//     that scales the full output curve by up to 1.59×, effectively giving
//     a brightness slider above 100%.
//
//  Consumers talk to `XDRBrightnessController.shared`. `AppleDisplay`
//  drives it on/off when the `xdrEnabled` pref is toggled.

import Cocoa
import Foundation
import IOKit
import MetalKit
import os.log

// MARK: - Device support

/// Built-in Mac models that ship with an XDR-capable display.
let xdrSupportedDevices: [String] = [
  "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
  "Mac14,6", "Mac14,10", "Mac14,5", "Mac14,9",
  "Mac15,7", "Mac15,9", "Mac15,11", "Mac15,6", "Mac15,8", "Mac15,10", "Mac15,3",
  "Mac16,1", "Mac16,6", "Mac16,8", "Mac16,7", "Mac16,5",
  "Mac17,2", "Mac17,6", "Mac17,8", "Mac17,7", "Mac17,9",
]

/// "SDR 600 nits" variants (M3+) whose max gamma multiplier is 1.535
/// instead of 1.59.
let xdrSdr600nitsDevices: [String] = [
  "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
  "Mac16,1", "Mac16,6", "Mac16,8", "Mac16,7", "Mac16,5",
  "Mac17,2", "Mac17,6", "Mac17,8", "Mac17,7", "Mac17,9",
]

let xdrExternalDisplays: [String] = ["Pro Display XDR", "Studio Display XDR"]

func xdrGetModelIdentifier() -> String? {
  let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
  defer { IOObjectRelease(service) }
  if let modelData = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? Data {
    return String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
  }
  return nil
}

func xdrIsBuiltInDeviceSupported() -> Bool {
  guard let device = xdrGetModelIdentifier() else { return false }
  return xdrSupportedDevices.contains(device)
}

/// Max gamma multiplier for this device (1.535 on M3+, 1.59 otherwise).
func xdrGetDeviceMaxBrightness() -> Float {
  guard let device = xdrGetModelIdentifier() else { return 1.59 }
  return xdrSdr600nitsDevices.contains(device) ? 1.535 : 1.59
}

func xdrIsBuiltInScreen(screen: NSScreen) -> Bool {
  guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
    return false
  }
  return CGDisplayIsBuiltin(screenNumber) != 0
}

/// Enumerates currently-attached XDR-capable screens.
@MainActor
func xdrGetEligibleScreens(onlyBuiltIn: Bool = false) -> [NSScreen] {
  var screens: [NSScreen] = []
  for screen in NSScreen.screens {
    let isBuiltInXDR = xdrIsBuiltInScreen(screen: screen) && xdrIsBuiltInDeviceSupported()
    let isExternalXDR = xdrExternalDisplays.contains(screen.localizedName) && !onlyBuiltIn
    if isBuiltInXDR || isExternalXDR {
      screens.append(screen)
    }
  }
  return screens
}

private extension NSScreen {
  var xdrDisplayId: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
  }
}

// MARK: - Metal overlay (the EDR signal)

/// MTKView that renders a clear color with components > 1.0 into an
/// extended-dynamic-range drawable. This is the "HDR content is on screen"
/// signal that macOS needs to keep the display in XDR mode.
final class XDRMetalOverlay: MTKView, MTKViewDelegate {
  private let hdrColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
  private var commandQueue: MTLCommandQueue?

  init(frame: CGRect, multiplyCompositing: Bool = false) {
    super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
    guard let device else { fatalError("XDRMetalOverlay: no Metal device") }

    autoResizeDrawable = false
    drawableSize = CGSize(width: 1, height: 1)
    commandQueue = device.makeCommandQueue()
    if commandQueue == nil { fatalError("XDRMetalOverlay: no Metal command queue") }

    delegate = self
    colorPixelFormat = .rgba16Float
    colorspace = hdrColorSpace
    clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0)
    preferredFramesPerSecond = 5

    if let layer = self.layer as? CAMetalLayer {
      layer.wantsExtendedDynamicRangeContent = true
      layer.isOpaque = false
      layer.pixelFormat = .rgba16Float
      if multiplyCompositing {
        layer.compositingFilter = "multiply"
      }
    }
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func screenUpdate(screen: NSScreen) {
    let maxEdrValue = screen.maximumExtendedDynamicRangeColorComponentValue
    let maxRenderedEdrValue = screen.maximumReferenceExtendedDynamicRangeColorComponentValue
    let factor = max(maxEdrValue / max(maxRenderedEdrValue, 1.0) - 1.0, 1.0)
    clearColor = MTLClearColorMake(factor, factor, factor, 1.0)
  }

  func draw(in view: MTKView) {
    guard let commandQueue = commandQueue,
          let renderPassDescriptor = view.currentRenderPassDescriptor,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
    encoder.endEncoding()
    if let drawable = view.currentDrawable { commandBuffer.present(drawable) }
    commandBuffer.commit()
  }

  func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}
}

// MARK: - Overlay window hosting the MTKView

final class XDROverlayWindow: NSWindow {
  var overlay: XDRMetalOverlay?
  let fullsize: Bool

  init(fullsize: Bool = false) {
    self.fullsize = fullsize
    let rect = NSRect(x: 0, y: 0, width: 1, height: 1)
    if fullsize {
      super.init(contentRect: rect, styleMask: [.fullSizeContentView, .borderless], backing: .buffered, defer: false)
      if #available(macOS 13.0, *) {
        collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .canJoinAllApplications, .fullScreenAuxiliary]
      } else {
        collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
      }
      level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    } else {
      super.init(contentRect: rect, styleMask: [], backing: BackingStoreType(rawValue: 0)!, defer: false)
      collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
      level = .screenSaver
      canHide = false
      isMovableByWindowBackground = true
      alphaValue = 1
    }
    isOpaque = false
    hasShadow = false
    backgroundColor = NSColor.clear
    ignoresMouseEvents = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
  }

  func addMetalOverlay(screen: NSScreen) {
    overlay = XDRMetalOverlay(frame: frame, multiplyCompositing: self.fullsize)
    overlay?.screenUpdate(screen: screen)
    overlay?.autoresizingMask = [.width, .height]
    contentView = overlay
  }
}

final class XDROverlayWindowController: NSWindowController, NSWindowDelegate {
  let fullsize: Bool
  let screen: NSScreen

  init(screen: NSScreen, fullsize: Bool = false) {
    self.screen = screen
    self.fullsize = fullsize
    let win = XDROverlayWindow(fullsize: fullsize)
    super.init(window: win)
    win.delegate = self
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func open(rect: NSRect) {
    guard let window = self.window as? XDROverlayWindow else { return }
    window.setFrame(rect, display: true)
    if !fullsize { reposition(screen: screen) }
    window.orderFrontRegardless()
    window.addMetalOverlay(screen: screen)
  }

  func reposition(screen: NSScreen) {
    window?.setFrameOrigin(idealPosition(screen: screen))
  }

  private func idealPosition(screen: NSScreen) -> CGPoint {
    var pos = screen.frame.origin
    pos.y += screen.frame.height - 1
    return pos
  }

  func windowDidMove(_: Notification) {
    if let window = window, window.frame.origin != idealPosition(screen: self.screen) {
      reposition(screen: self.screen)
    }
  }
}

// MARK: - Gamma LUT snapshot & multiply

final class XDRGammaTable {
  static let tableSize: UInt32 = 256
  var redTable = [CGGammaValue](repeating: 0, count: Int(tableSize))
  var greenTable = [CGGammaValue](repeating: 0, count: Int(tableSize))
  var blueTable = [CGGammaValue](repeating: 0, count: Int(tableSize))

  private init() {}

  static func snapshot(displayId: CGDirectDisplayID) -> XDRGammaTable? {
    let table = XDRGammaTable()
    var sampleCount: UInt32 = 0
    let result = CGGetDisplayTransferByTable(displayId, tableSize, &table.redTable, &table.greenTable, &table.blueTable, &sampleCount)
    return result == .success ? table : nil
  }

  func apply(displayId: CGDirectDisplayID, factor: Float = 1.0) {
    var r = redTable.map { $0 * factor }
    var g = greenTable.map { $0 * factor }
    var b = blueTable.map { $0 * factor }
    CGSetDisplayTransferByTable(displayId, XDRGammaTable.tableSize, &r, &g, &b)
  }
}

// MARK: - Technique orchestrator

@MainActor
final class XDRGammaTechnique {
  private(set) var isEnabled: Bool = false
  var brightnessFactor: Float = 1.0 {
    didSet { brightnessFactor = max(1.0, min(xdrGetDeviceMaxBrightness(), brightnessFactor)) }
  }
  var onlyOnBuiltIn: Bool = false

  private var overlayControllers: [CGDirectDisplayID: XDROverlayWindowController] = [:]
  private var gammaTables: [CGDirectDisplayID: XDRGammaTable] = [:]

  func enable() {
    xdrGetEligibleScreens(onlyBuiltIn: onlyOnBuiltIn).forEach { enableScreen(screen: $0) }
    isEnabled = true
    adjustBrightness()
  }

  func enableScreen(screen: NSScreen) {
    guard let displayId = screen.xdrDisplayId else { return }
    if gammaTables[displayId] == nil {
      gammaTables[displayId] = XDRGammaTable.snapshot(displayId: displayId)
    }
    let controller = XDROverlayWindowController(screen: screen)
    overlayControllers[displayId] = controller
    let rect = NSRect(x: screen.frame.origin.x, y: screen.frame.origin.y, width: 1, height: 1)
    controller.open(rect: rect)
  }

  func disable() {
    isEnabled = false
    overlayControllers.values.forEach { $0.window?.close() }
    overlayControllers.removeAll()
    gammaTables.removeAll()
    CGDisplayRestoreColorSyncSettings()
  }

  func adjustBrightness() {
    guard isEnabled else { return }
    for controller in overlayControllers.values {
      if let displayId = controller.screen.xdrDisplayId, let table = gammaTables[displayId] {
        table.apply(displayId: displayId, factor: brightnessFactor)
      }
    }
  }

  func screenUpdate(screens: [NSScreen]) {
    let ids = screens.compactMap { $0.xdrDisplayId }
    for displayId in overlayControllers.keys where !ids.contains(displayId) {
      overlayControllers[displayId]?.window?.close()
      gammaTables[displayId]?.apply(displayId: displayId, factor: 1.0)
      gammaTables.removeValue(forKey: displayId)
      overlayControllers.removeValue(forKey: displayId)
    }
    for screen in screens {
      guard let displayId = screen.xdrDisplayId else { continue }
      if let controller = overlayControllers[displayId] {
        controller.reposition(screen: screen)
      } else {
        enableScreen(screen: screen)
      }
    }
    adjustBrightness()
  }
}

// MARK: - Public controller

/// High-level singleton that the rest of MonitorControl talks to.
///
/// Wiring (see AppDelegate):
///   - NSApplication.didChangeScreenParametersNotification
///       -> XDRBrightnessController.shared.handleScreenParametersChanged()
///   - NSWorkspace.screensDidWakeNotification
///       -> XDRBrightnessController.shared.handleScreensDidWake()
@MainActor
final class XDRBrightnessController {
  static let shared = XDRBrightnessController()

  private let technique = XDRGammaTechnique()
  private var trackedScreens: [NSScreen] = NSScreen.screens
  private var trackedXdrScreens: [NSScreen] = []

  private init() {
    self.trackedXdrScreens = xdrGetEligibleScreens(onlyBuiltIn: technique.onlyOnBuiltIn)
  }

  var isEnabled: Bool { technique.isEnabled }

  /// Current gamma multiplier in [1.0, xdrGetDeviceMaxBrightness()].
  var brightness: Float {
    get { technique.brightnessFactor }
    set {
      technique.brightnessFactor = newValue
      technique.adjustBrightness()
    }
  }

  var onlyOnBuiltIn: Bool {
    get { technique.onlyOnBuiltIn }
    set {
      technique.onlyOnBuiltIn = newValue
      handleScreenParametersChanged()
    }
  }

  func setBrightness(_ factor: Float) { self.brightness = factor }

  func enable() {
    guard !technique.isEnabled else { return }
    technique.brightnessFactor = max(1.0, min(xdrGetDeviceMaxBrightness(), technique.brightnessFactor))
    technique.enable()
    os_log("XDRBrightnessController: enabled at factor %{public}@", type: .info, String(technique.brightnessFactor))
  }

  func disable() {
    guard technique.isEnabled else { return }
    technique.disable()
    os_log("XDRBrightnessController: disabled", type: .info)
  }

  func handleScreenParametersChanged() {
    let newScreens = NSScreen.screens
    let newXdrScreens = xdrGetEligibleScreens(onlyBuiltIn: technique.onlyOnBuiltIn)

    var changed = newScreens.count != trackedScreens.count || newXdrScreens.count != trackedXdrScreens.count
    if !changed {
      for screen in trackedScreens {
        let same = newScreens.first { $0.xdrDisplayId == screen.xdrDisplayId }
        if same?.frame.origin != screen.frame.origin {
          changed = true
          break
        }
      }
    }
    if changed {
      trackedScreens = newScreens
      trackedXdrScreens = newXdrScreens
    }
    guard technique.isEnabled else { return }
    if !newScreens.isEmpty {
      if changed {
        technique.screenUpdate(screens: trackedXdrScreens)
      } else {
        technique.adjustBrightness()
      }
    } else {
      technique.disable()
    }
  }

  func handleScreensDidWake() {
    if technique.isEnabled {
      technique.adjustBrightness()
    }
  }
}
