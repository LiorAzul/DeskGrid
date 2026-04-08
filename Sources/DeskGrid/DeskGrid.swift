import AppKit

// MARK: - App Entry Point

@main
@MainActor
struct DeskGridApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var controller: DeskGridController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Prompt for accessibility permission if not granted
        if !AXIsProcessTrusted() {
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let opts = [key: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "DeskGrid")
        }

        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        controller = DeskGridController()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cleanup()
    }

    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}

// MARK: - KeyableWindow

@MainActor
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Controller

@MainActor
final class DeskGridController {
    private var selectionWindow: NSWindow?
    private var gridWindow: NSWindow?
    private var dragOrigin: NSPoint?
    private var lastDrawnRect: NSRect = .zero
    private var frontmostAtMouseDown: String?

    private nonisolated(unsafe) var mouseDownMonitor: Any?
    private nonisolated(unsafe) var mouseDragMonitor: Any?
    private nonisolated(unsafe) var mouseUpMonitor: Any?
    private nonisolated(unsafe) var clickOutsideMonitor: Any?
    private nonisolated(unsafe) var escapeMonitor: Any?

    func start() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let loc = NSEvent.mouseLocation
            guard Self.isPointOnDesktop(loc) else { return }
            DispatchQueue.main.async { self?.handleMouseDown(at: loc) }
        }
    }

    /// Check if the point is on the desktop (no other app window under cursor)
    private static func isPointOnDesktop(_ point: NSPoint) -> Bool {
        let screenH = NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: screenH - point.y)

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return true }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for info in list {
            let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            if pid == myPID { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            if layer != 0 { continue }

            if let boundsDict = info[kCGWindowBounds as String],
               let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary) {
                if bounds.contains(cgPoint) {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Mouse Handling

    private func handleMouseDown(at point: NSPoint) {
        dragOrigin = point
        frontmostAtMouseDown = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if mouseDragMonitor == nil {
            mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                let loc = NSEvent.mouseLocation
                DispatchQueue.main.async { self?.handleMouseDrag(at: loc) }
            }
        }
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                let loc = NSEvent.mouseLocation
                DispatchQueue.main.async { self?.handleMouseUp(at: loc) }
            }
        }
    }

    private func handleMouseDrag(at point: NSPoint) {
        guard let origin = dragOrigin else { return }

        // Safety: if frontmost app changed during drag to something other than Finder, cancel.
        // Clicking the desktop always activates Finder, so that's expected and OK.
        let currentFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if currentFrontmost != frontmostAtMouseDown && currentFrontmost != "com.apple.finder" {
            cancelDrag()
            return
        }

        let rect = rectFrom(origin, point)
        guard rect.width > 10, rect.height > 10 else { return }
        updateSelectionWindow(rect: rect)
    }

    private func cancelDrag() {
        dragOrigin = nil
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        if let m = mouseDragMonitor { NSEvent.removeMonitor(m); mouseDragMonitor = nil }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
    }

    private func handleMouseUp(at point: NSPoint) {
        if let m = mouseDragMonitor { NSEvent.removeMonitor(m); mouseDragMonitor = nil }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }

        guard dragOrigin != nil else { return }

        guard let rect = selectionWindow?.frame, rect.width > 50, rect.height > 50 else {
            selectionWindow?.orderOut(nil)
            selectionWindow = nil
            dragOrigin = nil
            return
        }

        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        dragOrigin = nil
        lastDrawnRect = rect
        showGrid(in: rect)
    }

    private func rectFrom(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: - Selection Window

    private func updateSelectionWindow(rect: NSRect) {
        if selectionWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.contentView = SelectionView(frame: .zero)
            selectionWindow = w
            w.orderFrontRegardless()
        }
        selectionWindow?.setFrame(rect, display: true)
        selectionWindow?.contentView?.frame = NSRect(origin: .zero, size: rect.size)
        selectionWindow?.contentView?.needsDisplay = true
    }

    // MARK: - Grid

    private func showGrid(in rect: NSRect) {
        let apps = AppFinder.getInstalledApps()

        let window = KeyableWindow(
            contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.setFrame(rect, display: true)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        let view = GridView(frame: NSRect(origin: .zero, size: rect.size), apps: apps)
        view.onAppSelected = { [weak self] url in
            guard let self = self else { return }
            let target = self.lastDrawnRect
            // Capture screen height NOW, before dismissing (NSScreen.main may change)
            let screenH = NSScreen.main?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
            self.dismissGrid()
            self.launchAndPosition(url: url, rect: target, screenH: screenH)
        }
        window.contentView = view
        gridWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.dismissGrid() }
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { DispatchQueue.main.async { self?.dismissGrid() } }
        }
    }

    func cleanup() {
        cancelDrag()
        dismissGrid()
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m); mouseDownMonitor = nil }
    }

    func dismissGrid() {
        gridWindow?.orderOut(nil)
        gridWindow = nil
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
    }

    // MARK: - Launch & Position

    private func launchAndPosition(url: URL, rect: NSRect, screenH: CGFloat) {
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        guard !bundleID.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }

        let axOrigin = CGPoint(x: rect.origin.x, y: screenH - rect.origin.y - rect.height)
        let axSize = CGSize(width: rect.width, height: rect.height)

        let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let wasRunning = runningApp != nil && !runningApp!.isTerminated

        if wasRunning {
            let pid = runningApp!.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            let windowCountBefore = axWindows(for: axApp).count

            // Open new window via osascript (async) for known apps, CGEvent fallback
            openNewWindowAsync(bundleID: bundleID, appURL: url, runningApp: runningApp!)

            // Wait for a new AX window to appear, then position it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.waitForNewAXWindowAndPosition(
                    pid: pid, bundleID: bundleID, countBefore: windowCountBefore,
                    origin: axOrigin, size: axSize, retries: 30)
            }
        } else {
            NSWorkspace.shared.open(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.positionFocusedWindow(bundleID: bundleID, origin: axOrigin, size: axSize, retries: 20)
            }
        }
    }

    // MARK: - Open New Window

    /// Open a new window: AppleScript via osascript for known apps, CGEvent Cmd+N for others.
    /// Runs async — does not block the main thread.
    private func openNewWindowAsync(bundleID: String, appURL: URL, runningApp: NSRunningApplication) {
        let script: String?
        switch bundleID {
        case "com.apple.finder":
            script = "tell application \"Finder\" to activate\ntell application \"Finder\" to make new Finder window"
        case "com.google.Chrome":
            script = "tell application \"Google Chrome\" to activate\ntell application \"Google Chrome\" to make new window"
        case "com.apple.Safari":
            script = "tell application \"Safari\" to activate\ntell application \"Safari\" to make new document"
        case "com.apple.Terminal":
            script = "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script \"\""
        default:
            script = nil
        }

        if let script = script {
            // Run osascript in background — doesn't block main thread, no thread-safety issues
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = nil
            process.standardError = nil
            try? process.run()
        } else {
            // Generic fallback: activate + Cmd+N
            runningApp.activate(options: .activateIgnoringOtherApps)
            waitFrontmostThenAct(bundleID: bundleID, retries: 40) {
                self.sendCmdN()
            }
        }
    }

    /// Fallback: Cmd+N via CGEvent (requires accessibility permission)
    private func sendCmdN() {
        let src = CGEventSource(stateID: CGEventSourceStateID.hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: true) {
            down.flags = CGEventFlags.maskCommand
            down.post(tap: CGEventTapLocation.cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: false) {
            up.flags = CGEventFlags.maskCommand
            up.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    private func waitFrontmostThenAct(bundleID: String, retries: Int, action: @escaping () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action() }
        } else if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.waitFrontmostThenAct(bundleID: bundleID, retries: retries - 1, action: action)
            }
        }
    }

    /// Returns only real AXWindow elements (filters out desktop scroll areas, etc.)
    private func axWindows(for axApp: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref)
        guard let all = ref as? [AXUIElement] else { return [] }
        return all.filter { element in
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            return (roleRef as? String) == "AXWindow"
        }
    }

    // MARK: - Position: fresh launch

    private func positionFocusedWindow(bundleID: String, origin: CGPoint, size: CGSize, retries: Int) {
        guard retries > 0 else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.positionFocusedWindow(bundleID: bundleID, origin: origin, size: size, retries: retries - 1)
            }
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        if windowRef == nil {
            let wins = axWindows(for: axApp)
            windowRef = wins.first
        }
        guard let window = windowRef else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.positionFocusedWindow(bundleID: bundleID, origin: origin, size: size, retries: retries - 1)
            }
            return
        }

        setWindowFrame(window as! AXUIElement, origin: origin, size: size)
    }

    // MARK: - Position: already running (wait for new AX window by count)

    private func waitForNewAXWindowAndPosition(
        pid: pid_t, bundleID: String, countBefore: Int,
        origin: CGPoint, size: CGSize, retries: Int
    ) {
        guard retries > 0 else {
            // Fallback: position the focused window
            positionFocusedWindow(bundleID: bundleID, origin: origin, size: size, retries: 5)
            return
        }

        let axApp = AXUIElementCreateApplication(pid)
        let currentWindows = axWindows(for: axApp)

        if currentWindows.count > countBefore {
            // New window appeared — use the focused window (newly created windows get focus)
            var focusedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
            let targetWindow = (focusedRef as! AXUIElement?) ?? currentWindows.last!
            setWindowFrame(targetWindow, origin: origin, size: size)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.waitForNewAXWindowAndPosition(
                    pid: pid, bundleID: bundleID, countBefore: countBefore,
                    origin: origin, size: size, retries: retries - 1)
            }
        }
    }

    // MARK: - AX Helpers

    private func applyFrame(_ window: AXUIElement, origin: CGPoint, size: CGSize) {
        var pos = origin; var sz = size
        if let pv = AXValueCreate(.cgPoint, &pos) {
            let err1 = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv)
            if err1 != .success { NSLog("DeskGrid: setPosition failed: \(err1.rawValue) pos=\(pos)") }
        }
        if let sv = AXValueCreate(.cgSize, &sz) {
            let err2 = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
            if err2 != .success { NSLog("DeskGrid: setSize failed: \(err2.rawValue) size=\(sz)") }
        }
    }

    /// Set window frame — applies twice because apps often reset position on window creation
    private func setWindowFrame(_ window: AXUIElement, origin: CGPoint, size: CGSize) {
        applyFrame(window, origin: origin, size: size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.applyFrame(window, origin: origin, size: size)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.applyFrame(window, origin: origin, size: size)
        }
    }
}

