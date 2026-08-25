import Foundation

/// Sürüm dizgilerini bileşen bileşen SAYISAL karşılaştırır (güncelleme denetimi).
///
///     "1.10.0"  >  "1.9.0"      (düz dizgi karşılaştırması bunu ters çevirirdi)
///     "1.5"     == "1.5.0"      (eksik bileşenler 0 sayılır)
///     "1.5.1-beta" → 1.5.1      ("-" / "+" sonrası yok sayılır)
///     "v1.6.0"  → 1.6.0         (bileşen başındaki sayı olmayan karakterler atılır)
///
/// Bilerek bağımlılıksız ve aktör dışı: `swiftc` ile tek başına derlenip sınanabilir.
enum VersionCompare {
    static func components(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? trimmed
        return core.split(separator: ".").map { part in
            let digits = part.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
            return Int(digits) ?? 0
        }
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}
