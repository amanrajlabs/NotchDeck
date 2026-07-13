// Zero-dependency test runner (Command Line Tools ship no XCTest/Testing).
// Run: swift run NotchDeckChecks
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import NotchDeckKit

var failures = 0
var checks = 0

@MainActor
func expect(
    _ condition: Bool, _ message: String,
    file: String = #fileID, line: Int = #line
) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL \(file):\(line) — \(message)")
    }
}

// MARK: - NotchGeometry

let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

let notched = NotchGeometry.notchRect(
    screenFrame: screen, safeTopInset: 32, auxTopLeftWidth: 653, auxTopRightWidth: 653
)
expect(notched == CGRect(x: 653, y: 950, width: 206, height: 32), "notched screen uses aux areas: \(notched)")

let simulated = NotchGeometry.notchRect(
    screenFrame: screen, safeTopInset: 0, auxTopLeftWidth: nil, auxTopRightWidth: nil
)
expect(simulated.size == NotchGeometry.simulatedNotchSize, "notchless gets simulated size")
expect(simulated.midX == screen.midX && simulated.maxY == screen.maxY, "simulated notch centered at top")

let notch = CGRect(x: 653, y: 950, width: 206, height: 32)
let frame = NotchGeometry.panelFrame(notch: notch, expandedSize: CGSize(width: 640, height: 300))
expect(frame.midX == notch.midX && frame.maxY == notch.maxY, "panel frame centered/top-aligned")
expect(frame.size == CGSize(width: 640, height: 300), "panel frame takes expanded size")

let wide = NotchGeometry.panelFrame(notch: CGRect(x: 0, y: 950, width: 800, height: 32), expandedSize: CGSize(width: 640, height: 300))
expect(wide.width == 800, "panel frame never narrower than notch")

// MARK: - MediaStateMapper

let spotifyInfo = MediaStateMapper.trackInfo(
    from: [
        "Player State": "Playing", "Name": "Weightless", "Artist": "Marconi Union",
        "Album": "Ambient Transmissions", "Duration": NSNumber(value: 480_000),
    ],
    player: .spotify
)
expect(spotifyInfo?.title == "Weightless", "spotify title")
expect(spotifyInfo?.duration == 480, "spotify ms→s duration")
expect(spotifyInfo?.isPlaying == true, "spotify playing")
expect(spotifyInfo?.player == .spotify, "spotify player id")

let musicInfo = MediaStateMapper.trackInfo(
    from: [
        "Player State": "Paused", "Name": "Karma Police", "Artist": "Radiohead",
        "Total Time": NSNumber(value: 261_000),
    ],
    player: .music
)
expect(musicInfo?.isPlaying == false, "music paused")
expect(musicInfo?.duration == 261, "music Total Time ms→s")

expect(MediaStateMapper.trackInfo(from: ["Player State": "Stopped"], player: .spotify) == nil, "stopped → nil")
expect(MediaStateMapper.trackInfo(from: ["Name": "x"], player: .music) == nil, "missing state → nil")

// MARK: - BTBatteryScanner

let airpods = BTBatteryScanner.parse(properties: [
    "DeviceName": "Aman's AirPods Pro",
    "BatteryPercentLeft": 80, "BatteryPercentRight": 75, "BatteryPercentCase": 60,
    "DeviceAddress": "aa-bb-cc-dd-ee-ff",
])
expect(airpods?.kind == .airpods, "airpods kind")
expect(airpods?.batteries == [
    BatterySlot(label: "L", percent: 80),
    BatterySlot(label: "R", percent: 75),
    BatterySlot(label: "Case", percent: 60),
], "airpods three slots")
expect(airpods?.id == "aa-bb-cc-dd-ee-ff", "airpods id from address")
expect(airpods?.minPercent == 60, "airpods min percent")

let mouse = BTBatteryScanner.parse(properties: ["Product": "Magic Mouse", "BatteryPercent": 45])
expect(mouse?.kind == .mouse, "mouse kind")
expect(mouse?.batteries == [BatterySlot(label: "", percent: 45)], "mouse single slot")

expect(BTBatteryScanner.parse(properties: ["DeviceName": "Some Speaker"]) == nil, "no battery keys → nil")
expect(BTBatteryScanner.parse(properties: ["BatteryPercent": 50]) == nil, "no name → nil")
expect(BTBatteryScanner.parse(properties: ["DeviceName": "Weird", "BatteryPercent": 255]) == nil, "out-of-range percent → nil")
expect(
    BTBatteryScanner.parse(properties: ["DeviceName": "DualSense Wireless Controller", "BatteryPercent": 90])?.kind == .controller,
    "controller kind"
)

