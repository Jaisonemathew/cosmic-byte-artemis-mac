// Artemis RGB — menu bar app for Cosmic Byte Artemis (Holtek 04D9:A1CE) lighting.
// Protocol: see ../cli/main.swift. Never sends 0x0F (bootloader) or 0x13 (recovery).
import SwiftUI
import AppKit
import IOKit.hid

// MARK: - HID protocol

final class ArtemisDevice {
    static let vid = 0x04D9, pid = 0xA1CE, usagePage = 0xFF01
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var inputBuf = [UInt8](repeating: 0, count: 64)
    fileprivate var lastInput: [UInt8]?

    init() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.vid, kIOHIDProductIDKey: Self.pid,
                                                kIOHIDPrimaryUsagePageKey: Self.usagePage] as CFDictionary)
    }

    /// Opens (or re-opens after unplug) the vendor lighting interface.
    func connect() -> Bool {
        if let d = device, IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) != nil { return true }
        device = nil
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let d = set.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d, &inputBuf, 64, { ctx, _, _, _, _, report, len in
            guard let ctx else { return }
            Unmanaged<ArtemisDevice>.fromOpaque(ctx).takeUnretainedValue().lastInput =
                Array(UnsafeBufferPointer(start: report, count: len))
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        device = d
        return true
    }

    private func setFeature(_ b: [UInt8]) -> Bool {
        precondition(b.count == 8 && b[0] != 0x0F && b[0] != 0x13)
        guard let d = device else { return false }
        let ok = IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0, b, 8) == kIOReturnSuccess
        if !ok { device = nil }
        usleep(20_000)
        return ok
    }
    private func getFeature() -> [UInt8]? {
        guard let d = device else { return nil }
        var buf = [UInt8](repeating: 0, count: 8); var len = CFIndex(8)
        guard IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 0, &buf, &len) == kIOReturnSuccess else { return nil }
        return Array(buf.prefix(len))
    }
    private func writeOutput(_ data: [UInt8]) -> Bool {
        guard let d = device else { return false }
        var b = data + [UInt8](repeating: 0, count: max(0, 64 - data.count))
        let ok = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, &b, 64) == kIOReturnSuccess
        usleep(20_000)
        return ok
    }
    private func readInput(timeout: Double = 1.0) -> [UInt8]? {
        lastInput = nil
        let end = Date().addingTimeInterval(timeout)
        while lastInput == nil && Date() < end { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
        return lastInput
    }

    /// [type, brightness 0-63, speed 1-5, direction, colourIndex, bl0, bl1]
    func getLED() -> [UInt8]? {
        guard connect(), setFeature([0x88, 0, 0, 0, 0, 0x55, 0xAA, 0]), let r = getFeature(), r.count == 8 else { return nil }
        return Array(r.dropFirst())
    }
    /// 7 × RGB, 6-bit channels (0-63)
    func getPalette() -> [UInt8]? {
        guard connect(), setFeature([0xB0, 0, 0, 0, 0, 0x55, 0xAA, 0]) else { return nil }
        _ = getFeature()
        guard let d = readInput(), d.count >= 21 else { return nil }
        return Array(d.prefix(21))
    }
    func setPalette(_ p: [UInt8]) -> Bool {
        guard connect(), setFeature([0x30, 0, 0, 0, 0, 0x55, 0xAA, 0]), writeOutput(p) else { return false }
        _ = getFeature()
        return true
    }
    func setLED(_ v: [UInt8]) -> Bool {
        guard connect(), v.count == 7, setFeature([0x08] + v) else { return false }
        _ = getFeature()
        return true
    }
}

// MARK: - Model

enum Effect: Int, CaseIterable, Identifiable {
    case staticColor, breathing, wave, inductionDarken, marquee, ripple, inductionBrighten,
         neon, marqueeColorful, raining, marqueeCircle, spotlight
    var id: Int { rawValue }
    var name: String {
        ["Static", "Breathing", "Wave", "Reactive (darken)", "Marquee", "Ripple", "Reactive (brighten)",
         "Neon", "Marquee colourful", "Raining", "Marquee circle", "Spotlight"][rawValue]
    }
    var hasSpeed: Bool { self != .staticColor }
    var hasDirection: Bool { [.wave, .marquee, .marqueeColorful, .marqueeCircle].contains(self) }
}

