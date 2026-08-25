import AppKit
import SwiftUI
import Combine

// MARK: - Araçlar

enum DrawTool: Equatable {
    case pen
    case text
}

enum DrawPalette {
    static var colors: [(name: String, color: NSColor)] {[
        (L("Kırmızı"), .systemRed),
        (L("Turuncu"), .systemOrange),
        (L("Sarı"), .systemYellow),
        (L("Yeşil"), .systemGreen),
        (L("Mavi"), .systemBlue),
        (L("Beyaz"), .white),
    ]}

    static var widths: [(label: String, name: String, value: CGFloat)] {[
        ("S", L("İnce"), 3),
        ("M", L("Orta"), 6),
        ("L", L("Kalın"), 12),
    ]}
}

/// Toolbar'ın seçili durumunu SwiftUI'ye yansıtan küçük model.
final class DrawToolModel: ObservableObject {
    @Published var colorIndex = 0
    @Published var widthIndex = 1
    @Published var tool: DrawTool = .pen
}

// MARK: - Denetleyici

@MainActor
final class RecordingDrawController {
    static let shared = RecordingDrawController()

    let tools = DrawToolModel()

    private var canvasWindow: NSWindow?
    private var canvas: DrawCanvasView?
    private var toolbarPanel: NSPanel?

    private var observersRegistered = false
    private var notificationToken: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    var isActive: Bool { canvasWindow != nil }

    private init() {
        registerObservers()
    }

    /// ScreenRecorder.start() bunu çağırır: singleton'a dokunmak gözlemcileri kurar.
    func arm() {
        registerObservers()
    }

    private func registerObservers() {
        guard !observersRegistered else { return }
        observersRegistered = true

        // Island'daki ✏️ düğmesi bu bildirimi gönderir
        notificationToken = NotificationCenter.default.addObserver(
            forName: .ssPlusToggleDrawOverlay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toggle()
            }
        }

        // Kayıt bittiğinde her şeyi topla
        AppState.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                MainActor.assumeIsolated {
                    if phase != .recording {
                        self?.teardown()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Açma / kapama

    func toggle() {
        if isActive {
            teardown()
        } else {
            present()
        }
    }

    private func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        // 1) Tuval: kayda GİRMESİ gereken pencere
        let window = DrawCanvasWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        // Varsayılan paylaşım tipi: pencere ekran kaydına dahil edilebilir.
        // Akış başladıktan sonra oluştuğu için içerik filtresinin dışında kalır.
        window.sharingType = .readOnly
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let canvas = DrawCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.autoresizingMask = [.width, .height]
        canvas.strokeColor = DrawPalette.colors[tools.colorIndex].color
        canvas.strokeWidth = DrawPalette.widths[tools.widthIndex].value
        canvas.tool = tools.tool
        canvas.onEscape = { [weak self] in self?.teardown() }
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvas)

        self.canvasWindow = window
        self.canvas = canvas

        // 2) Toolbar: kayda GİRMEMESİ gereken cam hap
        let size = CGSize(width: 452, height: 56)
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 26,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.sharingType = .none               // videoda görünmesin
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: DrawToolbarView(model: tools, controller: self)
        )
        panel.orderFrontRegardless()
        self.toolbarPanel = panel
    }

    func teardown() {
        canvas?.finishEditing()
        canvas?.onEscape = nil
        if let canvasWindow {
            canvasWindow.orderOut(nil)
            canvasWindow.contentView = nil
        }
        canvasWindow = nil
        canvas = nil

        if let toolbarPanel {
            toolbarPanel.orderOut(nil)
            toolbarPanel.contentView = nil
        }
        toolbarPanel = nil
    }

    // MARK: Toolbar eylemleri

    func selectColor(_ index: Int) {
        guard DrawPalette.colors.indices.contains(index) else { return }
        tools.colorIndex = index
        canvas?.strokeColor = DrawPalette.colors[index].color
    }

    func selectWidth(_ index: Int) {
        guard DrawPalette.widths.indices.contains(index) else { return }
        tools.widthIndex = index
        canvas?.strokeWidth = DrawPalette.widths[index].value
    }

    func selectTool(_ tool: DrawTool) {
        tools.tool = tool
        canvas?.tool = tool
    }

    func clear() {
        canvas?.clearAll()
    }

    func close() {
        teardown()
    }
}

// MARK: - Tuval penceresi

final class DrawCanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Tuval

final class DrawCanvasView: NSView, NSTextFieldDelegate {

    private struct Stroke {
        var points: [CGPoint]
        var color: NSColor
        var width: CGFloat
    }

    private struct TextItem {
        var origin: CGPoint
        var string: String
        var color: NSColor
        var size: CGFloat
    }

