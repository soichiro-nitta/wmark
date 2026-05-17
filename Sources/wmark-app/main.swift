import AppKit
import Carbon
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

typealias WindowId = CGWindowID

struct SpaceSnapshot: Equatable {
    let id: Int
    let title: String
}

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
    private var windowMain: AppWindow?
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
            windowMain = AppWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                styleMask: [.titled, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            windowMain?.title = "wmark"
            windowMain?.titleVisibility = .hidden
            windowMain?.titlebarAppearsTransparent = true
            windowMain?.standardWindowButton(.closeButton)?.isHidden = true
            windowMain?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            windowMain?.standardWindowButton(.zoomButton)?.isHidden = true
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

final class AppWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
    @Published var stateCopiedWindowId: WindowId?
    @Published var stateSelectionMode = false
    @Published var stateHighlightedWindow: WindowRecord?
    @Published var stateSpaceRefreshing = false
    @Published var dataSpaceTitle = currentSpaceSnapshot()?.title ?? "wmark"
    @Published var dataTargetIds: [WindowId: String] = [:]

    private var monitorMouseMoved: Any?
    private var monitorMouseDown: Any?
    private var windowOverlay: NSWindow?
    private var observerSpace: NSObjectProtocol?
    private var taskCopiedReset: DispatchWorkItem?
    private var taskSpaceRefresh: DispatchWorkItem?
    private var dateSpaceRefreshStarted = Date.distantPast
    private var stateSpaceSnapshot = currentSpaceSnapshot()

    init() {
        dataWindows = scanWindowsForApp()
        syncTargetIds()
        startSpaceTracking()
    }

    func scan() {
        refreshSpaceState(force: true)
    }

    func refreshSpaceTitle() {
        refreshSpaceState(force: false)
    }

    private func startSpaceTracking() {
        observerSpace = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshSpaceStateAfterSpaceChange()
            }
        }
    }

    private func refreshSpaceStateAfterSpaceChange() {
        taskSpaceRefresh?.cancel()
        dateSpaceRefreshStarted = Date()
        stateSpaceRefreshing = true
        refreshSpaceStateWhenReady(previous: stateSpaceSnapshot, attemptsRemaining: 8)
    }

    private func refreshSpaceStateWhenReady(previous snapshotPrevious: SpaceSnapshot?, attemptsRemaining: Int) {
        let windowsCurrent = scanWindowsForApp()
        let snapshotCurrent = currentSpaceSnapshot(matching: windowsCurrent)

        if snapshotCurrent != snapshotPrevious || attemptsRemaining <= 0 {
            let intervalRemaining = max(0, 0.55 - Date().timeIntervalSince(dateSpaceRefreshStarted))
            let taskRefresh = DispatchWorkItem { [weak self] in
                withAnimation(.easeInOut(duration: 0.3)) {
                    self?.refreshSpaceState(force: true, snapshot: snapshotCurrent, windows: windowsCurrent)
                    self?.stateSpaceRefreshing = false
                }
            }

            taskSpaceRefresh = taskRefresh
            DispatchQueue.main.asyncAfter(deadline: .now() + intervalRemaining, execute: taskRefresh)
        } else {
            let taskRefresh = DispatchWorkItem { [weak self] in
                self?.refreshSpaceStateWhenReady(previous: snapshotPrevious, attemptsRemaining: attemptsRemaining - 1)
            }

            taskSpaceRefresh = taskRefresh
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: taskRefresh)
        }
    }

    private func refreshSpaceState(force: Bool, snapshot: SpaceSnapshot? = nil, windows: [WindowRecord]? = nil) {
        let windowsCurrent = windows ?? scanWindowsForApp()
        let snapshotCurrent = snapshot ?? currentSpaceSnapshot(matching: windowsCurrent)

        if force || snapshotCurrent != stateSpaceSnapshot {
            stateSpaceSnapshot = snapshotCurrent
            dataSpaceTitle = snapshotCurrent?.title ?? "wmark"
            dataWindows = windowsCurrent
            syncTargetIds()
        }
    }

    func mark(_ window: WindowRecord?) {
        stateSelectedWindow = window
        _ = markWindow(window, id: window.flatMap { dataTargetIds[$0.windowId] })
        showCopiedState(for: window)
        scan()
    }

    private func syncTargetIds() {
        var dataNext = dataTargetIds

        for window in dataWindows where dataNext[window.windowId] == nil {
            dataNext[window.windowId] = makeTargetId()
        }

        dataTargetIds = dataNext.filter { idWindow, _ in
            dataWindows.contains { $0.windowId == idWindow }
        }
    }

    private func showCopiedState(for window: WindowRecord?) {
        taskCopiedReset?.cancel()

        withAnimation(.easeOut(duration: 0.2)) {
            stateCopiedWindowId = window?.windowId
        }

        let taskReset = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.stateCopiedWindowId = nil
                }
            }
        }

        taskCopiedReset = taskReset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: taskReset)
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
        ZStack {
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

            ResizeCursorZones()
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ResizeCursorZones: View {
    private let valueSize: CGFloat = 7

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ResizeCursorZone(cursor: .resizeLeftRight)
                    .frame(width: valueSize)

                Spacer(minLength: 0)

                ResizeCursorZone(cursor: .resizeLeftRight)
                    .frame(width: valueSize)
            }

            VStack(spacing: 0) {
                ResizeCursorZone(cursor: .resizeUpDown)
                    .frame(height: valueSize)

                Spacer(minLength: 0)

                ResizeCursorZone(cursor: .resizeUpDown)
                    .frame(height: valueSize)
            }
        }
    }
}

