// artemis-rgb — control Cosmic Byte Artemis (Holtek 04D9:A1CE) lighting on macOS.
// Protocol reverse engineered from ARTEMISSetup_HV412 (Windows app, hidapi based):
//   commands are 8-byte feature reports on the vendor interface (usage page 0xFF01).
//   0x08 SetLEDType  [08 type brightness speed direction colorIdx bl0 bl1]
//   0x88 GetLEDType  [88 00 00 00 00 55 AA 00] -> get feature reply
//   0x30 SetPalette  [30 00 00 00 00 55 AA 00] + 64-byte output report (7 x RGB)
//   0xB0 GetPalette  [B0 00 00 00 00 55 AA 00] -> 64-byte input report
// Never sends 0x0F (bootloader) or 0x13 (recovery).
import Foundation
import IOKit.hid

let VID = 0x04D9, PID = 0xA1CE, USAGE_PAGE = 0xFF01

let effects = ["static", "breathing", "wave", "induction-darken", "marquee", "ripple",
               "induction-brighten", "neon", "marquee-colorful", "raining", "marquee-circle", "spotlight"]

func die(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

func openDevice() -> IOHIDDevice {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID,
                                        kIOHIDPrimaryUsagePageKey: USAGE_PAGE] as CFDictionary)
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = set.first else {
        die("Artemis keyboard (04D9:A1CE) not found. Is it plugged in?")
    }
    let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess { die(String(format: "Could not open keyboard (0x%08x)", r)) }
    return dev
}

let dev = openDevice()
var inputBuf = [UInt8](repeating: 0, count: 64)
var lastInput: [UInt8]? = nil
let inputCB: IOHIDReportCallback = { _, _, _, _, _, report, len in
    lastInput = Array(UnsafeBufferPointer(start: report, count: len))
}
IOHIDDeviceRegisterInputReportCallback(dev, &inputBuf, 64, inputCB, nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

func setFeature(_ b: [UInt8]) {
    precondition(b.count == 8 && b[0] != 0x0F && b[0] != 0x13)
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0, b, 8)
    if r != kIOReturnSuccess { die(String(format: "SetFeature %02X failed (0x%08x)", b[0], r)) }
    usleep(20_000)
}
func getFeature() -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 8); var len = CFIndex(8)
    let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0, &buf, &len)
    if r != kIOReturnSuccess { die(String(format: "GetFeature failed (0x%08x)", r)) }
    return Array(buf.prefix(len))
}
func writeOutput(_ data: [UInt8]) {
    var b = data + [UInt8](repeating: 0, count: max(0, 64 - data.count))
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, &b, 64)
    if r != kIOReturnSuccess { die(String(format: "Output write failed (0x%08x)", r)) }
    usleep(20_000)
}
func readInput(timeout: Double = 1.0) -> [UInt8]? {
    lastInput = nil
    let end = Date().addingTimeInterval(timeout)
    while lastInput == nil && Date() < end { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
    return lastInput
}

func getLED() -> [UInt8] {
    setFeature([0x88, 0, 0, 0, 0, 0x55, 0xAA, 0])
    let r = getFeature()           // [88 type bright speed dir color bl0 bl1]
    return Array(r.dropFirst())
}
func getPalette() -> [UInt8]? {
    setFeature([0xB0, 0, 0, 0, 0, 0x55, 0xAA, 0])
    _ = getFeature()
    guard let d = readInput(), d.count >= 21 else { return nil }
    return Array(d.prefix(21))
}
func setPalette(_ p: [UInt8]) {
    setFeature([0x30, 0, 0, 0, 0, 0x55, 0xAA, 0])
    writeOutput(p)
    _ = getFeature()
}
func setLED(_ v: [UInt8]) {  // type bright speed dir color bl0 bl1
    setFeature([0x08] + v)
    _ = getFeature()
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func describe(_ l: [UInt8]) -> String {
    let t = Int(l[0])
    let name = t < effects.count ? effects[t] : (0x33...0x37).contains(t) ? "user-\(t - 0x32)" : "unknown(\(t))"
    let color = l[4] < 7 ? "palette slot \(l[4])" : "rainbow"
    return "effect=\(name) brightness=\(Int((Double(l[1]) * 5 / 63).rounded()))/5 (raw \(l[1])) speed=\(l[2]) direction=\(l[3] == 0 ? "right" : "left") colour=\(color)"
}
func parseHex(_ s: String) -> [UInt8] {
    var h = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { die("Colour must be hex like ff0000 or #f00") }
    // Keyboard palette channels are 6-bit (0-63).
    return [v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF].map { UInt8((Double($0) * 63 / 255).rounded()) }
}
let named: [String: String] = ["red": "ff0000", "green": "00ff00", "blue": "0000ff", "white": "ffffff",
    "yellow": "ffff00", "cyan": "00ffff", "magenta": "ff00ff", "purple": "8000ff", "orange": "ff6000", "pink": "ff4080"]

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let cmd = args.first ?? "status"

switch cmd {
case "status":
    let l = getLED()
    print("LED raw:  \(hex(l))\n\(describe(l))")
    if let p = getPalette() {
        print("Palette:")
        func up(_ x: UInt8) -> Int { Int((Double(min(x, 63)) * 255 / 63).rounded()) }
        for i in 0..<7 { print(String(format: "  slot %d  #%02X%02X%02X", i, up(p[i*3]), up(p[i*3+1]), up(p[i*3+2]))) }
    } else { print("Palette: no reply") }

case "color", "colour", "set":
    // artemis-rgb color <hex|name|rainbow> [--effect static] [--brightness 0-5] [--speed 1-5] [--direction left|right]
    guard args.count >= 2 else { die("usage: artemis-rgb color <ff0000|red|rainbow> [--effect NAME] [--brightness 0-5] [--speed 1-5] [--direction left|right]") }
    var cur = getLED()
    if cur.count < 7 { die("Unexpected reply from keyboard: \(hex(cur))") }
    let c = args[1].lowercased()
    if c == "rainbow" {
        cur[4] = 7
    } else {
        let rgb = parseHex(named[c] ?? c)
        var pal = getPalette() ?? [UInt8](repeating: 0xFF, count: 21)
        pal[0] = rgb[0]; pal[1] = rgb[1]; pal[2] = rgb[2]
        setPalette(pal)
        cur[4] = 0
    }
    if let e = opt("--effect") {
        guard let i = effects.firstIndex(of: e.lowercased()) else { die("effects: " + effects.joined(separator: ", ")) }
        cur[0] = UInt8(i)
    } else if cur[0] >= 0x33 { cur[0] = 0 }   // user-defined pictures ignore colour; fall back to static
    if let b = opt("--brightness"), let v = Int(b), (0...5).contains(v) { cur[1] = UInt8((Double(v) * 63 / 5).rounded()) }
    if let s = opt("--speed"), let v = Int(s), (1...5).contains(v) { cur[2] = UInt8(v) }
    if let d = opt("--direction") { cur[3] = d == "left" ? 1 : 0 }
    setLED(Array(cur.prefix(7)))
    print("Set: \(describe(getLED()))")

case "effects":
    print(effects.joined(separator: "\n"))

default:
    print("""
    artemis-rgb — Cosmic Byte Artemis lighting control
      status                         show current lighting + palette
      color <hex|name|rainbow> [--effect NAME] [--brightness 0-5] [--speed 1-5] [--direction left|right]
      effects                        list effect names
    """)
}
