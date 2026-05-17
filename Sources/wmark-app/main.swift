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
                    .stroke(Color.accentColor, lineWidth: 4)
            )
            .shadow(color: Color.accentColor.opacity(0.45), radius: 16)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 16) {
                GlassToolbar(model: model)

                HSplitView {
                    WindowListPane(model: model)
                        .frame(minWidth: 340, idealWidth: 410)

                    PreviewPane(window: model.stateHoveredWindow ?? model.stateSelectedWindow)
                        .frame(minWidth: 430)
                }
            }
            .padding(18)

            if !model.stateCopiedText.isEmpty {
                StatusToast(text: model.stateCopiedText)
                    .padding(.top, 18)
                    .padding(.trailing, 22)
            }
        }
        .background(.regularMaterial)
    }
}

struct GlassToolbar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("wmark")
                    .font(.title2.weight(.semibold))
                Text("選んだウィンドウをCodexへ安全に渡します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.stateSelectionMode {
                StatusPill(systemImage: "scope", text: "Click a window")
            }

            ToolbarButton(systemImage: "arrow.clockwise", text: "Scan") {
                model.scan()
            }
            .keyboardShortcut("r")

            ToolbarButton(systemImage: model.stateSelectionMode ? "xmark" : "scope", text: model.stateSelectionMode ? "Cancel" : "Select") {
                if model.stateSelectionMode {
                    model.stopSelectionMode()
                } else {
                    model.startSelectionMode()
                }
            }

            ToolbarButton(systemImage: "macwindow.badge.plus", text: "Frontmost") {
                model.mark(model.dataWindows.first)
            }
            .keyboardShortcut("m")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.12), radius: 22, y: 10)
    }
}

struct ToolbarButton: View {
    let systemImage: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(.primary.opacity(0.08))
        )
    }
}

struct StatusPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.14))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.accentColor.opacity(0.28))
            )
    }
}

struct StatusToast: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.accentColor.opacity(0.24))
            )
            .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }
}

struct WindowListPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Open Windows")
                    .font(.headline)
                Spacer()
                Text("\(model.dataWindows.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }

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
                .padding(6)
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.primary.opacity(0.06))
            )
        }
    }
}

struct WindowRow: View {
    let window: WindowRecord
    let stateActive: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 12) {
                Image(systemName: "macwindow")
                    .font(.title3)
                    .foregroundStyle(stateActive ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(window.app)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("ID \(window.windowId)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(window.title.isEmpty ? "Untitled window" : window.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("\(window.bounds.width) x \(window.bounds.height)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Image(systemName: "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .opacity(stateActive ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if let window {
                    Text(window.app)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                }
            }

            if let window {
                PreviewView(window: window)

                VStack(alignment: .leading, spacing: 6) {
                    Text(window.title.isEmpty ? "Untitled window" : window.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text("Click the window row to copy a target.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("Choose a window", systemImage: "macwindow", description: Text("Hover or click a row to preview it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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
                .frame(maxWidth: .infinity, maxHeight: 440)
                .padding(10)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.primary.opacity(0.08))
                )
                .shadow(color: .black.opacity(0.18), radius: 28, y: 14)
        } else {
            ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text("Screen Recording permission may be required."))
                .frame(maxWidth: .infinity, minHeight: 320)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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
