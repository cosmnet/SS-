import AppKit
import Combine
@preconcurrency import Vision

@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()

    @Published var isPro: Bool {
        didSet { UserDefaults.standard.set(isPro, forKey: "isPro") }
    }

    static var features: [(icon: String, title: String, detail: String)] {[
        ("text.viewfinder", L("Metin Kopyala (OCR)"), L("Ekran görüntüsündeki yazıyı tek tıkla panoya al")),
        ("speedometer", L("60 FPS Video"), L("Akıcı, yüksek kare hızında ekran kaydı")),
        ("speaker.wave.2.fill", L("Ses Kaydı"), L("Video kaydına sistem sesini ve mikrofonu dahil et")),
        ("film", L("HEVC ve özel bit hızı"), L("Daha küçük dosya, daha yüksek kalite")),
        ("scroll", L("Kaydırmalı Yakalama"), L("Uzun sayfaları tek görüntüde birleştir (yakında)")),
    ]}

    /// Pro'yu açan kodlar. Karşılaştırma büyük/küçük harf ve boşluk duyarsızdır.
    private static let validCodes: Set<String> = ["cefri", "cemtest"]

    /// Kilidi açan kod girildiyse saklanır; Ayarlar'da gösterilir.
    @Published private(set) var redeemedCode: String? {
        didSet { UserDefaults.standard.set(redeemedCode, forKey: "proCode") }
    }

    private init() {
        isPro = UserDefaults.standard.bool(forKey: "isPro")
        redeemedCode = UserDefaults.standard.string(forKey: "proCode")
    }

    /// Girilen kodu doğrular; geçerliyse Pro'yu açar.
    @discardableResult
    func redeem(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.validCodes.contains(normalized) else { return false }
        redeemedCode = normalized
        isPro = true
        return true
    }

    /// Kodu kaldırır ve Pro'yu kapatır.
    func clearCode() {
        redeemedCode = nil
        isPro = false
    }
}

enum OCRService {
    static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
