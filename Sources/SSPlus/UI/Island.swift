import AppKit
import SwiftUI
import Combine

// MARK: - Ortak ölçüler

enum IslandLayout {
    /// Panelin ekranın ÜST kenarından yukarı taşma payı.
    ///
    /// macOS 26'da, üst kenarı tam `screen.frame.maxY`'ye oturan pencerelerle
    /// çentik arasında saç teli kalınlığında bir boşluk görülebiliyor. Çözüm
    /// (Atoll #681 / PR #715) pencereyi ekranın birkaç punto YUKARISINA taşırıp
    /// içeriği aynı miktarda aşağı itmek: içerik yerinden oynamaz, dikiş kapanır.
    static let topBleed: CGFloat = 4
}

// MARK: - Gözlemlenebilir durum

/// SwiftUI'nin island'ın açık/kapalı durumunu ve çentik ölçülerini izleyebilmesi için küçük model.
final class IslandUIModel: ObservableObject {
    @Published var expanded = false
    /// Yerleşimin etrafından dolaşacağı çentik ölçüleri.
    @Published var metrics: NotchMetrics = .fallback
}

// MARK: - Denetleyici

@MainActor
final class IslandController {
    static let shared = IslandController()

    let ui = IslandUIModel()

    private var panel: NSPanel?
    private var trackingView: IslandTrackingView?
    private var cancellables = Set<AnyCancellable>()
    private var collapseWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?

    /// Kazara temasla açılmaması için gereken KESİNTİSİZ bekleme süresi.
    private static let hoverDwell: TimeInterval = 1.2
    private var dwellWorkItem: DispatchWorkItem?

    private(set) var hovering = false
    var pinned = false {
        didSet { refreshFrame() }
    }

    private init() {}

    private var targetScreen: NSScreen? {
        NotchMetrics.hostScreen()
    }

    private var currentMetrics: NotchMetrics {
        guard let screen = targetScreen else { return .fallback }
        return NotchMetrics.metrics(for: screen)
    }

    /// Ada boştayken yalnızca ayar açıksa görünür; kayıt/seçim sırasında daima görünür.
    private var shouldBeVisible: Bool {
        if case .idle = AppState.shared.phase {
            return SettingsStore.shared.islandEnabled
        }
        return true
    }

    private enum Layout {
        // Çentiksiz Mac'ler: menü çubuğunun ALTINA oturan klasik ada.
        static let plainCollapsed = CGSize(width: 210, height: 34)
        static let plainExpanded = CGSize(width: 500, height: 200)
        static let plainSelecting = CGSize(width: 480, height: 54)
        static let plainRecording = CGSize(width: 340, height: 50)

        // Çentikli Mac'ler: ada çentiği KAPLAR ve iki yana taşar. İçerik
        // çentiğin solunda ve sağında kalan "kanatlara" yerleşir; çentiğin
        // kendisine denk gelen orta oyukta hiçbir şey çizilmez (orası fiziksel
        // olarak kamera muhafazası — oraya çizilen her şey görünmez olur).
        //
        // Kanat genişliği çentiğin BİR yanı içindir; panel genişliği
        // çentik + 2 × kanat olur, böylece gövde çentiğe göre simetriktir.
        static let expandedWing: CGFloat = 200
        static let selectingWing: CGFloat = 236
        static let recordingWing: CGFloat = 168
        /// Sistem sesi düzeyi göstergesi kayıt hâlinde iki kanadı da genişletir.
        static let audioMeterExtra: CGFloat = 52
        /// Kanadın ekran kenarına bırakması gereken en küçük pay.
        static let wingEdgeInset: CGFloat = 10

        /// Çentiğin ALTINA inen ek içerik yüksekliği. Seçim ve kayıt hâlleri
        /// tümüyle kanatlara sığar; yalnızca açık ada aşağı sarkar.
        static let expandedDrop: CGFloat = 190
        static let selectingDrop: CGFloat = 0
        static let recordingDrop: CGFloat = 0
    }