struct RGB: Equatable {
    var r, g, b: Double  // 0...1
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        r = n.redComponent; g = n.greenComponent; b = n.blueComponent
    }
    init(hex: UInt32) { self.init(r: Double(hex >> 16 & 0xFF) / 255, g: Double(hex >> 8 & 0xFF) / 255, b: Double(hex & 0xFF) / 255) }
    var six: [UInt8] { [r, g, b].map { UInt8((min(max($0, 0), 1) * 63).rounded()) } }
    static func fromSix(_ v: ArraySlice<UInt8>) -> RGB {
        let a = Array(v).map { Double(min($0, 63)) / 63 }
        return RGB(r: a[0], g: a[1], b: a[2])
    }
}

@MainActor
final class LightingModel: ObservableObject {
    let device = ArtemisDevice()
    @Published var connected = false
    @Published var status = "Looking for keyboard…"
    @Published var effect: Effect = .staticColor { didSet { scheduleApply() } }
    @Published var rainbow = false { didSet { scheduleApply() } }
    @Published var color = RGB(hex: 0xFF0000) { didSet { scheduleApply(colorChanged: true) } }
    @Published var brightness: Double = 5 { didSet { scheduleApply() } }   // 0-5
    @Published var speed: Double = 3 { didSet { scheduleApply() } }        // 1 slow … 5 fast (UI)
    @Published var directionLeft = false { didSet { scheduleApply() } }

    private var loading = false
    private var pendingColor = false
    private var applyTask: Task<Void, Never>?
    private var extra: [UInt8] = [0, 0]   // bl0, bl1 — preserved as the official app does
    private var palette = [UInt8](repeating: 63, count: 21)

    static let presets: [UInt32] = [0xFF0000, 0xFF6000, 0xFFD000, 0x00FF00, 0x00FFFF, 0x0060FF, 0x8000FF, 0xFF00C0, 0xFFFFFF]

    func refresh() {
        guard let led = device.getLED() else {
            connected = false; status = "Keyboard not found — plug in the Artemis"; return
        }
        loading = true
        defer { loading = false }
        if let p = device.getPalette() { palette = p }
        effect = Effect(rawValue: Int(led[0])) ?? .staticColor
        brightness = (Double(led[1]) * 5 / 63).rounded()
        speed = Double(6 - Int(min(max(led[2], 1), 5)))   // keyboard: 1 = fastest
        directionLeft = led[3] == 1
        rainbow = led[4] >= 7
        let slot = Int(min(led[4], 6))
        color = RGB.fromSix(palette[slot * 3 ..< slot * 3 + 3])
        extra = [led[5], led[6]]
        connected = true
        status = "Connected"
    }

