import AppKit
import SwiftUI
import Combine

// MARK: - Araçlar

enum AnnotationTool: Int, CaseIterable, Identifiable {
    case pen, highlighter, arrow, line, rect, ellipse, text

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .pen: return L("Kalem")
        case .highlighter: return L("Fosforlu")
        case .arrow: return L("Ok")
        case .line: return L("Çizgi")
        case .rect: return L("Dikdörtgen")
        case .ellipse: return L("Elips")
        case .text: return L("Metin")
        }
    }

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }

    /// 1–7 tuşları
    var shortcut: Int { rawValue + 1 }

    var isShape: Bool {
        switch self {
        case .line, .arrow, .rect, .ellipse: return true
        default: return false
        }
    }
}

enum AnnotationThickness: Int, CaseIterable, Identifiable {
    case small, medium, large

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .small: return 2
        case .medium: return 4
        case .large: return 7
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: return 16
        case .medium: return 24
        case .large: return 34
        }
    }
}

struct AnnotationColorItem: Identifiable {
    let id: Int
    let title: String
    let color: NSColor
    var swiftUIColor: Color { Color.from(color) }
}

enum AnnotationPalette {
    static var all: [AnnotationColorItem] {[
        AnnotationColorItem(id: 0, title: L("Beyaz"), color: .white),
        AnnotationColorItem(id: 1, title: L("Siyah"), color: .black),
        AnnotationColorItem(id: 2, title: L("Kırmızı"), color: .systemRed),
        AnnotationColorItem(id: 3, title: L("Turuncu"), color: .systemOrange),
        AnnotationColorItem(id: 4, title: L("Sarı"), color: .systemYellow),
        AnnotationColorItem(id: 5, title: L("Yeşil"), color: .systemGreen),
        AnnotationColorItem(id: 6, title: L("Mavi"), color: .systemBlue),
        AnnotationColorItem(id: 7, title: L("Mor"), color: .systemPurple),
    ]}
}

// MARK: - Çizim modeli

/// Koordinatlar görünüm noktası cinsinden, görüntünün SOL-ÜST köşesine göredir.
struct AnnotationShape: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var points: [CGPoint] = []
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var text: String = ""
}

final class AnnotationModel: ObservableObject {
    @Published var tool: AnnotationTool = .pen
    @Published var colorIndex: Int = 2
    @Published var thickness: AnnotationThickness = .medium
    @Published private(set) var shapes: [AnnotationShape] = []
    @Published private(set) var redoStack: [AnnotationShape] = []

    var currentColor: NSColor {
        AnnotationPalette.all[min(max(colorIndex, 0), AnnotationPalette.all.count - 1)].color
    }

    var canUndo: Bool { !shapes.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Fosforlu kalın çizer
    func strokeWidth(for tool: AnnotationTool) -> CGFloat {
        tool == .highlighter ? thickness.lineWidth * 4.5 : thickness.lineWidth
    }

    func makeShape(_ tool: AnnotationTool) -> AnnotationShape {
        AnnotationShape(
            tool: tool,
            color: currentColor,
            lineWidth: strokeWidth(for: tool),
            fontSize: thickness.fontSize
        )
    }

    func add(_ shape: AnnotationShape) {
        shapes.append(shape)
        redoStack.removeAll()
    }

    func undo() {
        guard let last = shapes.popLast() else { return }
        redoStack.append(last)
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        shapes.append(last)
    }
}

// MARK: - Çizici

/// Şekilleri geçerli NSGraphicsContext'e çizer.
/// Bağlam SOL-ÜST orijinli (y aşağı) olmalıdır.
enum AnnotationRenderer {

    static func draw(_ shapes: [AnnotationShape]) {
        for shape in shapes { draw(shape) }
    }

