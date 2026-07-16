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

let nudged = NotchGeometry.notchRect(
    screenFrame: screen, safeTopInset: 32, auxTopLeftWidth: 653, auxTopRightWidth: 653,
    verticalNudge: 4
)
expect(nudged.maxY == screen.maxY, "nudge keeps rect pinned to top edge")
expect(nudged.height == 28, "positive nudge shrinks height so bottom rises: \(nudged.height)")
let overNudged = NotchGeometry.notchRect(
    screenFrame: screen, safeTopInset: 32, auxTopLeftWidth: 653, auxTopRightWidth: 653,
    verticalNudge: 100
)
expect(overNudged.height >= 8, "nudge clamps to minimum height")

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

// MARK: - UsageLedger

var ledger = UsageLedger()
let day = Date(timeIntervalSince1970: 1_752_400_000) // fixed day
ledger.record(bundleID: "com.apple.Safari", from: day, to: day.addingTimeInterval(300))
ledger.record(bundleID: "com.apple.Terminal", from: day, to: day.addingTimeInterval(100))
ledger.record(bundleID: "com.apple.Safari", from: day.addingTimeInterval(400), to: day.addingTimeInterval(500))
let slices = ledger.today(top: 5, now: day)
expect(slices.first == UsageSlice(bundleID: "com.apple.Safari", seconds: 400), "usage sorted and summed")
expect(slices.count == 2, "two apps tracked")
expect(UsageLedger.dayKey(for: day) != UsageLedger.dayKey(for: day.addingTimeInterval(86_400)), "day keys differ across days")

var midnightLedger = UsageLedger()
let nearMidnight = Calendar.current.startOfDay(for: day).addingTimeInterval(86_400 - 60)
midnightLedger.record(bundleID: "app", from: nearMidnight, to: nearMidnight.addingTimeInterval(120))
expect(midnightLedger.days.count == 2, "midnight span splits across days")
expect(midnightLedger.days[UsageLedger.dayKey(for: nearMidnight)]?["app"] == 60, "first day gets 60s")

// MARK: - NotificationRowParser

let notifPlist: [String: Any] = ["req": ["titl": "New message", "subt": "Sam", "body": "hey!"]]
let notifData = try! PropertyListSerialization.data(fromPropertyList: notifPlist, format: .binary, options: 0)
if let item = NotificationRowParser.parse(data: notifData, appID: "com.apple.MobileSMS", uuid: "AB", deliveredCocoa: 700_000_000) {
    expect(item.title == "New message" && item.subtitle == "Sam" && item.body == "hey!", "notification fields parsed")
    expect(item.appBundleID == "com.apple.MobileSMS", "notification app id")
} else {
    expect(false, "notification plist not parsed")
}
let emptyNotif = try! PropertyListSerialization.data(fromPropertyList: ["req": [String: Any]()], format: .binary, options: 0)
expect(NotificationRowParser.parse(data: emptyNotif, appID: "x", uuid: "y", deliveredCocoa: 0) == nil, "empty notification skipped")

// MARK: - TranslationResponseParser