    /// Debounced so dragging sliders / the colour wheel doesn't hammer the keyboard's onboard memory.
    private func scheduleApply(colorChanged: Bool = false) {
        guard !loading else { return }
        if colorChanged { pendingColor = true }
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    private func apply() {
        var ok = true
        if !rainbow && pendingColor {
            palette.replaceSubrange(0..<3, with: color.six)
            ok = device.setPalette(palette)
        }
        pendingColor = false
        if !rainbow, palette[0..<3] != ArraySlice(color.six) {   // ensure slot 0 holds our colour
            palette.replaceSubrange(0..<3, with: color.six)
            ok = ok && device.setPalette(palette)
        }
        let led: [UInt8] = [UInt8(effect.rawValue),
                            UInt8((brightness * 63 / 5).rounded()),
                            UInt8(6 - Int(speed)),
                            directionLeft ? 1 : 0,
                            rainbow ? 7 : 0] + extra
        ok = ok && device.setLED(led)
        connected = ok
        status = ok ? "Applied" : "Couldn't reach keyboard — is it plugged in?"
    }
}

// MARK: - UI

struct PanelView: View {
    @ObservedObject var model: LightingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "keyboard.fill").foregroundStyle(model.rainbow ? AnyShapeStyle(rainbowGradient) : AnyShapeStyle(model.color.color))
                Text("Artemis RGB").font(.headline)
                Spacer()
                Circle().fill(model.connected ? .green : .red).frame(width: 7, height: 7)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }

            // Colour
            VStack(alignment: .leading, spacing: 8) {
                Text("Colour").font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    ForEach(LightingModel.presets, id: \.self) { hex in
                        let c = RGB(hex: hex)
                        Button { model.rainbow = false; model.color = c } label: {
                            Circle().fill(c.color).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary.opacity(!model.rainbow && model.color.six == c.six ? 0.9 : 0.15),
                                                         lineWidth: !model.rainbow && model.color.six == c.six ? 2 : 1))
                        }.buttonStyle(.plain).help(String(format: "#%06X", hex))
                    }
                    Button { model.rainbow = true } label: {
                        Circle().fill(rainbowGradient).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.primary.opacity(model.rainbow ? 0.9 : 0.15), lineWidth: model.rainbow ? 2 : 1))
                    }.buttonStyle(.plain).help("Rainbow")
                }
                // Inline picker: the system ColorPicker opens NSColorPanel, which steals focus
                // and dismisses the MenuBarExtra window, so its selection never arrives.
                InlineColorPicker(color: Binding(
                    get: { model.color },
                    set: { model.rainbow = false; model.color = $0 }))
            }

            Divider()

            // Effect
            Picker("Effect", selection: $model.effect) {
                ForEach(Effect.allCases) { Text($0.name).tag($0) }
            }

            labeledSlider("Brightness", value: $model.brightness, range: 0...5,
                          low: "sun.min", high: "sun.max.fill")
            if model.effect.hasSpeed {
                labeledSlider("Speed", value: $model.speed, range: 1...5, low: "tortoise", high: "hare")
            }
            if model.effect.hasDirection {
                Picker("Direction", selection: $model.directionLeft) {
                    Image(systemName: "arrow.left").tag(true)
                    Image(systemName: "arrow.right").tag(false)
                }.pickerStyle(.segmented)
            }

            Divider()
            HStack {
                Button("Reload from keyboard") { model.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }

    private var rainbowGradient: AngularGradient {
        AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                               low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            HStack {
                Image(systemName: low).foregroundStyle(.secondary)
                Slider(value: value, in: range, step: 1)
                Image(systemName: high).foregroundStyle(.secondary)
            }
        }
    }
}

/// Hue (x) / saturation (y) pad plus a hex field, all inside the panel.
struct InlineColorPicker: View {
    // @State needs the SwiftUIMacros plugin, which the Command Line Tools swiftc lacks.
    final class HexBox: ObservableObject { @Published var text = "" }
    @Binding var color: RGB
    @StateObject private var hex = HexBox()
    @FocusState private var hexFocused: Bool
    private var hexText: String {
        get { hex.text }
        nonmutating set { hex.text = newValue }
    }

    private var hs: (h: Double, s: Double) {
        let n = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
        return (n.hueComponent, n.saturationComponent)
    }
    private var hexString: String {
        String(format: "%02X%02X%02X", Int((color.r * 255).rounded()), Int((color.g * 255).rounded()), Int((color.b * 255).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                                   startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .background(Circle().fill(color.color))
                        .shadow(radius: 1.5)
                        .frame(width: 16, height: 16)
                        .offset(x: hs.h * w - 8, y: (1 - hs.s) * h - 8)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let hue = min(max(v.location.x / w, 0), 0.999)
                    let sat = 1 - min(max(v.location.y / h, 0), 1)
                    let n = NSColor(hue: hue, saturation: sat, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
                    color = RGB(r: n.redComponent, g: n.greenComponent, b: n.blueComponent)
                })
            }
            .frame(height: 90)

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(color.color).frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
                Text("#").foregroundStyle(.secondary)
                TextField("FF0000", text: $hex.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90)
                    .focused($hexFocused)
                    .onSubmit(applyHex)
                Button("Set", action: applyHex).controlSize(.small)
            }
        }
        .onAppear { hexText = hexString }
        .onChange(of: color) { _ in if !hexFocused { hexText = hexString } }
    }

    private func applyHex() {
        var s = hexText.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { hexText = hexString; return }
        color = RGB(hex: v)
        hexText = s.uppercased()
    }
}

@main
struct ArtemisRGBApp: App {
    @StateObject private var model = LightingModel()
    var body: some Scene {
        MenuBarExtra("Artemis RGB", systemImage: "keyboard") {
            PanelView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