// MARK: - Selection View

@MainActor
final class SelectionView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Grid View

@MainActor
final class GridView: NSView {
    var onAppSelected: ((URL) -> Void)?

    init(frame: NSRect, apps: [AppInfo]) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        addSubview(blur)

        let padding: CGFloat = 8
        let minCell: CGFloat = 60
        let maxCell: CGFloat = 100
        let availW = bounds.width - padding * 2

        var bestCols = 1
        var cellSize = minCell
        for cols in 1...20 {
            let cs = (availW - CGFloat(cols - 1) * padding) / CGFloat(cols)
            if cs >= minCell && cs <= maxCell {
                bestCols = cols
                cellSize = cs
            }
        }
        let cols = bestCols
        let rows = Int(ceil(Double(apps.count) / Double(cols)))
        let contentH = CGFloat(rows) * (cellSize + padding) + padding

        let scroll = NSScrollView(frame: bounds.insetBy(dx: 4, dy: 4))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let doc = NSView(frame: NSRect(x: 0, y: 0, width: scroll.bounds.width, height: max(scroll.bounds.height, contentH)))
        let totalW = CGFloat(cols) * cellSize + CGFloat(cols - 1) * padding
        let xOff = (doc.bounds.width - totalW) / 2

        for (i, app) in apps.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = xOff + CGFloat(col) * (cellSize + padding)
            let y = doc.bounds.height - padding - CGFloat(row + 1) * (cellSize + padding)
            let btn = AppTile(frame: NSRect(x: x, y: y, width: cellSize, height: cellSize), app: app)
            btn.onTap = { [weak self] in self?.onAppSelected?(app.url) }
            doc.addSubview(btn)
        }
        scroll.documentView = doc
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - App Tile