let openAIResponse = Data(#"{"choices":[{"message":{"role":"assistant","content":"  Hola \n"}}]}"#.utf8)
expect(TranslationResponseParser.openAIText(from: openAIResponse) == "Hola", "openai content extracted+trimmed")
let ollamaResponse = Data(#"{"model":"llama3.2","message":{"role":"assistant","content":"Bonjour"}}"#.utf8)
expect(TranslationResponseParser.ollamaText(from: ollamaResponse) == "Bonjour", "ollama content extracted")
expect(TranslationResponseParser.openAIText(from: Data(#"{"error":{}}"#.utf8)) == nil, "openai error → nil")

// MARK: - GitPayloadParser

let ghJSON = Data(#"{"items":[{"title":"Fix crash","number":42,"html_url":"https://github.com/a/b/pull/42","repository_url":"https://api.github.com/repos/a/b","updated_at":"2026-07-10T10:00:00Z"}]}"#.utf8)
let ghPRs = GitPayloadParser.github(data: ghJSON, isReviewRequest: true)
expect(ghPRs.count == 1 && ghPRs[0].repo == "a/b" && ghPRs[0].isReviewRequest, "github PR parsed")
expect(ghPRs[0].updated != nil, "github date parsed")

let glJSON = Data(#"[{"title":"Add API","iid":7,"web_url":"https://gitlab.com/g/p/-/merge_requests/7","references":{"full":"g/p!7"},"updated_at":"2026-07-11T09:30:00.000Z"}]"#.utf8)
let glPRs = GitPayloadParser.gitlab(data: glJSON, isReviewRequest: false)
expect(glPRs.count == 1 && glPRs[0].repo == "g/p" && glPRs[0].provider == .gitlab, "gitlab MR parsed")

let bbJSON = Data(#"{"values":[{"title":"Hotfix","id":3,"links":{"html":{"href":"https://bitbucket.org/w/r/pull-requests/3"}},"destination":{"repository":{"full_name":"w/r"}},"updated_on":"2026-07-12T08:00:00.000000+00:00"}]}"#.utf8)
let bbPRs = GitPayloadParser.bitbucket(data: bbJSON)
expect(bbPRs.count == 1 && bbPRs[0].repo == "w/r" && bbPRs[0].provider == .bitbucket, "bitbucket PR parsed")

// MARK: - ClaudeSessionParser

let jsonlTail = """
{"type":"user","message":{"content":"hi"}}
{"type":"assistant","message":{"model":"claude-fable-5","usage":{"input_tokens":1200,"output_tokens":300,"cache_read_input_tokens":50000}}}
not json at all
{"type":"assistant","message":{"model":"claude-fable-5","usage":{"input_tokens":1500,"output_tokens":450,"cache_read_input_tokens":52000}}}
"""
let stats = ClaudeSessionParser.parse(tail: jsonlTail)
expect(stats.assistantMessages == 2, "assistant messages counted")
expect(stats.inputTokens == 1500 && stats.outputTokens == 450, "last usage wins")
expect(stats.cacheReadTokens == 52000, "cache tokens parsed")
expect(stats.model == "claude-fable-5", "model parsed")
expect(ClaudeSessionParser.projectName(fromDirName: "-Users-aman-Desktop-NotchDeck") == "NotchDeck", "project name from dir")

// MARK: - DayProgress

let workday = Calendar.current.startOfDay(for: Date())
expect(DayProgress.fraction(now: workday.addingTimeInterval(8 * 3600), startHour: 9, endHour: 18) == nil, "before workday → nil")
expect(DayProgress.fraction(now: workday.addingTimeInterval(13.5 * 3600), startHour: 9, endHour: 18) == 0.5, "midday → 0.5")
expect(DayProgress.fraction(now: workday.addingTimeInterval(19 * 3600), startHour: 9, endHour: 18) == 1, "after workday → 1")
expect(DayProgress.fraction(now: workday, startHour: 18, endHour: 9) == nil, "inverted hours → nil")

// MARK: - Claude preview extraction

let previewTail = """
{"type":"assistant","message":{"model":"claude-fable-5","content":[{"type":"text","text":"  First reply  "}],"usage":{"input_tokens":10,"output_tokens":5}}}
{"type":"assistant","message":{"model":"claude-fable-5","content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"Fixed the bug in the parser."}],"usage":{"input_tokens":20,"output_tokens":9}}}
"""
let previewStats = ClaudeSessionParser.parse(tail: previewTail)
expect(previewStats.preview == "Fixed the bug in the parser.", "last assistant text wins as preview")
expect(previewStats.assistantMessages == 2, "preview tail counts messages")

// MARK: - MonthGrid days

let calendar = Calendar.current
let july = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15))!
let gridDays = MonthGrid.gridDays(for: july, calendar: calendar)
expect(gridDays.count == 42, "month grid always 6 weeks")
expect(calendar.component(.weekday, from: gridDays[0].date) == 2, "grid starts on Monday")
expect(gridDays.filter(\.inMonth).count == 31, "July has 31 in-month days")

// MARK: - SnapLayout

let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
expect(SnapLayout.leftHalf.frame(in: visible) == CGRect(x: 0, y: 0, width: 500, height: 800), "left half")
expect(SnapLayout.rightHalf.frame(in: visible) == CGRect(x: 500, y: 0, width: 500, height: 800), "right half")
expect(SnapLayout.maximize.frame(in: visible) == visible, "maximize fills visible frame")
expect(SnapLayout.centerThird.frame(in: visible).minX.rounded() == 333, "center third x")
expect(SnapLayout.topLeftQuarter.frame(in: visible) == CGRect(x: 0, y: 400, width: 500, height: 400), "top-left quarter (AppKit origin bottom-left → top row has higher y)")
expect(SnapLayout.bottomRightQuarter.frame(in: visible) == CGRect(x: 500, y: 0, width: 500, height: 400), "bottom-right quarter")

let strip = SnapZoneMath.stripFrame(notch: CGRect(x: 653, y: 950, width: 206, height: 32), tileCount: 5)
expect(strip.midX == 756, "strip centered on notch: \(strip.midX)")
expect(strip.maxY == 950, "strip hangs below the notch bottom")
let tiles = SnapZoneMath.tileRects(strip: strip, count: 5)
expect(tiles.count == 5, "one rect per tile")
expect(tiles[0].minX >= strip.minX && tiles[4].maxX <= strip.maxX, "tiles fit inside strip")
expect(SnapZoneMath.tileIndex(at: CGPoint(x: tiles[2].midX, y: tiles[2].midY), strip: strip, count: 5) == 2, "hit test middle tile")
expect(SnapZoneMath.tileIndex(at: CGPoint(x: strip.minX - 50, y: strip.midY), strip: strip, count: 5) == nil, "miss outside strip")
expect(SnapZoneMath.axPoint(fromCocoa: CGPoint(x: 10, y: 700), primaryScreenHeight: 800) == CGPoint(x: 10, y: 100), "cocoa→AX y-flip")

// MARK: - KeyCombo

// Cocoa flags: command = 1<<20, shift = 1<<17, option = 1<<19, control = 1<<18.
expect(KeyCombo.carbonModifiers(fromCocoa: 1 << 20) == 256, "cmd → carbon cmdKey")
expect(KeyCombo.carbonModifiers(fromCocoa: (1 << 20) | (1 << 17)) == 256 | 512, "cmd+shift")
expect(KeyCombo.carbonModifiers(fromCocoa: (1 << 19) | (1 << 18)) == 2048 | 4096, "opt+ctrl")
let combo = KeyCombo(keyCode: 45, carbonModifiers: 256 | 512) // ⇧⌘N
expect(combo.display == "⇧⌘N", "display renders modifiers+key: \(combo.display)")
let roundTrip = try? JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo))
expect(roundTrip == combo, "KeyCombo codable round-trip")

// MARK: - DropActionRunner (phase 5 actions)

expect(
    DropActionRunner.volumeRoot(for: URL(fileURLWithPath: "/Volumes/USB Stick/photos/a.jpg"))
        == URL(fileURLWithPath: "/Volumes/USB Stick"),
    "volume root extracted"
)
expect(DropActionRunner.volumeRoot(for: URL(fileURLWithPath: "/Users/x/a.txt")) == nil,
       "non-volume path → nil")
expect(DropActionRunner.volumeRoot(for: URL(fileURLWithPath: "/Volumes")) == nil,
       "bare /Volumes → nil")
expect(
    DropActionRunner.iCloudDriveURL(home: URL(fileURLWithPath: "/Users/x")).path
        == "/Users/x/Library/Mobile Documents/com~apple~CloudDocs",
    "iCloud Drive path"
)

// unzip round-trip: zip a temp file, unzip it, expect the payload back.
let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ndchecks-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
let payload = tempDir.appendingPathComponent("hello.txt")
try! "hello".write(to: payload, atomically: true, encoding: .utf8)
if let archive = try? DropActionRunner.zip([payload]),
   let extracted = try? DropActionRunner.unzip(archive) {
    let inside = extracted.appendingPathComponent("hello.txt")
    expect((try? String(contentsOf: inside, encoding: .utf8)) == "hello", "unzip restores payload")
} else {
    expect(false, "zip/unzip round-trip threw")
}
try? FileManager.default.removeItem(at: tempDir)

// MARK: - LiveRotation

expect(LiveRotation.pick(count: 0, tick: 7) == nil, "no sources → nil")
expect(LiveRotation.pick(count: 3, tick: 0) == 0, "tick 0 → first")
expect(LiveRotation.pick(count: 3, tick: 4) == 1, "wraps modulo count")

// MARK: - EventSearch

expect(EventSearch.matches(query: "", in: ["Standup"]), "empty query matches")
expect(EventSearch.matches(query: "stand", in: ["Standup", nil]), "case-insensitive prefix")
expect(EventSearch.matches(query: "CAFÉ", in: ["team cafe sync"]), "diacritic-insensitive")
expect(!EventSearch.matches(query: "retro", in: ["Standup", "Room 4"]), "no match → false")

// MARK: - DayTimeline

let dtDayStart = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
let dtDayEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date())!
let dtNoon = Calendar.current.date(bySettingHour: 13, minute: 30, second: 0, of: Date())!
expect(DayTimeline.fraction(of: dtNoon, dayStart: dtDayStart, dayEnd: dtDayEnd) == 0.5, "13:30 is halfway through 9–18")
expect(DayTimeline.fraction(of: dtDayStart.addingTimeInterval(-60), dayStart: dtDayStart, dayEnd: dtDayEnd) == nil, "before start → nil")
let dtBlocks = DayTimeline.blocks(
    events: [(start: dtDayStart.addingTimeInterval(3_600), end: dtDayStart.addingTimeInterval(7_200)),
             (start: dtDayEnd.addingTimeInterval(3_600), end: dtDayEnd.addingTimeInterval(7_200))],
    dayStart: dtDayStart, dayEnd: dtDayEnd
)
expect(dtBlocks.count == 1, "out-of-range event dropped")
expect(abs(dtBlocks[0].startFraction - 1.0 / 9.0) < 0.001, "block start fraction")

// MARK: - TaskTrash

let oldEntry = TrashedTask(id: "1", title: "old", deletedAt: Date(timeIntervalSinceNow: -31 * 86_400))
let newEntry = TrashedTask(id: "2", title: "new", deletedAt: Date(timeIntervalSinceNow: -3_600))
let kept = TaskTrash.pruned([oldEntry, newEntry], now: Date(), retentionDays: 30)
expect(kept == [newEntry], "prune drops entries older than retention")
expect(TaskTrash.pruned([], now: Date(), retentionDays: 30).isEmpty, "empty stays empty")

// MARK: - AppCategory

expect(AppCategory.categorize("com.apple.Safari") == "Browsing", "Safari → Browsing")
expect(AppCategory.categorize("com.google.Chrome") == "Browsing", "Chrome → Browsing")
expect(AppCategory.categorize("com.apple.dt.Xcode") == "Development", "Xcode → Development")
expect(AppCategory.categorize("com.tinyspeck.slackmacgap") == "Communication", "Slack → Communication")
expect(AppCategory.categorize("com.spotify.client") == "Media", "Spotify → Media")
expect(AppCategory.categorize("com.unknown.thing") == "Other", "unknown → Other")
let catTotals = AppCategory.totals([
    UsageSlice(bundleID: "com.apple.Safari", seconds: 100),
    UsageSlice(bundleID: "com.google.Chrome", seconds: 50),
    UsageSlice(bundleID: "com.apple.dt.Xcode", seconds: 120),
])
expect(catTotals.first?.category == "Browsing" && catTotals.first?.seconds == 150,
       "categories aggregate and sort: \(catTotals)")

// MARK: - Summary

if failures == 0 {
    print("OK — \(checks) checks passed")
    exit(0)
} else {
    print("\(failures)/\(checks) checks FAILED")
    exit(1)
}
