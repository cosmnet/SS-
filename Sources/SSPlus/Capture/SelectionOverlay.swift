import AppKit
import ScreenCaptureKit

enum SelectionMode: String {
    case rect
    case window

    var hint: String {
        switch self {
        case .rect: return L("Sürükleyerek alan seç  ·  ⇧ kare")
        case .window: return L("Yakalanacak pencereye tıkla")
        }
    }
}

enum SelectionStyle {
    case screenshot
    case recording

    var accent: NSColor {
        switch self {
        case .screenshot: return NSColor.white
        case .recording: return NSColor.systemRed
        }
    }
}

enum SelectionResult {
    case rect(CGRect, NSScreen)                       // global Cocoa koordinatı
    case window(CGWindowID, CGRect, NSScreen)         // pencere ID + global çerçeve
}

// MARK: - Pencere

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        sharingType = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
    }
}

// MARK: - Denetleyici

@MainActor
final class SelectionOverlayController {
    static let shared = SelectionOverlayController()

    private var window: OverlayWindow?
    private var completion: ((SelectionResult?) -> Void)?

    var isActive: Bool { window != nil }

    private init() {}

    func begin(mode: SelectionMode, style: SelectionStyle = .screenshot, completion: @escaping (SelectionResult?) -> Void) {
        guard window == nil else {
            completion(nil)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            completion(nil)
            return
        }

        self.completion = completion
        let overlay = OverlayWindow(screen: screen)
        let view = SelectionView(mode: mode, style: style, screen: screen) { [weak self] result in
            self?.finish(result)
        }
        overlay.contentView = view
        overlay.makeFirstResponder(view)
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = overlay

        AppState.shared.phase = .selecting(mode, style)
    }

    func setMode(_ mode: SelectionMode) {
        (window?.contentView as? SelectionView)?.switchMode(mode)
    }

    func cancel() {
        finish(nil)
    }

    fileprivate func finish(_ result: SelectionResult?) {
        guard let overlay = window else { return }
        window = nil
        overlay.orderOut(nil)
        overlay.contentView = nil
        let done = completion
        completion = nil
        AppState.shared.phase = .idle
        done?(result)
    }
}

// MARK: - Görünüm

final class SelectionView: NSView {
    private(set) var mode: SelectionMode
    private let style: SelectionStyle
    private let screen: NSScreen
    private let onFinish: (SelectionResult?) -> Void

    private var startPoint: NSPoint?
    private var currentRect: CGRect = .zero
    private var isDragging = false
    private var finished = false

    /// Gerçek sürükleme başladı mı (tıklama ile ayırmak için)
    private var didDrag = false
    /// Tıklama sayılacak azami kayma
    private static let clickSlop: CGFloat = 4
    /// Sürükleme sırasında ⇧ basılıysa kareye kilitlenir
    private var squareLocked = false

    /// Alan modunda pencere sezme açık mı (yalnızca ekran görüntüsünde)
    private let smartWindow: Bool

    // Pencere modu: liste önden arkaya sıralı, çerçeveler view koordinatında
    private var windowList: [(id: CGWindowID, frame: CGRect)] = []
    private var hoveredWindow: (id: CGWindowID, frame: CGRect)?

    init(mode: SelectionMode, style: SelectionStyle, screen: NSScreen, onFinish: @escaping (SelectionResult?) -> Void) {
        self.mode = mode
        self.style = style
        self.screen = screen
        self.onFinish = onFinish
        self.smartWindow = style == .screenshot && SettingsStore.shared.smartWindowDetect
        super.init(frame: .zero)
        wantsLayer = true
        if wantsWindowHover { loadWindowList() }
    }

    /// Fare üzerine gelince pencere vurgulanacak mı
    private var wantsWindowHover: Bool {
        mode == .window || (mode == .rect && smartWindow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .window ? .pointingHand : .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        updateHoveredWindow(at: convert(inWindow, from: nil))
        needsDisplay = true
    }

    func switchMode(_ newMode: SelectionMode) {
        guard newMode != mode else { return }
        mode = newMode
        startPoint = nil
        currentRect = .zero
        isDragging = false
        didDrag = false
        squareLocked = false
        hoveredWindow = nil
        if wantsWindowHover {
            loadWindowList()
            if let window {
                let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                updateHoveredWindow(at: convert(inWindow, from: nil))
            }
        }
        window?.invalidateCursorRects(for: self)
        SettingsStore.shared.lastModeRaw = newMode.rawValue
        AppState.shared.phase = .selecting(newMode, style)
        needsDisplay = true
    }

    // MARK: Pencere listesi

    private func loadWindowList() {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var list: [(CGWindowID, CGRect)] = []
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgRect.width > 40, cgRect.height > 40 else { continue }
            // CG (üst-sol global) → Cocoa (alt-sol global) → view koordinatı
            let cocoa = CGRect(
                x: cgRect.minX,
                y: primaryHeight - cgRect.maxY,
                width: cgRect.width,
                height: cgRect.height
            )
            let local = cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            list.append((CGWindowID(number), local))
        }
        windowList = list
    }

    private func updateHoveredWindow(at point: NSPoint) {
        hoveredWindow = windowList.first { $0.frame.contains(point) }
    }

    // MARK: Fare