// MARK: - MeetingDetector

expect(
    MeetingDetector.url(in: [nil, "Join here: https://us02web.zoom.us/j/1234567890?pwd=abc123 see you"])?
        .absoluteString == "https://us02web.zoom.us/j/1234567890?pwd=abc123",
    "zoom link extracted"
)
expect(
    MeetingDetector.url(in: ["https://meet.google.com/abc-defg-hij"])?.absoluteString == "https://meet.google.com/abc-defg-hij",
    "meet link extracted"
)
expect(
    MeetingDetector.url(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=%7b%7d"])?
        .absoluteString.hasPrefix("https://teams.microsoft.com/l/meetup-join/") == true,
    "teams link extracted"
)
expect(
    MeetingDetector.url(in: ["Location: https://company.webex.com/meet/aman"])?
        .absoluteString == "https://company.webex.com/meet/aman",
    "webex link extracted"
)
expect(
    MeetingDetector.url(in: ["https://meet.google.com/aaa-bbbb-ccc", "https://us02web.zoom.us/j/999"])?.host == "meet.google.com",
    "first field wins"
)
expect(MeetingDetector.url(in: ["Lunch with Sam", "https://example.com/page", nil]) == nil, "non-meeting URLs ignored")

// MARK: - DropActionRunner (real file ops in a temp dir)

let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("NotchDeckChecks-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

@MainActor func makeFile(_ name: String, contents: String = "hello") -> URL {
    let url = dir.appendingPathComponent(name)
    try! contents.data(using: .utf8)!.write(to: url)
    return url
}

@MainActor func makePNG(_ name: String) -> URL {
    let url = dir.appendingPathComponent(name)
    let ctx = CGContext(
        data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    expect(CGImageDestinationFinalize(dest), "fixture png written")
    return url
}

do {
    let file = makeFile("note.txt")
    let archive = try DropActionRunner.zip([file])
    expect(archive.lastPathComponent == "note.zip", "single-file zip name")
    let extractDir = dir.appendingPathComponent("extracted")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", archive.path, extractDir.path]
    try ditto.run()
    ditto.waitUntilExit()
    let roundTripped = try String(contentsOf: extractDir.appendingPathComponent("note.txt"), encoding: .utf8)
    expect(roundTripped == "hello", "zip round-trips contents")

    let multi = try DropActionRunner.zip([makeFile("a.txt"), makeFile("b.txt")])
    expect(multi.lastPathComponent == "Archive.zip", "multi-file zip named Archive.zip")

    let jpeg = try DropActionRunner.convert(makePNG("pixel.png"), to: .jpeg)
    expect(jpeg.pathExtension == "jpg", "converted extension")
    if let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil) {
        expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier, "converted type is jpeg")
    } else {
        expect(false, "converted jpeg unreadable")
    }

    var convertThrew = false
    do { _ = try DropActionRunner.convert(makeFile("plain.txt"), to: .png) } catch { convertThrew = true }
    expect(convertThrew, "convert rejects non-image")

    let moving = makeFile("moving.txt")
    let destDir = dir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    try DropActionRunner.move([moving], to: destDir)
    expect(!FileManager.default.fileExists(atPath: moving.path), "move removes source")
    expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("moving.txt").path), "move lands in dest")

    let copying = makeFile("copy.txt")
    try DropActionRunner.copy([copying], to: dir) // collides with itself
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("copy 2.txt").path), "copy avoids collision")
    expect(FileManager.default.fileExists(atPath: copying.path), "copy keeps original")
} catch {
    expect(false, "drop action checks threw: \(error)")
}


// MARK: - SystemNowPlayingAccumulator (adapter stream protocol)