    /// Açılışta çağrılır: gözlemcileri kurar; paneli yalnızca görünmesi gerektiğinde
    /// oluşturur (ada boşta gizliyse bellekte SwiftUI paneli tutulmaz).
    func show() {
        subscribeIfNeeded()
        refreshFrame()
    }

    private var subscribed = false

    private func subscribeIfNeeded() {
        guard !subscribed else { return }
        subscribed = true

        AppState.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                // Yakalama/kayıt başlayınca sabitlemeyi bırak ki iş bitince ada toparlansın.
                if phase != .idle, self.pinned {
                    self.pinned = false
                } else {
                    self.refreshFrame()
                }
            }
            .store(in: &cancellables)

        // Ayarlardan ada anahtarı değişince görünürlüğü tazele
        SettingsStore.shared.$islandEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrame() }
            .store(in: &cancellables)

        // Ekran değişimlerinde (harici monitör, çözünürlük, menü çubuğu) ölçüleri tazele.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                IslandController.shared.refreshFrame()
            }
        }
    }

    /// Paneli (ve SwiftUI barındırma görünümünü) gerektiğinde kurar.
    private func ensurePanel() {
        guard panel == nil, let screen = targetScreen else { return }
        ui.metrics = currentMetrics

        let panel = IslandPanel(
            contentRect: targetFrame(metrics: ui.metrics),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        // İçerik daima koyu zemin üzerinde: sistem açık temadayken de ada siyah kalır.
        panel.appearance = NSAppearance(named: .darkAqua)

        let tracking = IslandTrackingView(frame: NSRect(origin: .zero, size: screen.frame.size))
        tracking.onEnter = { [weak self] in self?.hoverEntered() }
        tracking.onExit = { [weak self] in self?.hoverExited() }

        let hosting = NSHostingView(rootView: IslandView())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        tracking.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: tracking.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: tracking.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: tracking.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: tracking.trailingAnchor),
        ])

        panel.contentView = tracking
        panel.orderFrontRegardless()
        self.panel = panel
        self.trackingView = tracking
        ui.expanded = isExpanded
    }

    /// Ada gizlenince paneli tümüyle bırak: barındırma görünümü ve katmanları belleğe geri döner.
    private func destroyPanel() {
        dwellWorkItem?.cancel()
        dwellWorkItem = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        hovering = false
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        trackingView = nil
    }

    var isExpanded: Bool {
        if case .idle = AppState.shared.phase {
            return hovering || pinned
        }
        return true
    }

    // MARK: Hover (beklemeli açılma)

    /// Fare adanın üstüne geldi: HEMEN açma — kazara geçişlerde ada kımıldamaz.
    /// İmleç `hoverDwell` süre kesintisiz üstte kalırsa açılır.
    private func hoverEntered() {
        collapseWorkItem?.cancel()
        guard !hovering, !pinned else { return }
        guard case .idle = AppState.shared.phase, SettingsStore.shared.islandEnabled else { return }
        dwellWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.hovering = true
                self.refreshFrame()
            }
        }
        dwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell, execute: work)
    }

    private func hoverExited() {
        // Dwell tamamlanmadan çıkıldıysa açılma hiç yaşanmaz
        dwellWorkItem?.cancel()
        dwellWorkItem = nil
        guard hovering else { return }
        collapseWorkItem?.cancel()
        // Sabitlenmişse hemen kapanmasın; imleç uzaklaştıktan bir süre sonra toparlansın.
        let delay: TimeInterval = pinned ? 2.5 : 0.35
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hovering = false
            if self.pinned {
                self.pinned = false
            } else {
                self.refreshFrame()
            }
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func collapse() {
        hovering = false
        dwellWorkItem?.cancel()
        collapseWorkItem?.cancel()
        if pinned {
            pinned = false   // didSet → refreshFrame
        } else {
            refreshFrame()
        }
    }

    // MARK: Ölçüler

    /// Panelin ekrandaki hedef çerçevesi.
    ///
    /// Çentikli Mac'lerde:
    ///  • **Kapalı** hâlde panel BİREBİR çentik dikdörtgenidir — bir punto bile
    ///    taşmaz, hiçbir şey çizmez; çentiğe karışıp görünmez olur.
    ///  • Açık / seçim / kayıt hâllerinde panelin üst kenarı çentiğin üst
    ///    kenarına yapışıktır, çentik kadarlık üst şerit ölü bölgedir ve tüm
    ///    içerik çentiğin ALTINDA kalır. Yatay merkez ekranın değil, **çentiğin**
    ///    merkezidir.
    private func targetFrame(metrics m: NotchMetrics) -> CGRect {
        guard let screen = targetScreen else { return .zero }
        let phase = AppState.shared.phase

        // Çentiksiz Mac: menü çubuğunun ALTINA oturan klasik ada.
        guard m.hasNotch else {
            var size: CGSize
            switch phase {
            case .idle:      size = isExpanded ? Layout.plainExpanded : Layout.plainCollapsed
            case .selecting: size = Layout.plainSelecting
            case .recording:
                size = Layout.plainRecording
                if AppState.shared.recordingAudioActive { size.width += Layout.audioMeterExtra }
            }
            let width = size.width.rounded()
            let height = size.height.rounded()
            return CGRect(
                x: (screen.frame.midX - width / 2).rounded(),
                y: screen.frame.maxY - m.menuBarHeight - height,
                width: width,
                height: height
            )
        }

        // Kapalı: çentiğin ta kendisi. Yuvarlama YOK, pay YOK — ölçüm neyse o.
        // Hiçbir şey çizilmediği için görünmez; yalnızca üzerine gelme alanıdır.
        if case .idle = phase, !isExpanded {
            return m.notchRect
        }

        let bleed = IslandLayout.topBleed
        let wing = Self.wingWidth(for: phase, metrics: m)
        let drop: CGFloat
        switch phase {
        case .idle:      drop = Layout.expandedDrop
        case .selecting: drop = Layout.selectingDrop
        case .recording: drop = Layout.recordingDrop
        }

        // Panel çentiği ortalar: genişlik = çentik + iki kanat. Yatay merkez
        // ekranın değil ÇENTİĞİN merkezidir (ikisi yarım punto kayıktır).
        let width = (m.notchRect.width + wing * 2).rounded()
        let height = (m.notchRect.height + bleed + drop).rounded()
        return CGRect(
            x: (m.notchRect.midX - width / 2).rounded(),
            y: m.notchRect.maxY + bleed - height,
            width: width,
            height: height
        )
    }

    /// Çentiğin bir yanındaki kanat genişliği.
    ///
    /// İstenen genişlik ekranda gerçekten boş olan şeritten (`availableWingWidth`)
    /// taşamaz; taşarsa kırpılır. Böylece dar çentikli / küçük ekranlı modellerde
    /// ada ekran dışına sarkmaz.
    static func wingWidth(for phase: AppState.Phase, metrics m: NotchMetrics) -> CGFloat {
        var wanted: CGFloat
        switch phase {
        case .idle:      wanted = Layout.expandedWing
        case .selecting: wanted = Layout.selectingWing
        case .recording:
            wanted = Layout.recordingWing
            if AppState.shared.recordingAudioActive { wanted += Layout.audioMeterExtra }
        }
        // MacBook Air'ın çentiği görece geniş, kanatları dardır; birkaç punto
        // daha sıkı bir yerleşim taşmayı önler.
        if m.family == .air { wanted -= 8 }
        let room = m.availableWingWidth - Layout.wingEdgeInset
        guard room > 0 else { return wanted }
        return min(wanted, room).rounded()
    }

    private func refreshFrame() {
        // SwiftUI'yi haberdar et (hover / pinned / phase / ekran değişimleri)
        let metrics = currentMetrics
        if ui.metrics != metrics {
            ui.metrics = metrics
        }
        let expanded = isExpanded
        if ui.expanded != expanded {
            ui.expanded = expanded
        }

        // Ayar kapalıyken ada boşta tümüyle kaldırılır (kayıt/seçimde daima görünür)
        if shouldBeVisible {
            ensurePanel()
        } else {
            destroyPanel()
            return
        }
        guard let panel else { return }

        // Seçim sırasında island, overlay'in üstünde HUD olarak kalsın
        if case .selecting = AppState.shared.phase {
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        } else {
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        }

        let target = targetFrame(metrics: metrics)
        guard panel.frame != target else { return }
        animateFrame(of: panel, to: target)
    }

    // MARK: Animasyon

    /// Tek evreli yumuşak geçiş.
    ///
    /// Eskiden açılma iki evreliydi ve ikinci evre yalnızca ilk animasyonun
    /// completion handler'ından tetikleniyordu; hızlı hover giriş-çıkışlarında
    /// o handler düşünce ada YARIM BOYDA TAKILI kalıyordu. Tek evrede animasyon
    /// kesintiye uğrasa da hedef daima geçerlidir; ada asla ara boyutta kalmaz.
    private func animateFrame(of panel: NSPanel, to target: CGRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.24, 0.9, 0.28, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }
}