    override func mouseMoved(with event: NSEvent) {
        guard wantsWindowHover, !isDragging, !didDrag else { return }
        updateHoveredWindow(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .rect:
            startPoint = point
            currentRect = .zero
            isDragging = true
            didDrag = false
            squareLocked = event.modifierFlags.contains(.shift)
        case .window:
            if let hovered = hoveredWindow {
                let globalFrame = hovered.frame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                finish(.window(hovered.id, globalFrame, screen))
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .rect, let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !didDrag, hypot(point.x - start.x, point.y - start.y) > Self.clickSlop {
            // Gerçek sürükleme başladı: pencere vurgusu kaybolur
            didDrag = true
            hoveredWindow = nil
        }
        var dx = point.x - start.x
        var dy = point.y - start.y
        if squareLocked {
            // ⇧: kenarı uzun kenara kilitle, yön korunur
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        currentRect = CGRect(
            x: min(start.x, start.x + dx),
            y: min(start.y, start.y + dy),
            width: abs(dx),
            height: abs(dy)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { needsDisplay = true }
        guard mode == .rect else { return }
        isDragging = false
        squareLocked = false
        // Sürüklemeden yapılan tıklama: altındaki pencereyi yakala
        if smartWindow, !didDrag, let hovered = hoveredWindow {
            let globalFrame = hovered.frame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            finish(.window(hovered.id, globalFrame, screen))
            return
        }
        guard currentRect.width > 4, currentRect.height > 4 else {
            startPoint = nil
            currentRect = .zero
            didDrag = false
            if wantsWindowHover { updateHoveredWindow(at: point) }
            return
        }
        let global = currentRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        finish(.rect(global.integral, screen))
    }

    // MARK: Klavye

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            finish(nil)
            return
        }
        if event.keyCode == 36 { // Return → tüm ekran
            finish(.rect(screen.frame, screen))
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r", "a": switchMode(.rect)
        case "w", "p": switchMode(.window)
        default: super.keyDown(with: event)
        }
    }

    /// ⇧ basılıp bırakıldığında kare kilidini tazele
    override func flagsChanged(with event: NSEvent) {
        squareLocked = event.modifierFlags.contains(.shift)
        if isDragging, let start = startPoint {
            let mouse = convert(window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero, from: nil)
            var dx = mouse.x - start.x
            var dy = mouse.y - start.y
            if squareLocked {
                let side = max(abs(dx), abs(dy))
                dx = dx < 0 ? -side : side
                dy = dy < 0 ? -side : side
            }
            currentRect = CGRect(
                x: min(start.x, start.x + dx),
                y: min(start.y, start.y + dy),
                width: abs(dx),
                height: abs(dy)
            )
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    private func finish(_ result: SelectionResult?) {
        guard !finished else { return }
        finished = true
        onFinish(result)
    }

    // MARK: Çizim

    override func draw(_ dirtyRect: NSRect) {
        let accent = style.accent
        let dimColor = NSColor.black.withAlphaComponent(0.32)

        switch mode {
        case .rect:
            if let hovered = hoveredWindow, !didDrag {
                // Akıllı pencere sezme: ikincil, daha silik vurgu
                drawWindowHighlight(hovered.frame, dimColor: dimColor, secondary: true)
            } else {
                drawDim(cutout: isDraggingValidRect ? currentRect : nil, dimColor: dimColor)
                if isDraggingValidRect {
                    drawSelectionBorder(currentRect, accent: accent)
                    drawSizeBadge(for: currentRect)
                }
            }
        case .window:
            if let hovered = hoveredWindow {
                drawWindowHighlight(hovered.frame, dimColor: dimColor, secondary: false)
            } else {
                drawDim(cutout: nil, dimColor: dimColor)
            }
        }
    }

    private func drawWindowHighlight(_ frame: CGRect, dimColor: NSColor, secondary: Bool) {
        drawDim(cutout: frame, dimColor: dimColor)
        let accent = NSColor.controlAccentColor
        if secondary {
            // Alan modunda yalnızca ipucu: kesik, silik çerçeve
            accent.withAlphaComponent(0.55).setStroke()
            let border = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
            border.lineWidth = 1.5
            border.setLineDash([7, 5], count: 2, phase: 0)
            border.stroke()
            accent.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        } else {
            drawSelectionBorder(frame, accent: accent)
            accent.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
        }
        drawSizeBadge(for: frame)
    }

    private var isDraggingValidRect: Bool {
        currentRect.width > 1 && currentRect.height > 1
    }

    private func drawDim(cutout: CGRect?, dimColor: NSColor) {
        let path = NSBezierPath(rect: bounds)
        if let cutout {
            path.append(NSBezierPath(rect: cutout))
            path.windingRule = .evenOdd
        }
        dimColor.setFill()
        path.fill()
    }

    private func drawSelectionBorder(_ rect: CGRect, accent: NSColor) {
        accent.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()

        // Köşe tutamaçları
        let handleSize: CGFloat = 6
        accent.setFill()
        for corner in [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ] {
            let handle = CGRect(
                x: corner.x - handleSize / 2,
                y: corner.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSBezierPath(ovalIn: handle).fill()
        }
    }

    private func drawSizeBadge(for rect: CGRect) {
        guard rect.width > 1 else { return }
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let padding: CGFloat = 6
        var origin = CGPoint(x: rect.maxX - size.width - padding * 2, y: rect.minY - size.height - padding * 2 - 6)
        if origin.y < 4 { origin.y = rect.minY + 8 }
        origin.x = max(4, origin.x)
        let badge = CGRect(
            x: origin.x,
            y: origin.y,
            width: size.width + padding * 2,
            height: size.height + padding
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: badge.minX + padding, y: badge.minY + padding / 2), withAttributes: attributes)
    }
}
