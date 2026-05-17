import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

typealias WindowId = CGWindowID

struct Bounds: Codable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct WindowRecord: Codable {
    let windowId: WindowId
    let pid: Int
    let app: String
    let title: String
    let bounds: Bounds
    let layer: Int
}

struct ChromeTabRecord: Codable {
    let title: String
    let url: String
}

struct TargetRecord: Codable {
    let id: String
    let kind: String
    let app: String
    let pid: Int
    let windowId: WindowId
    let windowTitle: String
    let tabTitle: String?
    let url: String?
    let bounds: Bounds
    let thumbnailPath: String?
    let capturedAt: String
    let status: String
}

struct ResolveRecord: Codable {
    let id: String
    let status: String
    let reason: String
    let target: TargetRecord?
    let matches: [WindowRecord]
}

let directoryTargets = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/window-targets", isDirectory: true)
let directoryThumbs = directoryTargets.appendingPathComponent("thumbs", isDirectory: true)
let fileQueue = directoryTargets.appendingPathComponent("queue.json")
let intervalStale: TimeInterval = 60 * 60

let encoderJson = JSONEncoder()
encoderJson.outputFormatting = [.prettyPrinted, .sortedKeys]

let decoderJson = JSONDecoder()

let command = CommandLine.arguments.dropFirst().first ?? "help"

switch command {
case "scan":
    printJson(scanWindows())
case "chrome-front":
    printJson(chromeFrontTab())
case "thumbnail":
    runThumbnailCommand()
case "mark-frontmost":
    runMarkFrontmostCommand()
case "queue":
    printJson(readTargets())
case "resolve":
    runResolveCommand()
case "consume":
    runConsumeCommand()
default:
    printUsage()
}

func scanWindows() -> [WindowRecord] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

    return rawWindows.compactMap { rawWindow in
        guard
            let numberWindow = rawWindow[kCGWindowNumber as String] as? NSNumber,
            let numberPid = rawWindow[kCGWindowOwnerPID as String] as? NSNumber,
            let app = rawWindow[kCGWindowOwnerName as String] as? String,
            let dictionaryBounds = rawWindow[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dictionaryBounds as CFDictionary)
        else {
            return nil
        }

        let title = rawWindow[kCGWindowName as String] as? String ?? ""
        let layer = (rawWindow[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0

        return WindowRecord(
            windowId: WindowId(numberWindow.uint32Value),
            pid: numberPid.intValue,
            app: app,
            title: title,
            bounds: Bounds(
                x: Int(bounds.origin.x),
                y: Int(bounds.origin.y),
                width: Int(bounds.width),
                height: Int(bounds.height)
            ),
            layer: layer
        )
    }
}

func chromeFrontTab() -> ChromeTabRecord? {
    let source = """
    tell application "Google Chrome"
      if not running then return ""
      if (count of windows) is 0 then return ""
      set activeTab to active tab of front window
      return (title of activeTab) & "\n" & (URL of activeTab)
    end tell
    """

    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
    let lines = result.components(separatedBy: "\n")

    if lines.count >= 2 {
        return ChromeTabRecord(
            title: lines[0],
            url: lines.dropFirst().joined(separator: "\n")
        )
    }

    if let error {
        fputs("chrome-front failed: \(error)\n", stderr)
    }

    return nil
}

func runThumbnailCommand() {
    guard
        CommandLine.arguments.count >= 3,
        let windowId = WindowId(CommandLine.arguments[2])
    else {
        fputs("usage: wmark thumbnail <windowId>\n", stderr)
        exit(2)
    }

    let path = writeThumbnail(windowId: windowId, id: "window-\(windowId)")

    if let path {
        print(path.path(percentEncoded: false))
    } else {
        fputs("thumbnail failed for windowId \(windowId)\n", stderr)
        exit(1)
    }
}

func runMarkFrontmostCommand() {
    let windows = scanWindows().filter { $0.layer == 0 && !$0.title.isEmpty }

    guard let window = windows.first else {
        fputs("no frontmost window candidate\n", stderr)
        exit(1)
    }

    let id = makeTargetId()
    let chrome = window.app == "Google Chrome" ? chromeFrontTab() : nil
    let thumbnail = writeThumbnail(windowId: window.windowId, id: id)
    let target = TargetRecord(
        id: id,
        kind: "window",
        app: window.app,
        pid: window.pid,
        windowId: window.windowId,
        windowTitle: window.title,
        tabTitle: chrome?.title,
        url: chrome?.url,
        bounds: window.bounds,
        thumbnailPath: thumbnail?.path(percentEncoded: false),
        capturedAt: ISO8601DateFormatter().string(from: Date()),
        status: "pending"
    )

    appendTarget(target)
    copyToPasteboard("target: \(id)")
    print("target: \(id)")
}

func runResolveCommand() {
    guard CommandLine.arguments.count >= 3 else {
        fputs("usage: wmark resolve <targetId>\n", stderr)
        exit(2)
    }

    let id = CommandLine.arguments[2]
    let result = resolveTarget(id: id)
    printJson(result)

    if result.status != "matched" {
        exit(1)
    }
}

func runConsumeCommand() {
    guard CommandLine.arguments.count >= 3 else {
        fputs("usage: wmark consume <targetId>\n", stderr)
        exit(2)
    }

    let id = CommandLine.arguments[2]
    let result = resolveTarget(id: id)
    printJson(result)

    if result.status == "matched" {
        updateTargetStatus(id: id, status: "used")
    }

    if result.status != "matched" {
        exit(1)
    }
}

func resolveTarget(id: String) -> ResolveRecord {
    let targets = readTargets()
    let target = targets.last { $0.id == id }
    let windows = scanWindows()
    var status = "missing"
    var reason = "target id is not in queue"
    var matches: [WindowRecord] = []

    if let target {
        let isExpired = isStale(target)
        let isUsableStatus = target.status == "pending"
        matches = windows.filter {
            $0.windowId == target.windowId
                && $0.pid == target.pid
                && $0.app == target.app
        }

        if !isUsableStatus {
            status = "used"
            reason = "target status is \(target.status)"
        }

        if isUsableStatus && isExpired {
            status = "stale"
            reason = "target is older than \(Int(intervalStale / 60)) minutes"
        }

        if isUsableStatus && !isExpired && matches.isEmpty {
            status = "stale"
            reason = "saved window identity no longer exists"
        }

        if isUsableStatus && !isExpired && matches.count > 1 {
            status = "ambiguous"
            reason = "multiple windows matched the saved identity"
        }

        if isUsableStatus && !isExpired && matches.count == 1 {
            status = "matched"
            reason = "windowId, pid, and app matched"
        }
    }

    return ResolveRecord(
        id: id,
        status: status,
        reason: reason,
        target: target,
        matches: matches
    )
}

func writeThumbnail(windowId: WindowId, id: String) -> URL? {
    try? FileManager.default.createDirectory(at: directoryThumbs, withIntermediateDirectories: true)

    guard
        let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowId,
            [.boundsIgnoreFraming, .bestResolution]
        ),
        let destination = CGImageDestinationCreateWithURL(
            directoryThumbs.appendingPathComponent("\(id).png") as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        return nil
    }

    CGImageDestinationAddImage(destination, image, nil)

    return CGImageDestinationFinalize(destination)
        ? directoryThumbs.appendingPathComponent("\(id).png")
        : nil
}

