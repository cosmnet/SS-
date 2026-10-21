import Foundation

/// Web sitesi adresleri — tek yerden yönetilir.
enum SiteLinks {
    static let home = URL(string: "https://ssplusapp.vercel.app")!
    static let privacy = URL(string: "https://ssplusapp.vercel.app/privacy")!
    static let terms = URL(string: "https://ssplusapp.vercel.app/terms")!
    static let changelog = URL(string: "https://ssplusapp.vercel.app/changelog")!
    static let versionJSON = URL(string: "https://ssplusapp.vercel.app/version.json")!
    static let connected = URL(string: "https://ssplusapp.vercel.app/connected")!
    static let connectFailed = URL(string: "https://ssplusapp.vercel.app/connect-failed")!
    static let releases = URL(string: "https://ssplusapp.vercel.app/#download")!
}
