import CoreGraphics
import Foundation
import ObjectiveC.runtime

/// Creates a full-resolution virtual display when no physical monitor is
/// attached, so a headless Mac is controllable at a sane resolution instead of
/// the 1024×768 fallback.
///
/// `CGVirtualDisplay` / `CGVirtualDisplayDescriptor` are PRIVATE, undocumented
/// CoreGraphics classes — there is no public SDK symbol. This is acceptable
/// here (the app is unsandboxed and not App-Store-bound) but it is implemented
/// defensively: availability is detected at runtime via the Objective-C
/// runtime, every step is guarded, and we fall back to capturing whatever
/// display exists if the private API is missing on the running OS.
final class VirtualDisplayManager {
    /// Strong references to the live virtual-display objects (Obj-C instances).
    private var display: AnyObject?

    /// True if a virtual display is currently active.
    private(set) var isActive = false

    /// Whether the private API is present on this OS build.
    static var isAvailable: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
    }

    /// True if there is no online physical display (i.e. headless).
    static var hasNoPhysicalDisplay: Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        return count == 0
    }

    /// Attempt to create a virtual display. Returns the new display ID on
    /// success, or nil if the private API is unavailable / creation failed (the
    /// caller then falls back to whatever display exists).
    @discardableResult
    func createIfNeeded(width: Int = 2560, height: Int = 1440, hiDPI: Bool = true) -> CGDirectDisplayID? {
        guard Self.isAvailable else {
            NSLog("SameDesk: CGVirtualDisplay private API unavailable — falling back to physical capture.")
            return nil
        }
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else {
            return nil
        }

        let descriptor = descriptorClass.init()
        // Best-effort KVC configuration. Property names are stable across the OS
        // versions where this API exists; if any setValue throws (it won't for
        // KVC-compliant keys) we still proceed defensively.
        descriptor.setValue("SameDesk Virtual Display", forKeyIfPresent: "name")
        descriptor.setValue(NSNumber(value: width), forKeyIfPresent: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: height), forKeyIfPresent: "maxPixelsHigh")
        // Physical size in mm (≈ 23" 16:9) — affects reported DPI only.
        descriptor.setValue(NSValue(size: NSSize(width: 510, height: 290)), forKeyIfPresent: "sizeInMillimeters")
        descriptor.setValue(NSNumber(value: 0x0610_002F), forKeyIfPresent: "vendorID")
        descriptor.setValue(NSNumber(value: 0x0000_0001), forKeyIfPresent: "productID")
        descriptor.setValue(NSNumber(value: UInt32.random(in: .min ... .max)), forKeyIfPresent: "serialNum")

        guard let display = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
            .perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)?.takeUnretainedValue() else {
            NSLog("SameDesk: failed to init CGVirtualDisplay.")
            return nil
        }

        // Build a mode (native + HiDPI scaled).
        let scale = hiDPI ? 2 : 1
        let mode = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        let initSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        typealias ModeInit = @convention(c) (AnyObject, Selector, Int, Int, Double) -> AnyObject?
        var modeObject: AnyObject?
        if let mode, let method = class_getInstanceMethod(modeClass, initSel) {
            let imp = method_getImplementation(method)
            let fn = unsafeBitCast(imp, to: ModeInit.self)
            modeObject = fn(mode, initSel, width / scale, height / scale, 60.0)
        }

        let settings = settingsClass.init()
        settings.setValue(NSNumber(value: hiDPI ? 2 : 1), forKeyIfPresent: "hiDPI")
        if let modeObject {
            settings.setValue([modeObject], forKeyIfPresent: "modes")
        }

        let applySel = NSSelectorFromString("applySettings:")
        if (display as AnyObject).responds(to: applySel) {
            _ = (display as AnyObject).perform(applySel, with: settings)
        }

        self.display = display
        self.isActive = true

        // Read back the assigned display ID.
        if let idNumber = (display as AnyObject).value(forKey: "displayID") as? NSNumber {
            return CGDirectDisplayID(idNumber.uint32Value)
        }
        return nil
    }

    func tearDown() {
        // Releasing the strong reference removes the virtual display.
        display = nil
        isActive = false
    }
}

private extension NSObject {
    /// KVC set that silently no-ops if the key is absent on this OS build,
    /// rather than raising an Obj-C exception we can't catch from Swift.
    func setValue(_ value: Any?, forKeyIfPresent key: String) {
        // `value(forKey:)` on an unknown key throws; guard by checking the
        // property/ivar exists first.
        let cls: AnyClass = type(of: self)
        let hasProperty = class_getProperty(cls, key) != nil
        let hasIvar = class_getInstanceVariable(cls, key) != nil
            || class_getInstanceVariable(cls, "_" + key) != nil
        guard hasProperty || hasIvar || responds(to: NSSelectorFromString("set" + key.capitalizedFirst + ":")) else {
            return
        }
        setValue(value, forKey: key)
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