var acc = SystemNowPlayingAccumulator()
expect(acc.ingest(line: "not json") == nil, "garbage line ignored")
expect(acc.ingest(line: #"{"type":"other","payload":{}}"#) == nil, "non-data line ignored")

let full = #"{"type":"data","diff":false,"payload":{"title":"Lofi Mix","artist":"ChilledCow","album":"","duration":3600.5,"elapsedTime":12.25,"playing":true,"bundleIdentifier":"com.google.Chrome"}}"#
if let result = acc.ingest(line: full), let state = result {
    expect(state.title == "Lofi Mix", "full payload title")
    expect(state.playing == true, "full payload playing")
    expect(state.bundleID == "com.google.Chrome", "full payload bundle")
    expect(state.duration == 3600.5 && state.elapsed == 12.25, "full payload times")
} else {
    expect(false, "full payload not parsed")
}

let diff = #"{"type":"data","diff":true,"payload":{"playing":false,"elapsedTime":80}}"#
if let result = acc.ingest(line: diff), let state = result {
    expect(state.title == "Lofi Mix", "diff keeps title")
    expect(state.playing == false, "diff updates playing")
    expect(state.elapsed == 80, "diff updates elapsed")
} else {
    expect(false, "diff payload not parsed")
}

let cleared = #"{"type":"data","diff":false,"payload":{}}"#
if let result = acc.ingest(line: cleared) {
    expect(result == nil, "empty payload means nothing playing")
} else {
    expect(false, "empty payload should still be a data line")
}

// MARK: - WeatherParser

let weatherJSON = """
{"current":{"temperature_2m":21.4,"weather_code":61},
 "daily":{"temperature_2m_max":[27.1],"temperature_2m_min":[17.9]}}
""".data(using: .utf8)!
if let w = WeatherParser.parse(data: weatherJSON) {
    expect(w.tempC == 21.4 && w.code == 61, "weather current parsed")
    expect(w.hiC == 27.1 && w.loC == 17.9, "weather daily hi/lo parsed")
} else {
    expect(false, "weather payload not parsed")
}
expect(WeatherParser.parse(data: Data("{}".utf8)) == nil, "weather empty JSON → nil")
expect(WeatherParser.symbol(for: 0) == "sun.max.fill", "WMO clear symbol")
expect(WeatherParser.symbol(for: 63) == "cloud.rain.fill", "WMO rain symbol")
expect(WeatherParser.symbol(for: 73) == "cloud.snow.fill", "WMO snow symbol")
expect(WeatherParser.symbol(for: 96) == "cloud.bolt.rain.fill", "WMO storm symbol")

// MARK: - SystemStatsMath

let prev = CPUSample(user: 100, system: 50, idle: 800, nice: 0)
let curr = CPUSample(user: 130, system: 70, idle: 850, nice: 0)
expect(SystemStatsMath.cpuUsage(previous: prev, current: curr) == 0.5, "cpu 50% busy")
expect(SystemStatsMath.cpuUsage(previous: prev, current: prev) == 0, "cpu no delta → 0")

// MARK: - PomodoroEngine

var pomodoro = PomodoroEngine(workMinutes: 25, breakMinutes: 5)
let t0 = Date(timeIntervalSince1970: 1_000_000)
expect(!pomodoro.isRunning, "pomodoro starts stopped")
expect(pomodoro.remaining(at: t0) == 25 * 60, "full work duration when stopped")
pomodoro.start(at: t0)
expect(pomodoro.remaining(at: t0.addingTimeInterval(60)) == 24 * 60, "counts down while running")
pomodoro.pause(at: t0.addingTimeInterval(60))
expect(pomodoro.remaining(at: t0.addingTimeInterval(600)) == 24 * 60, "paused holds remaining")
pomodoro.start(at: t0.addingTimeInterval(600))
expect(pomodoro.advanceIfElapsed(at: t0.addingTimeInterval(700)) == nil, "no phase change early")
let workEnd = t0.addingTimeInterval(600 + 24 * 60)
expect(pomodoro.advanceIfElapsed(at: workEnd) == .work, "work phase completes")
expect(pomodoro.phase == .shortBreak, "break follows work")
expect(pomodoro.completedSessions == 1, "session counted")
expect(pomodoro.remaining(at: workEnd) == 5 * 60, "break duration fresh")
expect(pomodoro.advanceIfElapsed(at: workEnd.addingTimeInterval(5 * 60)) == .shortBreak, "break completes")
expect(pomodoro.phase == .work, "work follows break")
pomodoro.reset()
expect(!pomodoro.isRunning && pomodoro.phase == .work, "reset returns to idle work")

// MARK: - Summary

if failures == 0 {
    print("OK — \(checks) checks passed")
    exit(0)
} else {
    print("\(failures)/\(checks) checks FAILED")
    exit(1)
}
