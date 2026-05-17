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
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var windowMain: NSWindow?
    private var shortcut: ShortcutManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcut = ShortcutManager {
            DispatchQueue.main.async {
                self.model.startSelectionMode()
            }
        }
        showMainWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshSpaceTitle()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    private func showMainWindow() {
        if windowMain == nil {
            windowMain = BorderlessResizeWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                styleMask: [.borderless, .resizable],
                backing: .buffered,
                defer: false
            )
            windowMain?.title = "wmark"
            windowMain?.minSize = NSSize(width: 280, height: 360)
            windowMain?.contentView = NSHostingView(
                rootView: ContentView(model: model)
                    .frame(minWidth: 280, minHeight: 360)
            )
            windowMain?.center()
        }

        if let window = windowMain {
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.stationary)
            window.hidesOnDeactivate = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

final class BorderlessResizeWindow: NSWindow {
    private let valueResizeMargin: CGFloat = 8

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let valueEdge = resizeEdge(at: event.locationInWindow)

        if valueEdge.isEmpty {
            super.mouseDown(with: event)
        } else {
            resizeWindow(from: event, edge: valueEdge)
        }
    }

    private func resizeEdge(at point: NSPoint) -> ResizeEdge {
        var valueEdge: ResizeEdge = []

        if point.x <= valueResizeMargin {
            valueEdge.insert(.minX)
        }

        if frame.width - point.x <= valueResizeMargin {
            valueEdge.insert(.maxX)
        }

        if point.y <= valueResizeMargin {
            valueEdge.insert(.minY)
        }

        if frame.height - point.y <= valueResizeMargin {
            valueEdge.insert(.maxY)
        }

        return valueEdge
    }

    private func resizeWindow(from event: NSEvent, edge: ResizeEdge) {
        let pointStart = NSEvent.mouseLocation
        let frameStart = frame

        while NSEvent.pressedMouseButtons & 1 == 1 {
            if let eventNext = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if eventNext.type == .leftMouseDragged {
                    setFrame(
                        resizedFrame(from: frameStart, pointStart: pointStart, pointCurrent: NSEvent.mouseLocation, edge: edge),
                        display: true
                    )
                }
            }
        }
    }

    private func resizedFrame(from frameStart: NSRect, pointStart: NSPoint, pointCurrent: NSPoint, edge: ResizeEdge) -> NSRect {
        var frameNext = frameStart
        let valueDeltaX = pointCurrent.x - pointStart.x
        let valueDeltaY = pointCurrent.y - pointStart.y

        if edge.contains(.minX) {
            frameNext.origin.x = frameStart.origin.x + valueDeltaX
            frameNext.size.width = frameStart.size.width - valueDeltaX
        }

        if edge.contains(.maxX) {
            frameNext.size.width = frameStart.size.width + valueDeltaX
        }

        if edge.contains(.minY) {
            frameNext.origin.y = frameStart.origin.y + valueDeltaY
            frameNext.size.height = frameStart.size.height - valueDeltaY
        }

        if edge.contains(.maxY) {
            frameNext.size.height = frameStart.size.height + valueDeltaY
        }

        if frameNext.width < minSize.width {
            if edge.contains(.minX) {
                frameNext.origin.x = frameStart.maxX - minSize.width
            }
            frameNext.size.width = minSize.width
        }

        if frameNext.height < minSize.height {
            if edge.contains(.minY) {
                frameNext.origin.y = frameStart.maxY - minSize.height
            }
            frameNext.size.height = minSize.height
        }

        return frameNext
    }
}

struct ResizeEdge: OptionSet {
    let rawValue: Int

    static let minX = ResizeEdge(rawValue: 1 << 0)
    static let maxX = ResizeEdge(rawValue: 1 << 1)
    static let minY = ResizeEdge(rawValue: 1 << 2)
    static let maxY = ResizeEdge(rawValue: 1 << 3)
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
    @Published var dataSpaceTitle = currentSpaceTitle() ?? "wmark"

    private var monitorMouseMoved: Any?
    private var monitorMouseDown: Any?
    private var windowOverlay: NSWindow?

