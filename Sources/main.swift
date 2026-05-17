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

let directoryTargets = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/window-targets", isDirectory: true)
let directoryThumbs = directoryTargets.appendingPathComponent("thumbs", isDirectory: true)
let fileQueue = directoryTargets.appendingPathComponent("queue.json")

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
        kind: chrome == nil ? "window" : "chrome-tab",
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

    let dataExisting = try? Data(contentsOf: fileQueue)
    let targetsExisting = dataExisting.flatMap { try? decoderJson.decode([TargetRecord].self, from: $0) } ?? []
    let dataNext = try? encoderJson.encode(targetsExisting + [target])

    if let dataNext {
        try? dataNext.write(to: fileQueue, options: .atomic)
    }
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
        """
    )
}
