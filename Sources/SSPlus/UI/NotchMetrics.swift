import AppKit

/// Ekranın çentik (notch) ölçüleri — punto cinsinden, **global** koordinatta.
///
/// Değerler tamamen `NSScreen`'den dinamik okunur; hiçbir Mac modeli için sabit
/// ölçü gömülmez. Çentiğin dikdörtgeni, genişlikleri toplayıp çıkararak değil,
/// menü çubuğunun sol/sağ yardımcı alanlarının **gerçek kenarlarından** kurulur:
///
///     sol kenar  = auxiliaryTopLeftArea.maxX
///     sağ kenar  = auxiliaryTopRightArea.minX
///     üst kenar  = screen.frame.maxY
///     yükseklik  = yardımcı alanların yüksekliği (== safeAreaInsets.top)
///
/// Böylece iki yardımcı alan eşit genişlikte olmadığında (ör. 16" MacBook Pro'da
/// sol 771 / sağ 772) ortaya çıkan yarım puntoluk kayma yaşanmaz: ekranın orta
/// noktası çentiğin orta noktası DEĞİLDİR.
struct NotchMetrics: Equatable {
    /// Ölçümün alındığı ekranın global çerçevesi.
    let screenFrame: CGRect
    /// Çentiğin global (alt-sol orijinli) dikdörtgeni. Çentik yoksa `.zero`.
    let notchRect: CGRect
    /// Menü çubuğu şeridinin yüksekliği. Çentiksiz Mac'lerde de geçerlidir.
    let menuBarHeight: CGFloat

    var hasNotch: Bool { notchRect.width > 1 && notchRect.height > 1 }
    /// Çentiğin genişliği. Çentik yoksa 0.
    var notchWidth: CGFloat { notchRect.width }
    /// Çentiğin (ya da çentiksiz Mac'lerde menü çubuğu şeridinin) yüksekliği.
    var notchHeight: CGFloat { hasNotch ? notchRect.height : menuBarHeight }
    /// Çentiğin alt kenarı: açılan panelin İÇERİĞİ daima bu çizginin altındadır.
    var notchBottomY: CGFloat { notchRect.minY }

    /// Çentiğin ALT köşelerinin yarıçapı.
    ///
    /// Fiziksel çentiğin alt köşeleri yuvarlaktır. Ada çentiği kaplayıp iki yana
    /// taştığı için bu yarıçap, gövdenin çentik oyuğuna oturan iç köşelerinde
    /// kullanılır; tutmadığında çentiğin kenarında ince bir "basamak" görünür.
    /// Ölçü punto cinsindendir ve çentik yüksekliğiyle orantılıdır (Apple'ın
    /// bütün çentikli modellerinde oran neredeyse aynıdır).
    var notchCornerRadius: CGFloat {
        guard hasNotch else { return 0 }
        return min(max(notchRect.height * 0.28, 4), 10).rounded()
    }

    /// Ölçülen çentiğin hangi MacBook ailesine denk geldiği.
    ///
    /// Yerleşim tamamen dinamik ölçüme dayanır; bu sınıflandırma yalnızca kanat
    /// genişliği gibi tasarım kararlarını modele göre ayarlamak ve ölçüm saçma
    /// bir değer verdiğinde makul bir değere çekmek için kullanılır.
    enum Family: String {
        /// 13"/15" MacBook Air (M2–M4) — görece dar çentik.
        case air = "MacBook Air"
        /// 14"/16" MacBook Pro (M1 Pro ve sonrası) — geniş çentik.
        case pro = "MacBook Pro"
        /// Çentikli ama tanınmayan bir model (yeni donanım / sıra dışı çözünürlük).
        case unknown = "Çentikli Mac"
    }

    /// Çentik genişliğinin ekran genişliğine oranından model ailesini kestirir.
    ///
    /// Oran kullanılır çünkü kullanıcı çözünürlüğü ("Daha Fazla Alan" vb.)
    /// değiştirdiğinde punto ölçüleri değişir ama oran sabit kalır:
    ///   14"/16" Pro  → ~0.107   (1728 pt ekranda 185 pt çentik)
    ///   13"/15" Air  → ~0.117
    var family: Family {
        guard hasNotch, screenFrame.width > 1 else { return .unknown }
        let ratio = notchRect.width / screenFrame.width
        switch ratio {
        case ..<0.113: return .pro
        case ..<0.128: return .air
        default:       return .unknown
        }
    }

