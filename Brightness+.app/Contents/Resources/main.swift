// Brightness+ — brightness keys and sliders for every screen, the way the built-in display works.
//  • Built-in display: left to macOS (keys pass straight through).
//  • Monitors that accept DDC/CI: real backlight control over the cable.
//  • Screens that don't (TVs, AirPlay and virtual displays): a dimming layer over the picture.
// The brightness keys act on whichever screen the pointer is on, with an Apple-style on-screen indicator.

import AppKit
import SwiftUI
import IOKit
import ServiceManagement
import ApplicationServices
import CoreGraphics

// MARK: - Private IOKit DDC calls (Apple silicon)

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                        _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

struct AVEntry {
    let service: CFTypeRef
    let vendor: Int?
    let product: Int?
    let name: String?
}

/// Walks the IO registry and returns each external display's AV service, paired with the
/// product details of the framebuffer that precedes it.
func findExternalAVServices() -> [AVEntry] {
    var result: [AVEntry] = []
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    var iter = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else {
        return []
    }
    defer { IOObjectRelease(iter) }
    var lastAttrs: [String: Any]? = nil
    while true {
        let entry = IOIteratorNext(iter)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        var nameBuf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &nameBuf)
        let name = String(cString: nameBuf)
        if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
            if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                lastAttrs = attrs
            }
        } else if name == "DCPAVServiceProxy" {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            let pa = lastAttrs?["ProductAttributes"] as? [String: Any]
            result.append(AVEntry(service: av,
                                  vendor: pa?["LegacyManufacturerID"] as? Int,
                                  product: pa?["ProductID"] as? Int,
                                  name: pa?["ProductName"] as? String))
            lastAttrs = nil
        }
    }
    return result
}

/// Talks DDC/CI to one monitor. All I2C traffic happens on a private serial queue;
/// rapid changes (dragging a slider, holding a key) are coalesced so only the latest value is sent.
final class DDC {
    let service: CFTypeRef
    private let queue = DispatchQueue(label: "BrightnessPlus.ddc")
    private let lock = NSLock()
    private var pending: UInt16?
    private var busy = false

    init(service: CFTypeRef) { self.service = service }

    func setBrightness(_ value: UInt16) {
        lock.lock()
        pending = value
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { self.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let v = pending else { busy = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            _ = write(vcp: 0x10, value: v)
        }
    }

    func readBrightness(_ done: @escaping ((current: Double, max: Double)?) -> Void) {
        queue.async {
            let r = self.read(vcp: 0x10)
            DispatchQueue.main.async { done(r.map { (Double($0.current), Double($0.max)) }) }
        }
    }

    @discardableResult
    private func write(vcp: UInt8, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        var chk: UInt8 = 0x6E ^ 0x51
        for i in 0..<5 { chk ^= packet[i] }
        packet[5] = chk
        var ok = false
        for _ in 0..<2 {
            usleep(10_000)
            if IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
        }
        return ok
    }

    private func read(vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        for _ in 0..<4 {
            var request: [UInt8] = [0x82, 0x01, vcp, 0]
            var chk: UInt8 = 0x6E
            for i in 0..<3 { chk ^= request[i] }
            request[3] = chk
            usleep(10_000)
            guard IOAVServiceWriteI2C(service, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { continue }
            let maxV = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let cur = UInt16(reply[8]) << 8 | UInt16(reply[9])
            if maxV > 0 && cur <= maxV { return (cur, maxV) }
        }
        return nil
    }
}

// MARK: - Built-in display (DisplayServices, loaded at runtime)

final class BuiltInBrightness {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32
    private var getter: Getter?
    private var setter: Setter?

    init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let g = dlsym(h, "DisplayServicesGetBrightness") { getter = unsafeBitCast(g, to: Getter.self) }
            if let s = dlsym(h, "DisplayServicesSetBrightness") { setter = unsafeBitCast(s, to: Setter.self) }
        }
    }

    func get(_ d: CGDirectDisplayID) -> Double? {
        guard let getter else { return nil }
        var v: Float = 0
        return getter(d, &v) == 0 ? Double(v) : nil
    }

