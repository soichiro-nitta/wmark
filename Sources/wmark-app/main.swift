import AppKit
import Carbon
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

typealias WindowId = CGWindowID

struct Bounds: Codable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct WindowRecord: Codable, Identifiable {
    let windowId: WindowId
    let pid: Int
    let app: String
    let title: String
    let bounds: Bounds
    let layer: Int

    var id: WindowId { windowId }
}

struct TargetRecord: Codable {
    let id: String
    let kind: String
    let app: String
    let pid: Int
    let windowId: WindowId
    let windowTitle: String
    let bounds: Bounds
    let thumbnailPath: String?
    let capturedAt: String
    let status: String
    let context: [String: String]
}

let directoryTargets = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/window-targets", isDirectory: true)
let directoryThumbs = directoryTargets.appendingPathComponent("thumbs", isDirectory: true)
let fileQueue = directoryTargets.appendingPathComponent("queue.json")

let encoderJson = JSONEncoder()
let decoderJson = JSONDecoder()

@main
struct WmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("wmark") {
            ContentView(model: appDelegate.model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var shortcut: ShortcutManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcut = ShortcutManager {
            DispatchQueue.main.async {
                self.model.startSelectionMode()
            }
        }
    }
}

final class ShortcutManager {
    private var hotKeyRef: EventHotKeyRef?
    private let onShortcut: () -> Void

    init(onShortcut: @escaping () -> Void) {
        self.onShortcut = onShortcut
        let hotKeyID = EventHotKeyID(signature: OSType(0x574D524B), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                if hotKeyID.id == 1, let userData {
                    Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue().onShortcut()
                }

                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var dataWindows: [WindowRecord] = []
    @Published var stateHoveredWindow: WindowRecord?
    @Published var stateSelectedWindow: WindowRecord?
    @Published var stateCopiedText = ""
    @Published var stateSelectionMode = false
    @Published var stateHighlightedWindow: WindowRecord?

    private var monitorMouseMoved: Any?
    private var monitorMouseDown: Any?
    private var windowOverlay: NSWindow?

    init() {
        dataWindows = scanWindowsForApp()
    }

    func scan() {
        dataWindows = scanWindowsForApp()
    }

    func mark(_ window: WindowRecord?) {
        stateSelectedWindow = window
        stateCopiedText = markWindow(window)
        scan()
    }

    func startSelectionMode() {
        stateSelectionMode = true
        scan()
        updateHighlightedWindow()
        monitorMouseMoved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateHighlightedWindow()
            }
        }
        monitorMouseDown = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.mark(self?.stateHighlightedWindow)
                self?.stopSelectionMode()
            }
        }
    }

    func stopSelectionMode() {
        stateSelectionMode = false
        stateHighlightedWindow = nil
        windowOverlay?.close()
        windowOverlay = nil

        if let monitorMouseMoved {
            NSEvent.removeMonitor(monitorMouseMoved)
            self.monitorMouseMoved = nil
        }

        if let monitorMouseDown {
            NSEvent.removeMonitor(monitorMouseDown)
            self.monitorMouseDown = nil
        }
    }

    private func updateHighlightedWindow() {
        let location = NSEvent.mouseLocation
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let point = CGPoint(x: location.x, y: maxY - location.y)
        let windows = scanWindowsForApp()
        stateHighlightedWindow = windows.first { window in
            CGRect(
                x: window.bounds.x,
                y: window.bounds.y,
                width: window.bounds.width,
                height: window.bounds.height
            )
            .contains(point)
        }
        showOverlay(for: stateHighlightedWindow)
    }

    private func showOverlay(for window: WindowRecord?) {
        guard let window else {
            windowOverlay?.close()
            windowOverlay = nil
            return
        }

        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let frame = NSRect(
            x: window.bounds.x,
            y: Int(maxY) - window.bounds.y - window.bounds.height,
            width: window.bounds.width,
            height: window.bounds.height
        )
        let overlay = windowOverlay ?? NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.level = .screenSaver
        overlay.ignoresMouseEvents = true
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.contentView = NSHostingView(rootView: HighlightOverlay())
        overlay.setFrame(frame, display: true)
        overlay.orderFrontRegardless()
        windowOverlay = overlay
    }
}