    var strokeColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 6 {
        didSet { needsDisplay = true }
    }
    var tool: DrawTool = .pen {
        didSet {
            if tool != oldValue { finishEditing() }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onEscape: (() -> Void)?

    private var strokes: [Stroke] = []
    private var texts: [TextItem] = []
    private var current: Stroke?
    private var editor: NSTextField?
    /// Fare titreşimini süzen sabitleyici — akıcı fırça hissi.
    private let stabilizer = StrokeStabilizer()

    private var textSize: CGFloat { max(18, strokeWidth * 3.4) }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Çizim

    override func draw(_ dirtyRect: NSRect) {
        for stroke in strokes { render(stroke) }
        if let current { render(current) }
        for item in texts { render(item) }
    }

    private func render(_ stroke: Stroke) {
        guard stroke.points.count > 1 else { return }
        let path = Self.smoothPath(for: stroke.points)
        path.lineWidth = stroke.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Açık zeminlerde de okunsun diye ince koyu kontur
        NSColor.black.withAlphaComponent(0.28).setStroke()
        path.lineWidth = stroke.width + 2
        path.stroke()
        stroke.color.setStroke()
        path.lineWidth = stroke.width
        path.stroke()
    }

    private func render(_ item: TextItem) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: item.size, weight: .semibold),
            .foregroundColor: item.color,
            .shadow: shadow,
        ]
        NSAttributedString(string: item.string, attributes: attributes).draw(at: item.origin)
    }

    // MARK: Fare

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        finishEditing()
        switch tool {
        case .pen:
            stabilizer.reset(with: point)
            current = Stroke(points: [point], color: strokeColor, width: strokeWidth)
        case .text:
            beginText(at: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool == .pen, current != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let smooth = stabilizer.add(point) else { return }
        current?.points.append(smooth)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard tool == .pen, var stroke = current else { return }
        current = nil
        let point = convert(event.locationInWindow, from: nil)
        stroke.points.append(point)
        if stroke.points.count < 2 {
            stroke.points.append(CGPoint(x: point.x + 0.6, y: point.y))
        }
        strokes.append(stroke)
        needsDisplay = true
    }

    // MARK: Klavye

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {            // Esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // MARK: İmleç

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    // MARK: Metin aracı

    private func beginText(at point: CGPoint) {
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - textSize * 0.8, width: 300, height: textSize * 1.7))
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.32)
        field.textColor = strokeColor
        field.font = .systemFont(ofSize: textSize, weight: .semibold)
        field.focusRingType = .none
        field.placeholderString = L("Yaz ve ↩")
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldAction(_:))
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
    }

    @objc private func textFieldAction(_ sender: NSTextField) {
        finishEditing()
    }

    /// Açık metin alanını tuvale kalıcı olarak işler.
    func finishEditing() {
        guard let field = editor else { return }
        editor = nil
        let value = field.stringValue
        let origin = CGPoint(x: field.frame.minX + 3, y: field.frame.minY + textSize * 0.35)
        let color = field.textColor ?? strokeColor
        let size = field.font?.pointSize ?? textSize
        field.removeFromSuperview()
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.append(TextItem(origin: origin, string: value, color: color, size: size))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editor?.removeFromSuperview()
            editor = nil
            window?.makeFirstResponder(self)
            needsDisplay = true
            return true
        }
        return false
    }

    // MARK: Temizle

    func clearAll() {
        editor?.removeFromSuperview()
        editor = nil
        strokes.removeAll()
        texts.removeAll()
        current = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Yumuşatma (Catmull-Rom → kübik Bézier)

    private static func smoothPath(for points: [CGPoint]) -> NSBezierPath {
        StrokePath.smooth(through: points)
    }
}

// MARK: - Cam toolbar

struct DrawToolbarView: View {
    @ObservedObject var model: DrawToolModel
    let controller: RecordingDrawController

    var body: some View {
        HStack(spacing: 10) {
            colorDots
            separator
            widthChips
            separator
            toolToggle
            separator
            actionChip(icon: "trash", title: L("Temizle"), tooltip: L("Tüm çizimleri sil")) {
                controller.clear()
            }
            actionChip(icon: "xmark", title: L("Kapat"), tooltip: L("Çizim katmanını kapat (Esc)")) {
                controller.close()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            MaterialFill(shape: Capsule(style: .continuous))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 20)
    }

    private var colorDots: some View {
        HStack(spacing: 7) {
            ForEach(Array(DrawPalette.colors.enumerated()), id: \.offset) { index, entry in
                Button {
                    controller.selectColor(index)
                } label: {
                    Circle()
                        .fill(Color.from(entry.color))
                        .frame(width: 17, height: 17)
                        .overlay(
                            Circle().strokeBorder(
                                Color.white.opacity(model.colorIndex == index ? 0.95 : 0.3),
                                lineWidth: model.colorIndex == index ? 2 : 0.5
                            )
                        )
                        .scaleEffect(model.colorIndex == index ? 1.16 : 1)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .compatHelp(entry.name)
            }
        }
        .compatAnimation(.spring(response: 0.25, dampingFraction: 0.7), value: model.colorIndex)
    }

    private var widthChips: some View {
        HStack(spacing: 5) {
            ForEach(Array(DrawPalette.widths.enumerated()), id: \.offset) { index, entry in
                Button {
                    controller.selectWidth(index)
                } label: {
                    Text(entry.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 24, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(model.widthIndex == index ? 0.18 : 0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.white.opacity(model.widthIndex == index ? 0.3 : 0.1), lineWidth: 0.5)
                        )
                        .foregroundColor(Color.primary)
                }
                .buttonStyle(.plain)
                .compatHelp(L("%@ kalınlık", entry.name))
            }
        }
    }

    private var toolToggle: some View {
        HStack(spacing: 5) {
            toolButton(.pen, icon: "pencil.tip", tooltip: L("Kalem"))
            toolButton(.text, icon: "textformat", tooltip: L("Metin — tıkla, yaz, ↩ ile bırak"))
        }
    }

    private func toolButton(_ tool: DrawTool, icon: String, tooltip: String) -> some View {
        Button {
            controller.selectTool(tool)
        } label: {
            SymbolImage(name: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(model.tool == tool ? 0.18 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(model.tool == tool ? 0.3 : 0.1), lineWidth: 0.5)
                )
                .foregroundColor(Color.primary)
        }
        .buttonStyle(.plain)
        .compatHelp(tooltip)
    }

    private func actionChip(
        icon: String,
        title: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                SymbolImage(name: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .foregroundColor(Color.primary)
        }
        .buttonStyle(.plain)
        .compatHelp(tooltip)
    }
}