@MainActor
final class AppTile: NSView {
    var onTap: (() -> Void)?
    private var hovered = false

    init(frame: NSRect, app: AppInfo) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10

        let iconSize = min(bounds.width * 0.55, 48.0)
        let iv = NSImageView(frame: NSRect(
            x: (bounds.width - iconSize) / 2,
            y: bounds.height - iconSize - 6,
            width: iconSize, height: iconSize
        ))
        iv.image = app.icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iv)

        let lbl = NSTextField(labelWithString: app.name)
        lbl.font = .systemFont(ofSize: min(bounds.width * 0.13, 11), weight: .medium)
        lbl.textColor = .white
        lbl.alignment = .center
        lbl.lineBreakMode = .byTruncatingTail
        lbl.maximumNumberOfLines = 2
        lbl.frame = NSRect(x: 2, y: 1, width: bounds.width - 4, height: bounds.height * 0.3)
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.6)
        s.shadowOffset = NSSize(width: 0, height: -0.5)
        s.shadowBlurRadius = 2
        lbl.shadow = s
        addSubview(lbl)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = nil
    }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
        layer?.backgroundColor = hovered ? NSColor.white.withAlphaComponent(0.15).cgColor : nil
    }
}

// MARK: - App Finder

struct AppInfo: @unchecked Sendable {
    let name: String
    let url: URL
    let icon: NSImage

    @MainActor
    static func from(url: URL) -> AppInfo? {
        let name = url.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 48, height: 48)
        return AppInfo(name: name, url: url, icon: icon)
    }
}

@MainActor
enum AppFinder {
    static func getInstalledApps() -> [AppInfo] {
        var apps: [AppInfo] = []
        let fm = FileManager.default
        for dir in ["/Applications", "/System/Applications", "/Applications/Utilities"] {
            guard let items = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                if let app = AppInfo.from(url: url) { apps.append(app) }
            }
        }
        // Always add Finder — hardcoded since it lives outside standard app directories
        let finderPath = "/System/Library/CoreServices/Finder.app"
        let finderIcon = NSWorkspace.shared.icon(forFile: finderPath)
        finderIcon.size = NSSize(width: 48, height: 48)
        apps.append(AppInfo(name: "Finder", url: URL(fileURLWithPath: finderPath), icon: finderIcon))
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return apps
    }
}