struct ResizeCursorZone: View {
    let cursor: NSCursor

    var body: some View {
        CursorRectView(cursor: cursor)
    }
}

struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectNSView {
        CursorRectNSView(cursor: cursor)
    }

    func updateNSView(_ view: CursorRectNSView, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }
}

final class CursorRectNSView: NSView {
    var cursor: NSCursor {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}

struct AppToolbar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            TrafficButtons()
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if model.stateSpaceRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.62)
                        .frame(width: 12, height: 12)
                }

                Text(model.stateSelectionMode ? "Click a window" : model.dataSpaceTitle)
                    .font(.headline)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .animation(.easeInOut(duration: 0.18), value: model.stateSpaceRefreshing)

            HStack(spacing: 1) {
                ToolbarIconButton(systemImage: "arrow.clockwise", help: "Scan") {
                    model.scan()
                }
                .keyboardShortcut("r")

                ToolbarIconButton(systemImage: model.stateSelectionMode ? "xmark" : "scope", help: model.stateSelectionMode ? "Cancel" : "Select") {
                    if model.stateSelectionMode {
                        model.stopSelectionMode()
                    } else {
                        model.startSelectionMode()
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(.thinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(.primary.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, -6)
        }
        .controlSize(.regular)
        .buttonStyle(.plain)
        .font(.title3)
        .frame(height: 42)
    }
}

struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var stateHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .background(stateHovering ? Color.primary.opacity(0.08) : Color.clear)
                .clipShape(Circle())
                .animation(.easeOut(duration: 0.18), value: stateHovering)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { valueHovering in
            stateHovering = valueHovering
        }
    }
}

struct TrafficButtons: View {
    @State private var stateHoveringClose = false

    var body: some View {
        HStack(spacing: 9) {
            Button {
                NSApplication.shared.keyWindow?.close()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.88))
                        .frame(width: 13, height: 13)

                    if stateHoveringClose {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { stateHoveringClose = $0 }

            Circle()
                .fill(Color.secondary.opacity(0.36))
                .frame(width: 13, height: 13)

            Circle()
                .fill(Color.secondary.opacity(0.36))
                .frame(width: 13, height: 13)
        }
        .padding(.leading, 1)
        .frame(width: 70, height: 24, alignment: .leading)
    }
}