// MARK: - Panel

/// Ekranın üst kenarından yukarı taşabilen panel.
///
/// AppKit, `setFrame` ile verilen çerçeveyi normalde ekranın görünür alanına
/// sıkıştırır. Ada çentiğe dikişsiz yapışabilmek için birkaç punto yukarı
/// taşmak zorunda olduğundan bu kısıtlama devre dışı bırakılır.
final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Hover takibi

final class IslandTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

// MARK: - Geçişler

private extension AnyTransition {
    /// İçerik çentiğin altından "iniyormuş" gibi belirir; yanlara kayma yok.
    static var islandDescend: AnyTransition {
        .opacity.combined(with: .offset(y: -8))
    }

    /// Seçim HUD'u için yaylı ölçek + solma girişi.
    static var islandPop: AnyTransition {
        .scale(scale: 0.92)
            .combined(with: .opacity)
            .combined(with: .offset(y: -8))
    }
}

// MARK: - SwiftUI içerik

struct IslandView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var ui = IslandController.shared.ui
    @ObservedObject private var settings = SettingsStore.shared

    private var metrics: NotchMetrics { ui.metrics }

    /// Animasyonu tetikleyen tek anahtar (faz + açık/kapalı).
    private var layoutKey: String {
        switch app.phase {
        case .idle: return ui.expanded ? "expanded" : "collapsed"
        case .selecting: return "selecting"
        case .recording: return "recording"
        }
    }

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchedBody
            } else {
                plainBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .compatAnimation(.spring(response: 0.34, dampingFraction: 0.86), value: layoutKey)
    }

    /// Çentiği KAPLAYAN gövde: üst kenarı ekranın tepesine yapışıktır (üst
    /// köşeler düz), alt köşeler yuvarlaktır. Siyah gövde fiziksel çentikle
    /// kesintisiz birleşir; çentiğin iki yanındaki menü çubuğu şeridi adanın
    /// kanatlarıyla örtülür.
    ///
    /// Kontur YOK: 0.5 punto beyaz saç teli, gövdenin çentikle birleştiği yerde
    /// görünür bir çizgi bırakır ve hizasızlık izlenimi verir. Gölge aşağı
    /// yönlüdür (yarıçap < kaydırma) — menü çubuğunun üzerine hâle düşmez.
    private var coveringShape: some View {
        BottomRoundedRectangle(radius: isExpandedIdle ? 22 : 16)
            .fill(Color.black)
            .shadow(color: .black.opacity(0.38), radius: 10, y: 8)
    }

    /// Çentiksiz Mac'lerde menü çubuğunun altında duran serbest ada.
    private var floatingShape: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    // MARK: - Çentikli yerleşim

    /// Kapalı ve boştaysa ada tümüyle görünmezdir.
    private var isCollapsedIdle: Bool {
        if case .idle = app.phase { return !ui.expanded }
        return false
    }

    /// Panelin ekranın üst kenarından yukarı taşan payı. Burada hiçbir şey
    /// çizilmez; içerik bu kadar aşağı itilir ki çentikle arada dikiş kalmasın.
    private var topBleedHeight: CGFloat {
        isCollapsedIdle ? 0 : IslandLayout.topBleed
    }

    private var notchedBody: some View {
        Group {
            if isCollapsedIdle {
                // KAPALI: panel birebir çentik boyundadır ve hiçbir şey
                // çizilmez; ada çentiğe karışıp tümüyle görünmez olur.
                Color.clear
            } else {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: topBleedHeight)
                        .allowsHitTesting(false)

                    // Çentik şeridi: içerik yalnızca iki kanatta.
                    notchRow
                        .frame(height: metrics.notchHeight)

                    // Yalnızca açık adada: çentiğin altına sarkan bölüm.
                    if isExpandedIdle {
                        notchedDrop
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(coveringShape)
                .transition(app.phase.isSelecting ? .islandPop : .islandDescend)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { IslandController.shared.pinned = true }
    }

    private var isExpandedIdle: Bool {
        if case .idle = app.phase { return ui.expanded }
        return false
    }

    /// Çentik hizasındaki satır. Ortadaki oyuk BİREBİR çentik genişliğindedir ve
    /// boş bırakılır; içerik yalnızca soldaki ve sağdaki kanatlara yerleşir.
    @ViewBuilder
    private var notchRow: some View {
        HStack(spacing: 0) {
            wing(alignment: .leading) { leftWingContent }

            // ÇENTİK OYUĞU — buraya hiçbir şey çizilmez.
            Color.clear
                .frame(width: metrics.notchWidth)
                .allowsHitTesting(false)

            wing(alignment: .trailing) { rightWingContent }
        }
    }

    private func wing<Content: View>(
        alignment: Alignment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(alignment == .leading ? .leading : .trailing, 13)
            .clipped()
    }

    @ViewBuilder
    private var leftWingContent: some View {
        switch app.phase {
        case .idle:
            HStack(spacing: 7) {
                SSPlusLogoView(size: 16)
                Text("SS+")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        case let .selecting(mode, style):
            selectingLeading(mode: mode, style: style)
        case .recording:
            HStack(spacing: 8) {
                PulsingDot()
                Text(app.recordingTimeString)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                if app.recordingAudioActive {
                    AudioLevelMeter(level: app.audioLevel, mic: app.recordingMicActive)
                }
            }
        }
    }

    @ViewBuilder
    private var rightWingContent: some View {
        switch app.phase {
        case .idle:
            settingsButton
        case let .selecting(mode, style):
            selectingTrailing(mode: mode, style: style)
        case .recording:
            HStack(spacing: 8) {
                drawToggleButton
                stopButton(compact: true)
            }
        }
    }

    /// Açık adanın çentik altına sarkan bölümü: araç sırası + pano şeridi.
    private var notchedDrop: some View {
        VStack(spacing: 0) {
            toolRow
                .padding(.horizontal, 14)
                .padding(.top, 10)

            ClipboardStripView()
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Çentiksiz yerleşim (klasik ada)

    private var plainBody: some View {
        plainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(floatingShape)
            .contentShape(Rectangle())
            .onTapGesture { IslandController.shared.pinned = true }
    }

    @ViewBuilder
    private var plainContent: some View {
        switch app.phase {
        case .idle:
            if ui.expanded {
                expandedContent.transition(.islandDescend)
            } else {
                plainCollapsed.transition(.islandDescend)
            }
        case let .selecting(mode, style):
            selectingRow(mode: mode, style: style)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.islandPop)
        case .recording:
            plainRecording.transition(.islandDescend)
        }
    }

    private var plainCollapsed: some View {
        HStack(spacing: 7) {
            SSPlusLogoView(size: 15)
            Text("SS+")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Açık içerik (ortak)

    /// Açık ada: başlık satırı, kompakt araçlar ve pano geçmişi şeridi.
    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    SSPlusLogoView(size: 17)
                    Text("SS+")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer(minLength: 8)
                settingsButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 9)

            toolRow
                .padding(.horizontal, 14)
                .padding(.top, 9)

            ClipboardStripView()
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
    }

    private var plainRecording: some View {
        HStack(spacing: 10) {
            PulsingDot()
            Text("REC")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(.red)
            Text(app.recordingTimeString)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            if app.recordingAudioActive { AudioLevelMeter(level: app.audioLevel, mic: app.recordingMicActive) }
            Spacer()
            drawToggleButton
            stopButton(compact: false)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ortak parçalar

    private var toolRow: some View {
        HStack(spacing: 8) {
            IslandToolButton(icon: "rectangle.dashed", title: L("Alan"), shortcut: settings.captureHotkey.display) {
                AppState.shared.beginCapture(.rect)
            }
            IslandToolButton(icon: "macwindow", title: L("Pencere"), shortcut: "W") {
                AppState.shared.beginCapture(.window)
            }
            IslandToolButton(icon: "display", title: L("Ekran"), shortcut: "↩") {
                AppState.shared.captureFullScreen()
            }
            IslandToolButton(icon: "record.circle", title: L("Kayıt"), shortcut: settings.recordHotkey.display, tint: .red) {
                AppState.shared.beginRecordingSelection()
            }
        }
    }

    private var settingsButton: some View {
        Button {
            SettingsWindowController.shared.show()
        } label: {
            SymbolImage(name: "gearshape.fill")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .compatHelp(L("Ayarlar"))
    }

    /// Kayıt sırasında ekrana çizim katmanını aç/kapat.
    private var drawToggleButton: some View {
        Button {
            NotificationCenter.default.post(name: .ssPlusToggleDrawOverlay, object: nil)
        } label: {
            SymbolImage(name: "pencil.tip.crop.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .compatHelp(L("Kayıt sırasında çiz"))
    }

    private func stopButton(compact: Bool) -> some View {
        Button {
            AppState.shared.stopRecording()
        } label: {
            HStack(spacing: 5) {
                SymbolImage(name: "stop.fill")
                    .font(.system(size: compact ? 9 : 10, weight: .bold))
                Text(L("Durdur"))
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 4.5 : 6)
            .background(Capsule().fill(Color.red))
            .foregroundColor(.white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .compatHelp(L("Kaydı durdur"))
    }

    // MARK: Seçim satırı

    /// Çentikli yerleşimde seçim ipucunun SOL kanada düşen yarısı: ne yapılacağı.
    @ViewBuilder
    private func selectingLeading(mode: SelectionMode, style: SelectionStyle) -> some View {
        if style == .recording {
            CompatLabel(title: L("Kayıt alanı seç"), systemImage: "record.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.red)
        } else {
            Text(mode.hint)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    /// SAĞ kanat: kip düğmeleri ve çıkış ipucu.
    @ViewBuilder
    private func selectingTrailing(mode: SelectionMode, style: SelectionStyle) -> some View {
        HStack(spacing: 7) {
            if style == .recording {
                Text(L("↩ tüm ekran"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                hudModeChip("R", L("Alan"), active: mode == .rect) { switchMode(.rect) }
                hudModeChip("W", L("Pencere"), active: mode == .window) { switchMode(.window) }
            }
            Text(L("Esc"))
                .font(.system(size: 10.5))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func selectingRow(mode: SelectionMode, style: SelectionStyle) -> some View {
        HStack(spacing: 10) {
            if style == .recording {
                CompatLabel(title: L("Kayıt alanı seç"), systemImage: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
                Text(L("↩ tüm ekran"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                Text(mode.hint)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                HStack(spacing: 6) {
                    hudModeChip("R", L("Alan"), active: mode == .rect) { switchMode(.rect) }
                    hudModeChip("W", L("Pencere"), active: mode == .window) { switchMode(.window) }
                }
            }
            Text(L("Esc iptal"))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
    }

    private func switchMode(_ mode: SelectionMode) {
        SelectionOverlayController.shared.setMode(mode)
    }

    private func hudModeChip(_ key: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(key)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.15)))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(active ? Color.purple.opacity(0.55) : Color.white.opacity(0.07))
            )
            .foregroundColor(.white.opacity(active ? 1 : 0.65))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pano şeridi

/// Adanın açık hâlinde görünen son kopyalamalar şeridi.
/// Tıklanan öğe panoya geri yazılır; kısa bir onay işareti belirir.
struct ClipboardStripView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(L("PANO"))
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .compatTracking(1)
                    .foregroundColor(.white.opacity(0.35))
                Spacer()
                if !store.entries.isEmpty {
                    Button {
                        store.clear()
                    } label: {
                        Text(L("Temizle"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .compatHelp(L("Pano geçmişini temizle"))
                }
            }

            if store.entries.isEmpty {
                Text(settings.clipboardHistoryEnabled
                     ? L("Kopyaladıkların burada birikir")
                     : L("Pano geçmişi kapalı · Ayarlar → Genel'den aç"))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.28))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(store.entries) { entry in
                            card(for: entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func card(for entry: ClipboardEntry) -> some View {
        Button {
            store.recopy(entry)
            copiedID = entry.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if copiedID == entry.id { copiedID = nil }
            }
        } label: {
            ZStack {
                cardContent(for: entry)
                if copiedID == entry.id {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                    SymbolImage(name: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.green)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .compatHelp(entry.kind == .text ? L("Metni panoya geri kopyala") : L("Görseli panoya geri kopyala"))
    }

    @ViewBuilder
    private func cardContent(for entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .image:
            if let thumb = store.thumbnail(for: entry) {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipped()
            } else {
                SymbolImage(name: "photo")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.06))
            }
        case .text:
            HStack(alignment: .top, spacing: 5) {
                SymbolImage(name: "text.quote")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.top, 2)
                Text(entry.text ?? "")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(6)
            .frame(width: 108, height: 52, alignment: .topLeading)
            .background(Color.white.opacity(0.06))
        }
    }
}

// MARK: - Araç düğmesi

struct IslandToolButton: View {
    let icon: String
    let title: String
    let shortcut: String
    var tint: Color = .white
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                SymbolImage(name: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(tint == .red ? Color.red : Color.white)
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text(shortcut)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(hovering ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) {
                hovering = inside
            }
        }
    }
}

// MARK: - Kayıt noktası animasyonu

struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(pulsing ? 0.35 : 1)
            .compatAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// Kayıtta sistem sesi düzeyi — macOS "Giriş düzeyi" göstergesi tarzında: hoparlör simgesi +
/// eşit boyda bir sıra dikey hap (segment) soldan sağa dolar. `level` 0…1 (−60…0 dBFS);
/// sessizlikte tüm segmentler sönük kalır. Dolan segmentler tepeye yaklaştıkça sararıp kızarır.
struct AudioLevelMeter: View {
    var level: Float
    var mic = false
    private let segmentCount = 14

    var body: some View {
        HStack(spacing: 4) {
            SymbolImage(name: mic ? "mic.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            HStack(spacing: 2) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(color(for: index))
                        .frame(width: 3, height: 12)
                }
            }
        }
        .frame(height: 16)
        .compatAnimation(.linear(duration: 0.06), value: level)
        .compatHelp(L("Ses düzeyi"))
    }

    /// Segment dolu mu? Doluysa konumuna göre yeşil / sarı / kırmızı; değilse sönük.
    private func color(for index: Int) -> Color {
        let lit = Int((level * Float(segmentCount)).rounded(.down))
        guard index < lit else { return Color.white.opacity(0.16) }
        switch Double(index) / Double(segmentCount) {
        case ..<0.7: return Color.green
        case ..<0.85: return Color.yellow
        default: return Color.red
        }
    }
}