    /// Çentiğin iki yanında kalan boş menü çubuğu şeridinin genişliği.
    /// Ada kanatları bu genişliği aşarsa ekrandan taşar.
    var availableWingWidth: CGFloat {
        guard hasNotch else { return 0 }
        return min(notchRect.minX - screenFrame.minX, screenFrame.maxX - notchRect.maxX)
    }

    /// Ekran hiç bulunamadığında kullanılacak nötr ölçü.
    static let fallback = NotchMetrics(screenFrame: .zero, notchRect: .zero, menuBarHeight: 24)

    // MARK: - Ölçüm

    /// Verilen ekranın çentik ölçülerini hesaplar.
    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let frame = screen.frame

        // Menü çubuğu şeridi. `visibleFrame` menü çubuğunun altında 1 puntoluk
        // pay bırakır; çentikli Mac'lerde asıl doğru kaynak safeAreaInsets.top
        // (macOS 12+; daha eski sürümlerde çentikli Mac yoktur).
        let safeTop: CGFloat
        if #available(macOS 12, *) { safeTop = screen.safeAreaInsets.top } else { safeTop = 0 }
        let strip = frame.maxY - screen.visibleFrame.maxY
        let menuBarHeight: CGFloat
        if safeTop > 0 {
            menuBarHeight = safeTop
        } else {
            menuBarHeight = min(max(strip.rounded(), 20), 44)
        }

        // Çentik yalnızca güvenli alan payı VE iki yardımcı alan birden
        // bildirildiğinde vardır.
        guard #available(macOS 12, *), safeTop > 0,
              let rawLeft = screen.auxiliaryTopLeftArea,
              let rawRight = screen.auxiliaryTopRightArea
        else {
            return NotchMetrics(screenFrame: frame, notchRect: .zero, menuBarHeight: menuBarHeight)
        }

        let left = globalized(rawLeft, on: frame)
        let right = globalized(rawRight, on: frame)

        // Yükseklik: yardımcı alanların kendi yüksekliği en güvenilir kaynaktır
        // (menü çubuğunun çentiğe komşu şeridi birebir bu yüksekliktedir).
        let height = max(max(left.height, right.height), safeTop)
        let width = right.minX - left.maxX
        guard width > 1, height > 1 else {
            return NotchMetrics(screenFrame: frame, notchRect: .zero, menuBarHeight: menuBarHeight)
        }

        let notch = CGRect(
            x: left.maxX,
            y: frame.maxY - height,
            width: width,
            height: height
        )
        return NotchMetrics(screenFrame: frame, notchRect: notch, menuBarHeight: height)
    }

    /// Yardımcı alanlar ekranın kendi uzayında gelebilir; global uzaya taşır.
    ///
    /// Birincil ekranda iki uzay çakıştığı için fark etmez; harici monitör
    /// bağlıyken dahili ekranın orijini (0,0) olmayabilir.
    private static func globalized(_ rect: CGRect, on frame: CGRect) -> CGRect {
        // Üst kenarı zaten ekranın tepesindeyse dokunma.
        if abs(rect.maxY - frame.maxY) <= 1 { return rect }
        return rect.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    // MARK: - Ekran seçimi

    /// Island'ın yerleşeceği ekran: çentiği olan (dahili) ekran varsa o, yoksa ana ekran.
    ///
    /// Harici monitör birincil yapıldığında `NSScreen.screens.first` dahili ekran
    /// olmayabilir; çentik uygulaması daima çentiğin bulunduğu ekrana oturmalıdır.
    static func hostScreen() -> NSScreen? {
        if #available(macOS 12, *), let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Island'ın yerleştiği ekranın ölçüleri.
    static func primary() -> NotchMetrics {
        guard let screen = hostScreen() else { return .fallback }
        return metrics(for: screen)
    }

    /// Hizalama testi ve hata ayıklama için okunabilir özet.
    var debugSummary: String {
        guard hasNotch else {
            return "Çentik yok · ekran \(Int(screenFrame.width))×\(Int(screenFrame.height))"
            + " · menü çubuğu \(fmt(menuBarHeight))"
        }
        return """
        çentik  x \(fmt(notchRect.minX)) → \(fmt(notchRect.maxX))   \
        y \(fmt(notchRect.minY)) → \(fmt(notchRect.maxY))
        ölçü    \(fmt(notchRect.width)) × \(fmt(notchRect.height)) pt   \
        merkez x \(fmt(notchRect.midX))   (ekran merkezi \(fmt(screenFrame.midX)))
        ekran   \(fmt(screenFrame.width)) × \(fmt(screenFrame.height)) pt   \
        menü çubuğu \(fmt(menuBarHeight)) pt
        """
    }

    private func fmt(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}