    static func draw(_ shape: AnnotationShape) {
        let base = shape.color.usingColorSpace(.sRGB) ?? shape.color
        let color = shape.tool == .highlighter ? base.withAlphaComponent(0.4) : base

        switch shape.tool {
        case .pen, .highlighter:
            guard shape.points.count > 1 else {
                guard let point = shape.points.first else { return }
                let radius = max(shape.lineWidth, 1) / 2
                color.setFill()
                NSBezierPath(ovalIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )).fill()
                return
            }
            let path = smoothPath(shape.points)
            path.lineWidth = shape.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()

        case .line:
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: shape.start)
            path.line(to: shape.end)
            path.lineWidth = shape.lineWidth
            path.lineCapStyle = .round
            path.stroke()

        case .arrow:
            drawArrow(shape, color: color)

        case .rect:
            color.setStroke()
            let path = NSBezierPath(rect: normalized(shape))
            path.lineWidth = shape.lineWidth
            path.lineJoinStyle = .round
            path.stroke()

        case .ellipse:
            color.setStroke()
            let path = NSBezierPath(ovalIn: normalized(shape))
            path.lineWidth = shape.lineWidth
            path.stroke()

        case .text:
            guard !shape.text.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: shape.fontSize, weight: .bold),
                .foregroundColor: color,
            ]
            NSAttributedString(string: shape.text, attributes: attributes).draw(at: shape.start)
        }
    }

    static func normalized(_ shape: AnnotationShape) -> CGRect {
        CGRect(
            x: min(shape.start.x, shape.end.x),
            y: min(shape.start.y, shape.end.y),
            width: abs(shape.end.x - shape.start.x),
            height: abs(shape.end.y - shape.start.y)
        )
    }

    private static func drawArrow(_ shape: AnnotationShape, color: NSColor) {
        let dx = shape.end.x - shape.start.x
        let dy = shape.end.y - shape.start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        let angle = atan2(dy, dx)
        let headLength = min(max(12, shape.lineWidth * 4.2), length)
        let headWidth = headLength * 0.82
        let base = CGPoint(
            x: shape.end.x - cos(angle) * headLength,
            y: shape.end.y - sin(angle) * headLength
        )
        let normal = CGPoint(x: -sin(angle), y: cos(angle))

        color.setStroke()
        let line = NSBezierPath()
        line.move(to: shape.start)
        // Gövde başlığın biraz içinde bitsin ki uç temiz görünsün
        line.line(to: CGPoint(
            x: shape.end.x - cos(angle) * headLength * 0.72,
            y: shape.end.y - sin(angle) * headLength * 0.72
        ))
        line.lineWidth = shape.lineWidth
        line.lineCapStyle = .round
        line.stroke()

        color.setFill()
        let head = NSBezierPath()
        head.move(to: shape.end)
        head.line(to: CGPoint(
            x: base.x + normal.x * headWidth / 2,
            y: base.y + normal.y * headWidth / 2
        ))
        head.line(to: CGPoint(
            x: base.x - normal.x * headWidth / 2,
            y: base.y - normal.y * headWidth / 2
        ))
        head.close()
        head.fill()
    }

    /// Serbest çizimi yumuşat (Catmull-Rom → kübik Bézier)
    private static func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        StrokePath.smooth(through: points)
    }
}

// MARK: - Pencere

final class AnnotationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Arka plan

final class AnnotationBackdropView: NSView {
    var onBackgroundClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        dirtyRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

// MARK: - Tuval

final class AnnotationCanvasView: NSView {
    private let model: AnnotationModel
    /// Çizilecek orijinal piksel görüntüsü — hiçbir ara temsil yok.
    private let originalImage: CGImage
    private var draft: AnnotationShape?
    /// Fare titreşimini süzen sabitleyici — akıcı fırça hissi verir.
    private let stabilizer = StrokeStabilizer()

    var onBeforeMouseDown: (() -> Void)?
    var onTextRequest: ((CGPoint) -> Void)?

    init(image: CGImage, model: AnnotationModel, frame: CGRect) {
        self.model = model
        self.originalImage = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == .text ? .iBeam : .crosshair)
    }