struct WindowListPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.dataWindows) { window in
                        WindowRow(
                            window: window,
                            targetId: model.dataTargetIds[window.windowId] ?? "",
                            stateActive: model.stateHoveredWindow?.id == window.id || model.stateSelectedWindow?.id == window.id,
                            stateCopied: model.stateCopiedWindowId == window.windowId
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
    let targetId: String
    let stateActive: Bool
    let stateCopied: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 8) {
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

                Spacer(minLength: 8)

                ZStack {
                    if stateCopied {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Copied")
                        }
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                    }

                    if !stateCopied {
                        Text(targetId)
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(stateCopied ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial)
                .clipShape(Capsule())
                .animation(.easeOut(duration: 0.2), value: stateCopied)
            }
            .padding(8)
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

func currentSpaceSnapshot(matching windows: [WindowRecord]? = nil) -> SpaceSnapshot? {
    var valueSnapshot: SpaceSnapshot?
    var dataSpaceRows: [(id: Int, uuid: String, index: Int)] = []
    let urlSpaces = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.spaces.plist")

    if
        let dataSpaces = NSDictionary(contentsOf: urlSpaces) as? [String: Any],
        let dataConfiguration = dataSpaces["SpacesDisplayConfiguration"] as? [String: Any],
        let dataManagement = dataConfiguration["Management Data"] as? [String: Any],
        let dataMonitors = dataManagement["Monitors"] as? [[String: Any]]
    {
        for dataMonitor in dataMonitors where valueSnapshot == nil {
            if
                let dataCurrentSpace = dataMonitor["Current Space"] as? [String: Any],
                let idCurrent = dataCurrentSpace["ManagedSpaceID"] as? Int,
                let dataSpaces = dataMonitor["Spaces"] as? [[String: Any]]
            {
                for indexSpace in dataSpaces.indices {
                    if
                        let idSpace = dataSpaces[indexSpace]["ManagedSpaceID"] as? Int,
                        let uuidSpace = dataSpaces[indexSpace]["uuid"] as? String
                    {
                        dataSpaceRows.append((id: idSpace, uuid: uuidSpace, index: indexSpace + 1))
                    }

                    if
                        let idSpace = dataSpaces[indexSpace]["ManagedSpaceID"] as? Int,
                        idSpace == idCurrent,
                        valueSnapshot == nil
                    {
                        valueSnapshot = SpaceSnapshot(
                            id: idCurrent,
                            title: localizedDesktopTitle(indexSpace + 1)
                        )
                    }
                }
            }
        }

        if
            let windows,
            let dataProperties = dataConfiguration["Space Properties"] as? [[String: Any]]
        {
            let idsVisible = Set(windows.map { Int($0.windowId) })
            var valueBestScore = 0
            var snapshotVisible: SpaceSnapshot?

            for dataProperty in dataProperties {
                if
                    let uuidSpace = dataProperty["name"] as? String,
                    let idsSpace = dataProperty["windows"] as? [Int],
                    let dataSpace = dataSpaceRows.first(where: { $0.uuid == uuidSpace })
                {
                    let valueScore = Set(idsSpace).intersection(idsVisible).count

                    if valueScore > valueBestScore {
                        valueBestScore = valueScore
                        snapshotVisible = SpaceSnapshot(
                            id: dataSpace.id,
                            title: localizedDesktopTitle(dataSpace.index)
                        )
                    }
                }
            }

            if valueBestScore > 0 {
                valueSnapshot = snapshotVisible
            }
        }
    }

    return valueSnapshot
}

func localizedDesktopTitle(_ number: Int) -> String {
    var valueTitle = "Desktop \(number)"
    let valueLanguage = Locale.preferredLanguages.first ?? Locale.current.identifier

    if valueLanguage.hasPrefix("ja") {
        valueTitle = "デスクトップ\(number)"
    }

    return valueTitle
}

func markWindow(_ window: WindowRecord?, id: String? = nil) -> String {
    guard let window else {
        return "No target window"
    }

    let id = id ?? makeTargetId()
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