struct HighlightOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
            )
            .shadow(color: Color.accentColor.opacity(0.28), radius: 10)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                AppToolbar(model: model)

                HSplitView {
                    WindowListPane(model: model)
                        .frame(minWidth: 300, idealWidth: 340)

                    PreviewPane(window: model.stateHoveredWindow ?? model.stateSelectedWindow)
                        .frame(minWidth: 440)
                }
            }
            .padding(14)

            if !model.stateCopiedText.isEmpty {
                StatusToast(text: model.stateCopiedText)
                    .padding(.top, 14)
                    .padding(.trailing, 16)
            }
        }
        .background(.regularMaterial)
    }
}

struct AppToolbar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("wmark")
                .font(.title2.weight(.semibold))

            Spacer()

            if model.stateSelectionMode {
                Text("Click a window")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.scan()
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")

            Button {
                if model.stateSelectionMode {
                    model.stopSelectionMode()
                } else {
                    model.startSelectionMode()
                }
            } label: {
                Label(model.stateSelectionMode ? "Cancel" : "Select", systemImage: model.stateSelectionMode ? "xmark" : "scope")
            }

            Button {
                model.mark(model.dataWindows.first)
            } label: {
                Label("Frontmost", systemImage: "macwindow.badge.plus")
            }
            .keyboardShortcut("m")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.primary.opacity(0.06))
        )
    }
}

struct StatusToast: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(.primary.opacity(0.08))
            )
    }
}

struct WindowListPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Windows")
                .font(.headline)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.dataWindows) { window in
                        WindowRow(
                            window: window,
                            stateActive: model.stateHoveredWindow?.id == window.id || model.stateSelectedWindow?.id == window.id
                        ) {
                            model.mark(window)
                        }
                        .onHover { stateHovering in
                            if stateHovering {
                                model.stateHoveredWindow = window
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct WindowRow: View {
    let window: WindowRecord
    let stateActive: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 3) {
                Text(window.app)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(window.title.isEmpty ? "Untitled window" : window.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(stateActive ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(stateActive ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }
}

struct PreviewPane: View {
    let window: WindowRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.headline)

            if let window {
                PreviewView(window: window)

                VStack(alignment: .leading, spacing: 4) {
                    Text(window.app)
                        .font(.callout.weight(.semibold))
                    Text(window.title.isEmpty ? "Untitled window" : window.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                ContentUnavailableView("Choose a window", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer()
        }
    }
}

struct PreviewView: View {
    let window: WindowRecord

    var body: some View {
        if let image = thumbnailImage(window.windowId) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.primary.opacity(0.08))
                )
        } else {
            ContentUnavailableView("No Preview", systemImage: "eye.slash")
                .frame(maxWidth: .infinity, minHeight: 320)
        }
    }
}

func scanWindowsForApp() -> [WindowRecord] {
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
    .filter { $0.layer == 0 && !$0.title.isEmpty }
}

func markWindow(_ window: WindowRecord?) -> String {
    guard let window else {
        return "No target window"
    }

    let id = makeTargetId()
    let thumbnail = writeThumbnail(windowId: window.windowId, id: id)
    let target = TargetRecord(
        id: id,
        kind: "window",
        app: window.app,
        pid: window.pid,
        windowId: window.windowId,
        windowTitle: window.title,
        bounds: window.bounds,
        thumbnailPath: thumbnail?.path(percentEncoded: false),
        capturedAt: ISO8601DateFormatter().string(from: Date()),
        status: "pending",
        context: [:]
    )

    appendTarget(target)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("target: \(id)", forType: .string)

    return "Copied target: \(id)"
}

func thumbnailImage(_ windowId: WindowId) -> NSImage? {
    guard
        let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowId,
            [.boundsIgnoreFraming, .bestResolution]
        )
    else {
        return nil
    }

    return NSImage(cgImage: image, size: .zero)
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

func makeTargetId() -> String {
    let value = UInt16.random(in: UInt16.min...UInt16.max)
    return "WTG-" + String(format: "%04X", value)
}
