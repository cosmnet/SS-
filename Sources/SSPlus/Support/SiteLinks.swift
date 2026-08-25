import Foundation

/// Web sitesi adresleri — tek yerden yönetilir.
enum SiteLinks {
    static let home = URL(string: "https://ssplus-app.vercel.app")!
    static let privacy = URL(string: "https://ssplus-app.vercel.app/privacy")!
    static let terms = URL(string: "https://ssplus-app.vercel.app/terms")!
    static let changelog = URL(string: "https://ssplus-app.vercel.app/changelog")!
    static let versionJSON = URL(string: "https://ssplus-app.vercel.app/version.json")!
    static let connected = URL(string: "https://ssplus-app.vercel.app/connected")!
    static let connectFailed = URL(string: "https://ssplus-app.vercel.app/connect-failed")!
    static let releases = URL(string: "https://ssplus-app.vercel.app/#download")!
}