    func refreshCursor() {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Çizim

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high

        // Bu görünüm isFlipped=true (y-aşağı) çalışır; NSImage.draw(in:) ise
        // bağlama göre değişkenlik gösterip bu yolda görüntüyü TERS çiziyordu.
        // Çözüm: CGImage'i doğrudan CG bağlamına çizip y'yi elle ters çevirmek.
        // Böylece piksel uzayı ile ekran arasındaki eşleme her bağlamda aynıdır.
        //
        // cgImage(forProposedRect:context:hints:) yumuşatma/devre dışı kalmış
        // bir temsil döndürebilir; orijinal CGImage'i doğrudan tutuyoruz.
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(originalImage, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        AnnotationRenderer.draw(model.shapes)
        if let draft { AnnotationRenderer.draw(draft) }
        NSGraphicsContext.restoreGraphicsState()

        // İnce beyaz kenar
        NSColor.white.withAlphaComponent(0.45).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    // MARK: Fare

    override func mouseDown(with event: NSEvent) {
        onBeforeMouseDown?()
        let point = convert(event.locationInWindow, from: nil)
        if model.tool == .text {
            onTextRequest?(point)
            return
        }
        stabilizer.reset(with: point)
        var shape = model.makeShape(model.tool)
        shape.start = point
        shape.end = point
        shape.points = [point]
        draft = shape
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var shape = draft else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch shape.tool {
        case .pen, .highlighter:
            guard let smooth = stabilizer.add(point) else { return }
            shape.points.append(smooth)
        default:
            shape.end = point
        }
        draft = shape
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var shape = draft else { return }
        draft = nil
        let point = convert(event.locationInWindow, from: nil)
        switch shape.tool {
        case .pen, .highlighter:
            // Son ham noktayı işle ki ucun vardığı yer kaybolmasın
            if let last = shape.points.last, hypot(point.x - last.x, point.y - last.y) >= 1.0 {
                shape.points.append(point)
            }
            model.add(shape)
        default:
            shape.end = point
            let distance = hypot(shape.end.x - shape.start.x, shape.end.y - shape.start.y)
            if distance > 3 { model.add(shape) }
        }
        needsDisplay = true
    }
}

// MARK: - Araç çubuğu

struct AnnotationActions {
    var undo: () -> Void
    var redo: () -> Void
    var done: () -> Void
    var plain: () -> Void
    var cancel: () -> Void
}

struct AnnotationToolbarView: View {
    @ObservedObject var model: AnnotationModel
    let actions: AnnotationActions

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 3) {
                ForEach(AnnotationTool.allCases) { tool in
                    toolButton(tool)
                }
            }
            separator
            HStack(spacing: 5) {
                ForEach(AnnotationPalette.all) { item in
                    colorButton(item)
                }
            }
            separator
            HStack(spacing: 3) {
                ForEach(AnnotationThickness.allCases) { value in
                    thicknessButton(value)
                }
            }
            separator
            HStack(spacing: 3) {
                iconButton("arrow.uturn.backward", help: L("Geri Al (⌘Z)"), enabled: model.canUndo, action: actions.undo)
                iconButton("arrow.uturn.forward", help: L("Yinele (⇧⌘Z)"), enabled: model.canRedo, action: actions.redo)
            }
            separator
            HStack(spacing: 6) {
                primaryButton
                textButton(L("Düz Aktar"), help: L("Çizimsiz orijinali aktar (Esc)"), action: actions.plain)
                textButton(L("Vazgeç"), help: L("Hiçbir şey kaydetme (⌘.)"), tint: .red, action: actions.cancel)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            MaterialFill(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 7)
        .environment(\.colorScheme, .dark)
        .padding(14)
        .scaleEffect(appeared ? 1 : 0.88)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.7)) { appeared = true }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 22)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let selected = model.tool == tool
        return Button {
            model.tool = tool
        } label: {
            SymbolImage(name: tool.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundColor(selected ? Color.black : Color.white.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .compatHelp("\(tool.title) (\(tool.shortcut))")
    }

    private func colorButton(_ item: AnnotationColorItem) -> some View {
        let selected = model.colorIndex == item.id
        return Button {
            model.colorIndex = item.id
        } label: {
            Circle()
                .fill(item.swiftUIColor)
                .frame(width: 15, height: 15)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(item.id == 0 ? 0.45 : 0.22), lineWidth: 0.8)
                )
                .padding(2.5)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 1.6)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .compatHelp(item.title)
    }

    private func thicknessButton(_ value: AnnotationThickness) -> some View {
        let selected = model.thickness == value
        return Button {
            model.thickness = value
        } label: {
            Text(value.title)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .foregroundColor(selected ? Color.black : Color.white.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .compatHelp("\(L("Kalınlık")): \(value.title)")
    }

    private func iconButton(_ icon: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolImage(name: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 26)
                .foregroundColor(Color.white.opacity(enabled ? 0.85 : 0.28))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .compatHelp(help)
    }

    private var primaryButton: some View {
        Button(action: actions.done) {
            HStack(spacing: 5) {
                SymbolImage(name: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Text(L("Bitti"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(Color.black)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.95))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .compatHelp(L("Çizimleri uygula ve aktar (Enter)"))
    }

    private func textButton(
        _ title: String,
        help: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tint.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .compatHelp(help)
    }
}

// MARK: - Denetleyici

@MainActor
final class AnnotationEditorController {
    static let shared = AnnotationEditorController()

    private var window: AnnotationWindow?
    private var canvas: AnnotationCanvasView?
    private var backdrop: AnnotationBackdropView?
    private var model = AnnotationModel()
    private var original: CGImage?
    private var onDone: ((CGImage?) -> Void)?
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    private var textField: NSTextField?
    private var textAnchor: CGPoint?
    private var textColor: NSColor = .systemRed

    private init() {}

    var isPresenting: Bool { window != nil }

    // MARK: Sunum

    /// - anchor: Görüntü üzerine oturtulacak ekran dikdörtgeni (yakalama
    ///   bölgesi). `nil` verilirse görüntü ekranın ORTASINA yerleşir
    ///   (önizleme kartından açılan düzenleme).
    func present(
        image: CGImage,
        on screen: NSScreen,
        scale: CGFloat,
        anchor: CGRect? = nil,
        onDone: @escaping (CGImage?) -> Void
    ) {
        // Zaten bir düzenleyici açıksa yenisini düzenlemeden aktar
        guard window == nil else {
            onDone(image)
            return
        }

        let model = AnnotationModel()
        self.model = model
        self.original = image
        self.onDone = onDone

        // Araç çubuğu önce ölçülür, yerleşim ona göre yapılır
        let actions = AnnotationActions(
            undo: { [weak self] in self?.undo() },
            redo: { [weak self] in self?.redo() },
            done: { [weak self] in self?.applyAndFinish() },
            plain: { [weak self] in self?.finishWithOriginal() },
            cancel: { [weak self] in self?.finish(nil) }
        )
        let hosting = NSHostingView(rootView: AnnotationToolbarView(model: model, actions: actions))
        var toolbarSize = hosting.fittingSize
        if toolbarSize.width < 60 || toolbarSize.height < 30 {
            toolbarSize = CGSize(width: 860, height: 76)
        }

        let visible = screen.visibleFrame
        toolbarSize.width = min(toolbarSize.width, max(200, visible.width - 16))

        let pointScale = max(scale, 1)
        let pointSize = CGSize(
            width: CGFloat(image.width) / pointScale,
            height: CGFloat(image.height) / pointScale
        )

        let margin: CGFloat = 16
        let gap: CGFloat = 4
        let reserved = toolbarSize.height + gap
        var contentArea = CGRect(
            x: visible.minX + margin,
            y: visible.minY + margin + reserved,
            width: visible.width - margin * 2,
            height: visible.height - margin * 2 - reserved
        )
        // Ekran araç çubuğuna yer bırakamayacak kadar küçükse çubuk görüntünün üstüne biner
        if contentArea.height < 120 || contentArea.width < 120 {
            contentArea = visible.insetBy(dx: margin, dy: margin)
        }

        var displaySize = pointSize
        let fit = min(1, min(contentArea.width / max(pointSize.width, 1), contentArea.height / max(pointSize.height, 1)))
        if fit < 1 {
            displaySize = CGSize(
                width: max(1, floor(pointSize.width * fit)),
                height: max(1, floor(pointSize.height * fit))
            )
        }

        // Yerleşim: yakalama bölgesinin üstüne ya da (anchor yoksa) ekranın ortasına
        let anchorCenter = anchor.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: contentArea.midX, y: contentArea.midY)
        var imageRect = CGRect(
            x: anchorCenter.x - displaySize.width / 2,
            y: anchorCenter.y - displaySize.height / 2,
            width: displaySize.width,
            height: displaySize.height
        )
        imageRect.origin.x = min(max(imageRect.minX, contentArea.minX), max(contentArea.minX, contentArea.maxX - imageRect.width))
        imageRect.origin.y = min(max(imageRect.minY, contentArea.minY), max(contentArea.minY, contentArea.maxY - imageRect.height))

        // Araç çubuğu görüntünün altına, yer yoksa üstüne
        var toolbarOrigin = CGPoint(
            x: imageRect.midX - toolbarSize.width / 2,
            y: imageRect.minY + gap - toolbarSize.height
        )
        if toolbarOrigin.y < visible.minY + 2 {
            let above = imageRect.maxY - gap
            toolbarOrigin.y = (above + toolbarSize.height <= visible.maxY - 2)
                ? above
                : visible.minY + 2
        }
        toolbarOrigin.x = min(max(toolbarOrigin.x, visible.minX + 2), max(visible.minX + 2, visible.maxX - toolbarSize.width - 2))
        let toolbarRect = CGRect(origin: toolbarOrigin, size: toolbarSize)

        // Pencere
        let overlay = AnnotationWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .screenSaver
        overlay.sharingType = .none
        overlay.acceptsMouseMovedEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.animationBehavior = .none

        let backdrop = AnnotationBackdropView(frame: CGRect(origin: .zero, size: screen.frame.size))
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.onBackgroundClick = { [weak self] in self?.commitText() }
        overlay.contentView = backdrop

        let localImageRect = imageRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let canvas = AnnotationCanvasView(image: image, model: model, frame: localImageRect)
        canvas.onBeforeMouseDown = { [weak self] in self?.commitText() }
        canvas.onTextRequest = { [weak self] point in self?.beginText(at: point) }
        backdrop.addSubview(canvas)

        hosting.frame = toolbarRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        backdrop.addSubview(hosting)

        self.window = overlay
        self.canvas = canvas
        self.backdrop = backdrop

        // Araç değişince imleç güncellensin
        model.$tool
            .receive(on: RunLoop.main)
            .sink { [weak canvas] _ in canvas?.refreshCursor() }
            .store(in: &cancellables)

        overlay.alphaValue = 0
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        overlay.makeFirstResponder(canvas)
        overlay.invalidateCursorRects(for: canvas)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            overlay.animator().alphaValue = 1
        }

        installKeyMonitor()
    }

    // MARK: Klavye

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = flags.contains(.command)

        // Metin yazılırken tuşlar alana ait
        if textField != nil {
            switch event.keyCode {
            case 36, 76: // Return / Enter
                commitText()
                return true
            case 53: // Esc
                dismissTextField(commit: false)
                return true
            default:
                if command, characters == "." {
                    finish(nil)
                    return true
                }
                return false
            }
        }

        switch event.keyCode {
        case 36, 76:
            applyAndFinish()
            return true
        case 53:
            finishWithOriginal()
            return true
        default:
            break
        }

        if command, characters == "." {
            finish(nil)
            return true
        }
        if command, characters == "z" {
            if flags.contains(.shift) { redo() } else { undo() }
            return true
        }
        if !command, !flags.contains(.control), !flags.contains(.option),
           let number = Int(characters),
           let tool = AnnotationTool(rawValue: number - 1) {
            model.tool = tool
            return true
        }
        return false
    }

    // MARK: Geçmiş

    private func undo() {
        commitText()
        model.undo()
        canvas?.needsDisplay = true
    }

    private func redo() {
        commitText()
        model.redo()
        canvas?.needsDisplay = true
    }

    // MARK: Metin

    private func beginText(at point: CGPoint) {
        guard let canvas, let backdrop, let window else { return }
        commitText()

        let font = NSFont.systemFont(ofSize: model.thickness.fontSize, weight: .bold)
        let height = ceil(font.boundingRectForFont.height) + 6
        let available = max(120, canvas.bounds.width - point.x + 40)
        let width = min(360, available)

        let field = NSTextField(frame: .zero)
        field.font = font
        field.textColor = model.currentColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        field.drawsBackground = true
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.placeholderString = L("Metin")
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        // Tuval sol-üst orijinli, arka plan sol-alt orijinli
        let anchorInBackdrop = canvas.convert(point, to: backdrop)
        field.frame = CGRect(
            x: anchorInBackdrop.x - 3,
            y: anchorInBackdrop.y - height + 2,
            width: width,
            height: height
        )
        backdrop.addSubview(field)
        window.makeFirstResponder(field)

        textField = field
        textAnchor = point
        textColor = model.currentColor
    }

    private func commitText() {
        dismissTextField(commit: true)
    }

    private func dismissTextField(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        // Alan hâlâ düzenlenirken de güncel metni al
        let raw = field.currentEditor()?.string ?? field.stringValue
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if let canvas { window?.makeFirstResponder(canvas) }

        guard commit, !value.isEmpty, let anchor = textAnchor else {
            textAnchor = nil
            return
        }
        textAnchor = nil
        var shape = AnnotationShape(
            tool: .text,
            color: textColor,
            lineWidth: 0,
            fontSize: field.font?.pointSize ?? model.thickness.fontSize
        )
        shape.start = anchor
        shape.text = value
        model.add(shape)
        canvas?.needsDisplay = true
    }

    // MARK: Bitirme

    private func applyAndFinish() {
        commitText()
        guard let original else {
            finish(nil)
            return
        }
        finish(model.shapes.isEmpty ? original : (composite() ?? original))
    }

    private func finishWithOriginal() {
        dismissTextField(commit: false)
        finish(original)
    }

    /// Çizimleri tam piksel çözünürlüğünde görüntüye işler.
    private func composite() -> CGImage? {
        guard let original, let canvas, canvas.bounds.width > 0 else { return nil }
        let width = original.width
        let height = original.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))

        let shapes = model.shapes
        guard !shapes.isEmpty else { return ctx.makeImage() }

        // Görünüm noktası → piksel eşlemesi (ölçekli gösterimde de doğru)
        let pixelsPerPoint = CGFloat(width) / canvas.bounds.width

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)                     // sol-üst orijin, y aşağı
        ctx.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        AnnotationRenderer.draw(shapes)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private func finish(_ image: CGImage?) {
        guard let overlay = window else { return }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        cancellables.removeAll()
        textField?.removeFromSuperview()
        textField = nil
        textAnchor = nil

        window = nil
        canvas = nil
        backdrop = nil
        original = nil
        overlay.orderOut(nil)
        overlay.contentView = nil

        let completion = onDone
        onDone = nil
        completion?(image)
    }
}