func appendTarget(_ target: TargetRecord) {
    try? FileManager.default.createDirectory(at: directoryTargets, withIntermediateDirectories: true)

    let dataNext = try? encoderJson.encode(readTargets() + [target])

    if let dataNext {
        try? dataNext.write(to: fileQueue, options: .atomic)
    }
}

func updateTargetStatus(id: String, status: String) {
    let targets = readTargets().map { target in
        var updatedTarget = target

        if target.id == id {
            updatedTarget = TargetRecord(
                id: target.id,
                kind: target.kind,
                app: target.app,
                pid: target.pid,
                windowId: target.windowId,
                windowTitle: target.windowTitle,
                tabTitle: target.tabTitle,
                url: target.url,
                bounds: target.bounds,
                thumbnailPath: target.thumbnailPath,
                capturedAt: target.capturedAt,
                status: status
            )
        }

        return updatedTarget
    }
    let dataNext = try? encoderJson.encode(targets)

    if let dataNext {
        try? dataNext.write(to: fileQueue, options: .atomic)
    }
}

func readTargets() -> [TargetRecord] {
    let dataExisting = try? Data(contentsOf: fileQueue)
    return dataExisting.flatMap { try? decoderJson.decode([TargetRecord].self, from: $0) } ?? []
}

func isStale(_ target: TargetRecord) -> Bool {
    let formatter = ISO8601DateFormatter()
    var stale = true

    if let date = formatter.date(from: target.capturedAt) {
        stale = Date().timeIntervalSince(date) > intervalStale
    }

    return stale
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func makeTargetId() -> String {
    let value = UInt16.random(in: UInt16.min...UInt16.max)
    return "WTG-" + String(format: "%04X", value)
}

func printJson<T: Encodable>(_ value: T) {
    guard let data = try? encoderJson.encode(value) else {
        exit(1)
    }

    print(String(data: data, encoding: .utf8) ?? "")
}

func printUsage() {
    print(
        """
        usage:
          wmark scan
          wmark chrome-front
          wmark thumbnail <windowId>
          wmark mark-frontmost
          wmark queue
          wmark resolve <targetId>
          wmark consume <targetId>
        """
    )
}