    func set(_ d: CGDirectDisplayID, _ v: Double) { _ = setter?(d, Float(v)) }
}

// MARK: - Dimming layer for screens that can't take brightness commands

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

final class DimOverlays {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    /// The darkest the layer goes, so the picture never disappears completely.
    static let maxDim: Double = 0.9

    func set(_ d: CGDirectDisplayID, level: Double) {
        let alpha = CGFloat((1 - level) * DimOverlays.maxDim)
        guard let screen = NSScreen.screens.first(where: { $0.displayID == d }) else {
            windows[d]?.orderOut(nil)
            return
        }
        if alpha < 0.005 {
            windows[d]?.orderOut(nil)
            return
        }
        let w = windows[d] ?? makeWindow()
        windows[d] = w
        w.setFrame(screen.frame, display: false)
        w.alphaValue = alpha
        w.orderFrontRegardless()
    }

    func keepOnly(_ ids: Set<CGDirectDisplayID>) {
        for (d, w) in windows where !ids.contains(d) {
            w.orderOut(nil)
            windows[d] = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return w
    }
}

// MARK: - On-screen indicator (like the system brightness HUD)

final class HUDState: ObservableObject {
    @Published var level: Double = 1
    @Published var name: String = ""
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SegmentBar: View {
    let level: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<16, id: \.self) { i in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.22))
                        Rectangle().fill(Color.white)
                            .frame(width: g.size.width * CGFloat(min(1, max(0, level * 16 - Double(i)))))
                    }
                }
            }
        }
    }
}

struct HUDView: View {
    @ObservedObject var state: HUDState
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: state.level <= 0.001 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 100, weight: .regular))
                .frame(height: 130)
            SegmentBar(level: state.level)
                .frame(height: 10)
            Text(state.name)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 270, height: 270)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.name) brightness \(Int((state.level * 100).rounded())) percent")
    }
}

final class HUD {
    private var panel: NSPanel?
    private let state = HUDState()
    private var hideWork: DispatchWorkItem?
    private var generation = 0
    private let size = NSSize(width: 270, height: 270)

