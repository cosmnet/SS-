import Foundation

extension Notification.Name {
    /// Kayıt sırasında ekrana çizim katmanını aç/kapat (island'daki kalem düğmesi gönderir,
    /// RecordingDrawController dinler).
    static let ssPlusToggleDrawOverlay = Notification.Name("ssPlusToggleDrawOverlay")
}