    init() {
        dataWindows = scanWindowsForApp()
    }

    func scan() {
        refreshSpaceTitle()
        dataWindows = scanWindowsForApp()
    }

    func refreshSpaceTitle() {
        dataSpaceTitle = currentSpaceTitle() ?? "wmark"
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
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 2)
            )
            .shadow(color: Color.accentColor.opacity(0.24), radius: 10)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(.thinMaterial)

            Color.black.opacity(0.48)

            VStack(spacing: 12) {
                AppToolbar(model: model)

                WindowListPane(model: model)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 14)

            if !model.stateCopiedText.isEmpty {
                StatusToast(text: model.stateCopiedText)
                    .padding(.top, 4)
                    .padding(.trailing, 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct AppToolbar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                WindowControlButton(color: .red) {
                    NSApplication.shared.keyWindow?.close()
                }

                WindowControlButton(color: .secondary.opacity(0.45)) {
                    NSApplication.shared.keyWindow?.miniaturize(nil)
                }

                WindowControlButton(color: .secondary.opacity(0.45)) {
                    NSApplication.shared.keyWindow?.zoom(nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(model.stateSelectionMode ? "Click a window" : model.dataSpaceTitle)
                .font(.headline.weight(.medium))
                .foregroundStyle(model.stateSelectionMode ? .secondary : .primary)
                .lineLimit(1)

            HStack(spacing: 14) {
                Button {
                    model.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help("Scan")

                Button {
                    if model.stateSelectionMode {
                        model.stopSelectionMode()
                    } else {
                        model.startSelectionMode()
                    }
                } label: {
                    Image(systemName: model.stateSelectionMode ? "xmark" : "scope")
                }
                .help(model.stateSelectionMode ? "Cancel" : "Select")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .controlSize(.regular)
        .buttonStyle(.plain)
        .font(.title3)
        .frame(height: 30)
    }
}

struct WindowControlButton: View {
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
    }
}

struct StatusToast: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            .clipShape(Capsule())
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
                            } else if model.stateHoveredWindow?.id == window.id {
                                model.stateHoveredWindow = nil
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
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(stateActive ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if stateActive {
                HoverPreview(window: window)
                    .frame(width: 220, height: 140)
                    .offset(x: -8, y: 34)
                    .zIndex(1)
            }
        }
    }
}

struct HoverPreview: View {
    let window: WindowRecord

    var body: some View {
        if let image = thumbnailImage(window.windowId) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(6)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Image(systemName: "eye.slash")
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

func currentSpaceTitle() -> String? {
    var valueTitle: String?
    let urlSpaces = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.spaces.plist")

    if
        let dataSpaces = NSDictionary(contentsOf: urlSpaces) as? [String: Any],
        let dataConfiguration = dataSpaces["SpacesDisplayConfiguration"] as? [String: Any],
        let dataManagement = dataConfiguration["Management Data"] as? [String: Any],
        let dataMonitors = dataManagement["Monitors"] as? [[String: Any]]
    {
        for dataMonitor in dataMonitors where valueTitle == nil {
            if
                let dataCurrentSpace = dataMonitor["Current Space"] as? [String: Any],
                let idCurrent = dataCurrentSpace["ManagedSpaceID"] as? Int,
                let dataSpaces = dataMonitor["Spaces"] as? [[String: Any]]
            {
                for indexSpace in dataSpaces.indices where valueTitle == nil {
                    if
                        let idSpace = dataSpaces[indexSpace]["ManagedSpaceID"] as? Int,
                        idSpace == idCurrent
                    {
                        valueTitle = localizedDesktopTitle(indexSpace + 1)
                    }
                }
            }
        }
    }

    return valueTitle
}

func localizedDesktopTitle(_ number: Int) -> String {
    var valueTitle = "Desktop \(number)"
    let valueLanguage = Locale.preferredLanguages.first ?? Locale.current.identifier

    if valueLanguage.hasPrefix("ja") {
        valueTitle = "デスクトップ \(number)"
    }

    return valueTitle
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