    func show(level: Double, name: String, on screen: NSScreen) {
        state.level = level
        state.name = name
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.animationBehavior = .none
            // Above the dimming layer so the indicator always stays bright and readable.
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: HUDView(state: state))
            panel = p
        }
        guard let p = panel else { return }
        let f = screen.frame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.14,
                          width: size.width, height: size.height), display: true)
        generation += 1
        let gen = generation
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak p] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.45
                p?.animator().alphaValue = 0
            }, completionHandler: {
                if self?.generation == gen { p?.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

// MARK: - Model

enum DisplayKind { case builtIn, ddc, dim }

final class DisplayItem: ObservableObject, Identifiable {
    let id: String
    let name: String
    let kind: DisplayKind
    let isTV: Bool
    var ddc: DDC?
    var ddcMax: Double = 100
    var displayIDs: [CGDirectDisplayID] = []
    @Published var level: Double

    init(id: String, name: String, kind: DisplayKind, isTV: Bool, level: Double) {
        self.id = id; self.name = name; self.kind = kind; self.isTV = isTV; self.level = level
    }

    var symbol: String {
        switch kind {
        case .builtIn: return "laptopcomputer"
        case .ddc: return "display"
        case .dim: return isTV ? "tv" : "display"
        }
    }

    var detail: String {
        switch kind {
        case .builtIn: return "Built-in display"
        case .ddc: return "Adjusts the monitor’s backlight"
        case .dim: return "Dims the picture — this screen doesn’t accept brightness commands"
        }
    }
}

/// Keeps Brightness+ running in the background: starts it at login and restarts it if it ever stops unexpectedly.
enum BackgroundHelper {
    static let label = "local.shane.BrightnessPlus"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isOn: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("KeepAlive")
    }

    static func turnOn() {
        let launcher = Bundle.main.bundlePath + "/Contents/MacOS/launch"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [launcher, "--background"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
        }
        // Register it with launchd now. The copy launchd starts sees this one running and steps aside.
        DispatchQueue.global().async {
            launchctl(["bootout", "gui/\(getuid())/\(label)"])
            for _ in 0..<3 {
                if launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) == 0 { break }
                usleep(500_000)
            }
        }
    }

    static func turnOff() {
        try? FileManager.default.removeItem(at: plistURL)
        // Unregistering doesn't stop this process: launchd only manages the copy it started itself.
        DispatchQueue.global().async { launchctl(["remove", label]) }
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

final class BrightnessModel: ObservableObject {
    @Published var items: [DisplayItem] = []
    @Published var keysAllowed = AXIsProcessTrusted()
    @Published var keepRunning = BackgroundHelper.isOn

    let overlays = DimOverlays()
    let hud = HUD()
    let builtIn = BuiltInBrightness()
    private let defaults = UserDefaults.standard

    var preferredHeight: CGFloat {
        CGFloat(220 + max(items.count, 1) * 112 + (keysAllowed ? 0 : 140))
    }

    private func savedLevel(_ key: String) -> Double? {
        defaults.object(forKey: "level." + key) as? Double
    }

    static func isSony(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("sony") || n.contains("bravia")
    }

    func refresh() {
        let avs = findExternalAVServices()
        var usedAV = Set<Int>()
        var built: [DisplayItem] = []
        func existingOrNew(_ key: String, _ name: String, _ kind: DisplayKind, _ isTV: Bool) -> DisplayItem {
            if let e = built.first(where: { $0.id == key }) { return e }
            let item: DisplayItem
            if let old = items.first(where: { $0.id == key && $0.kind == kind }) {
                old.displayIDs = []
                item = old
            } else {
                item = DisplayItem(id: key, name: name, kind: kind, isTV: isTV, level: savedLevel(key) ?? 1)
            }
            built.append(item)
            return item
        }

        var unmatched: [(DisplayItem, CGDirectDisplayID)] = []
        for screen in NSScreen.screens {
            guard let did = screen.displayID else { continue }
            let name = screen.localizedName
            if CGDisplayIsBuiltin(did) != 0 {
                let item = existingOrNew("builtin", "Built-in Display", .builtIn, false)
                item.displayIDs.append(did)
            } else if BrightnessModel.isSony(name) {
                let item = existingOrNew("sony-tv", "Sony TV", .dim, true)
                item.displayIDs.append(did)
            } else {
                let vendor = Int(CGDisplayVendorNumber(did)), model = Int(CGDisplayModelNumber(did))
                let serial = Int(CGDisplaySerialNumber(did))
                let key = "ext-\(vendor)-\(model)-\(serial)"
                if let idx = avs.indices.first(where: { !usedAV.contains($0) && avs[$0].vendor == vendor && avs[$0].product == model }) {
                    usedAV.insert(idx)
                    let item = existingOrNew(key, name, .ddc, false)
                    if item.ddc == nil { item.ddc = DDC(service: avs[idx].service) }
                    item.displayIDs.append(did)
                } else {
                    let item = existingOrNew(key, name, .dim, false)
                    item.displayIDs.append(did)
                    unmatched.append((item, did))
                }
            }
        }

        // One monitor and one unclaimed DDC connection left over: they belong together.
        let freeAV = avs.indices.filter { !usedAV.contains($0) }
        if freeAV.count == 1, unmatched.count == 1 {
            let (old, did) = unmatched[0]
            let ddcItem = DisplayItem(id: old.id + "-ddc", name: old.name, kind: .ddc, isTV: false,
                                      level: savedLevel(old.id + "-ddc") ?? 1)
            if let prev = items.first(where: { $0.id == ddcItem.id }) { prev.displayIDs = [did]; replace(&built, old, prev) }
            else { ddcItem.ddc = DDC(service: avs[freeAV[0]].service); ddcItem.displayIDs = [did]; replace(&built, old, ddcItem) }
        }

        // Built-in first, then monitors, then TVs.
        built.sort { order($0) < order($1) }
        let isNew = Set(built.map { ObjectIdentifier($0) }).subtracting(items.map { ObjectIdentifier($0) })
        items = built

        var dimIDs = Set<CGDirectDisplayID>()
        for item in items {
            switch item.kind {
            case .builtIn:
                if let d = item.displayIDs.first, let v = builtIn.get(d) { item.level = v }
            case .ddc:
                if isNew.contains(ObjectIdentifier(item)) {
                    item.ddc?.readBrightness { [weak item] r in
                        guard let item, let r else { return }
                        item.ddcMax = r.max
                        item.level = r.current / r.max
                    }
                }
            case .dim:
                for d in item.displayIDs { dimIDs.insert(d); overlays.set(d, level: item.level) }
            }
        }
        overlays.keepOnly(dimIDs)
    }

    private func replace(_ list: inout [DisplayItem], _ old: DisplayItem, _ new: DisplayItem) {
        if let i = list.firstIndex(where: { $0 === old }) { list[i] = new }
    }

    private func order(_ item: DisplayItem) -> Int {
        switch item.kind {
        case .builtIn: return 0
        case .ddc: return 1
        case .dim: return item.isTV ? 3 : 2
        }
    }

    func refreshBuiltInLevel() {
        for item in items where item.kind == .builtIn {
            if let d = item.displayIDs.first, let v = builtIn.get(d), abs(v - item.level) > 0.001 { item.level = v }
        }
    }

    func set(_ item: DisplayItem, _ value: Double, hudOn screen: NSScreen? = nil) {
        let v = min(1, max(0, value))
        item.level = v
        defaults.set(v, forKey: "level." + item.id)
        switch item.kind {
        case .builtIn:
            for d in item.displayIDs { builtIn.set(d, v) }
        case .ddc:
            item.ddc?.setBrightness(UInt16((v * item.ddcMax).rounded()))
        case .dim:
            for d in item.displayIDs { overlays.set(d, level: v) }
        }
        if let screen { hud.show(level: v, name: item.name, on: screen) }
    }

    /// Called for a brightness key press. Returns true when Brightness+ handled it
    /// (pointer on an external screen); false lets macOS handle it (built-in display).
    func step(up: Bool, fine: Bool) -> Bool {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) ?? NSScreen.main,
              let did = screen.displayID,
              let item = items.first(where: { $0.displayIDs.contains(did) }),
              item.kind != .builtIn else { return false }
        let size = fine ? 1.0 / 64 : 1.0 / 16
        var v = item.level + (up ? size : -size)
        v = (v / size).rounded() * size
        set(item, v, hudOn: screen)
        return true
    }

    func pointerOnExternal() -> Bool {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }),
              let did = screen.displayID,
              let item = items.first(where: { $0.displayIDs.contains(did) }) else { return false }
        return item.kind != .builtIn
    }

    func setKeepRunning(_ on: Bool) {
        if on { BackgroundHelper.turnOn() } else { BackgroundHelper.turnOff() }
        keepRunning = on
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Brightness keys

final class KeyTap {
    var tap: CFMachPort?
    let model: BrightnessModel
    private var lastStep: (time: TimeInterval, sysDefined: Bool) = (0, false)

    init(model: BrightnessModel) { self.model = model }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = (CGEventMask(1) << 14)
            | (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keyTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    /// Returns true to swallow the event.
    func handle(up: Bool, isDown: Bool, flags: CGEventFlags, sysDefined: Bool) -> Bool {
        if !isDown { return model.pointerOnExternal() }
        let now = ProcessInfo.processInfo.systemUptime
        // Some keyboards send the same press twice (as a media key and as a key code): count it once.
        if lastStep.sysDefined != sysDefined && now - lastStep.time < 0.05 {
            return model.pointerOnExternal()
        }
        lastStep = (now, sysDefined)
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        return model.step(up: up, fine: fine)
    }
}

let keyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type.rawValue == 14 {
        // NX_SYSDEFINED: media / special keys.
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let data1 = ns.data1
        let code = (data1 & 0xFFFF0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        if code == 2 || code == 3 { // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
            if me.handle(up: code == 2, isDown: state == 0x0A, flags: event.flags, sysDefined: true) { return nil }
        }
    } else if type == .keyDown || type == .keyUp {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        if kc == 144 || kc == 145 { // brightness up / down key codes
            if me.handle(up: kc == 144, isDown: type == .keyDown, flags: event.flags, sysDefined: false) { return nil }
        }
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Window

struct DisplayRow: View {
    @ObservedObject var item: DisplayItem
    let model: BrightnessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: item.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.weight(.semibold))
                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("\(Int((item.level * 100).rounded()))%")
                    .font(.title3.monospacedDigit().weight(.medium))
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.min.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { item.level }, set: { model.set(item, $0) }), in: 0...1) {
                    Text("\(item.name) brightness")
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
            }
            .font(.title3)
        }
        .padding(.vertical, 6)
    }
}

struct SettingsView: View {
    @ObservedObject var model: BrightnessModel

    var body: some View {
        Form {
            Section {
                if model.items.isEmpty {
                    Text("No displays found.").foregroundStyle(.secondary)
                }
                ForEach(model.items) { item in
                    DisplayRow(item: item, model: model)
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("Press the brightness keys to adjust the screen your pointer is on. Hold Option and Shift for smaller steps.")
                    .foregroundStyle(.secondary)
            }

            if !model.keysAllowed {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Allow the brightness keys", systemImage: "keyboard")
                            .font(.headline)
                        Text("Turn on Brightness+ in Privacy & Security › Accessibility so the brightness keys can control your other screens.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Toggle("Keep working when closed", isOn: Binding(get: { model.keepRunning }, set: { model.setKeepRunning($0) }))
            } footer: {
                Text("The brightness keys and dimming keep working after you close or quit Brightness+, and start automatically when you log in.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: model.preferredHeight)
    }
}

// MARK: - App

let launchedInBackground = CommandLine.arguments.contains("--background")
let showWindowNote = Notification.Name("local.shane.BrightnessPlus.showWindow")

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = BrightnessModel()
    lazy var keyTap = KeyTap(model: model)
    var window: NSWindow?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy runs. A second copy hands over to the first (showing its window if asked) and leaves.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.shane.BrightnessPlus")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        if !others.isEmpty {
            if !launchedInBackground {
                DistributedNotificationCenter.default().postNotificationName(showWindowNote, object: nil, userInfo: nil, deliverImmediately: true)
            }
            exit(0)
        }

        buildMenu()
        model.refresh()

        DistributedNotificationCenter.default().addObserver(forName: showWindowNote, object: nil, queue: .main) { [weak self] _ in
            self?.showWindow()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Give macOS a moment to finish arranging screens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.model.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.model.refresh() }
        }

        if launchedInBackground {
            if AXIsProcessTrusted() { keyTap.start() }
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(opts) { keyTap.start() }
        }

        // Keep working in the background by default (also replaces the older login setting).
        if !UserDefaults.standard.bool(forKey: "didSetUpBackground") {
            UserDefaults.standard.set(true, forKey: "didSetUpBackground")
            model.setKeepRunning(true)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.model.keysAllowed { self.model.keysAllowed = trusted }
            if trusted && self.keyTap.tap == nil { self.keyTap.start() }
            if self.window?.isVisible == true { self.model.refreshBuiltInLevel() }
        }

        if launchedInBackground { NSApp.setActivationPolicy(.accessory) } else { showWindow() }
    }

    /// Quitting only hides Brightness+ while "Keep working when closed" is on.
    /// Logging out, restarting and shutting down still quit it normally.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason)
        if model.keepRunning && reason == nil {
            goToBackground()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { self.goToBackground() }
    }

    private func goToBackground() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "Brightness+"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        model.refreshBuiltInLevel()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Brightness+", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Brightness+", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Brightness+", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(launchedInBackground ? .accessory : .regular)
app.run()
