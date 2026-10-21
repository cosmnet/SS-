import AppKit
import CryptoKit
import Network
import Security

// MARK: - İstemci yapılandırması

/// Geliştiricinin Google Cloud'da oluşturduğu OAuth istemcisi (uygulama kimliği).
/// Kullanıcı verisine erişim vermez; her kullanıcı KENDİ hesabıyla oturum açar
/// ve belirteçler yalnızca o kullanıcının Anahtar Zinciri'nde durur.
struct GoogleOAuthConfig {
    let clientID: String
    let clientSecret: String

    /// Paketteki `GoogleOAuth.plist`, yoksa ortam değişkenleri (`swift run` için).
    static func load() -> GoogleOAuthConfig? {
        if let url = Bundle.main.url(forResource: "GoogleOAuth", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let id = dict["ClientID"] as? String, !id.isEmpty, !id.contains("YOUR_") {
            return GoogleOAuthConfig(clientID: id, clientSecret: dict["ClientSecret"] as? String ?? "")
        }
        let env = ProcessInfo.processInfo.environment
        if let id = env["SSPLUS_GOOGLE_CLIENT_ID"], !id.isEmpty {
            return GoogleOAuthConfig(clientID: id, clientSecret: env["SSPLUS_GOOGLE_CLIENT_SECRET"] ?? "")
        }
        return nil
    }
}

enum GoogleAuthError: LocalizedError {
    case notConfigured
    case cancelled
    case stateMismatch
    case listenerFailed
    case tokenExchangeFailed(String)
    case noSession
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L("Google Drive için istemci kimliği ayarlanmamış.")
        case .cancelled: return L("Oturum açma iptal edildi.")
        case .stateMismatch: return L("Güvenlik doğrulaması başarısız (state).")
        case .listenerFailed: return L("Yerel geri dönüş sunucusu başlatılamadı.")
        case .tokenExchangeFailed(let message): return L("Google belirteci alınamadı: %@", message)
        case .noSession: return L("Google oturumu yok; Ayarlar'dan oturum aç.")
        case .sessionExpired: return L("Google oturumu süresi doldu; Ayarlar'dan yeniden oturum aç.")
        }
    }
}

struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var email: String
    var name: String
}

// MARK: - Anahtar Zinciri

private enum TokenKeychain {
    private static let service = "com.ssplus.app.google"
    private static let account = "tokens"

    private static var base: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func save(_ tokens: GoogleTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> GoogleTokens? {
        var query = base
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}

// MARK: - OAuth 2.0 (masaüstü akışı, PKCE, loopback)

@MainActor
final class GoogleAuth: ObservableObject {
    static let shared = GoogleAuth()

    static let scope = "https://www.googleapis.com/auth/drive.file"

    let config = GoogleOAuthConfig.load()
    var isConfigured: Bool { config != nil }

    @Published private(set) var tokens: GoogleTokens?
    @Published private(set) var isSigningIn = false

    var isSignedIn: Bool { tokens != nil }
    var accountEmail: String? { tokens?.email }

    private init() {
        tokens = TokenKeychain.load()
        // Öğe başka bir imzayla (eski derleme) oluşturulmuşsa macOS bir kez
        // Anahtar Zinciri onayı ister. Onaydan sonra öğeyi bu uygulamanın
        // imzasıyla yeniden yaz: sonraki açılışlarda soru tekrarlanmaz.
        if let tokens { TokenKeychain.save(tokens) }
    }

    // MARK: Oturum açma

    /// Varsayılan tarayıcıda Google onay ekranını açar, geri dönüşü 127.0.0.1'de
    /// dinler, belirteçleri alır ve Anahtar Zinciri'ne yazar.
    func signIn() async throws {
        guard let config else { throw GoogleAuthError.notConfigured }
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }

        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(bytes: 16)

        let server = LoopbackServer()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)/callback"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw GoogleAuthError.listenerFailed }
        NSWorkspace.shared.open(url)

        let (code, returnedState) = try await server.waitForCode(timeout: 300)
        guard returnedState == state else { throw GoogleAuthError.stateMismatch }

        let response = try await Self.tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ])
        guard let refresh = response.refreshToken else {
            throw GoogleAuthError.tokenExchangeFailed("refresh_token yok")
        }

        let user = try await GoogleDriveAPI.about(accessToken: response.accessToken)
        let fresh = GoogleTokens(
            accessToken: response.accessToken,
            refreshToken: refresh,
            expiry: Date().addingTimeInterval(response.expiresIn),
            email: user.emailAddress,
            name: user.displayName ?? ""
        )
        tokens = fresh
        TokenKeychain.save(fresh)
    }

    /// Belirteci Google'da geçersiz kılar ve yerel kaydı siler.
    func signOut() async {
        if let current = tokens, let config {
            _ = try? await Self.tokenRequest(
                ["token": current.refreshToken, "client_id": config.clientID],
                endpoint: "https://oauth2.googleapis.com/revoke"
            )
        }
        forgetLocally()
    }

    /// Google tarafında oturum düşmüşse (invalid_grant) yalnızca yerel kaydı sil.
    func forgetLocally() {
        tokens = nil
        TokenKeychain.delete()
        SettingsStore.shared.driveFolderID = ""
    }

    // MARK: Belirteç

    /// Geçerli erişim belirteci; süresi dolmak üzereyse yeniler.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw GoogleAuthError.noSession }
        if !forceRefresh, current.expiry > Date().addingTimeInterval(60) {
            return current.accessToken
        }
        guard let config else { throw GoogleAuthError.notConfigured }
        do {
            let response = try await Self.tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
            ])
            var updated = current
            updated.accessToken = response.accessToken
            updated.expiry = Date().addingTimeInterval(response.expiresIn)
            if let newRefresh = response.refreshToken { updated.refreshToken = newRefresh }
            tokens = updated
            TokenKeychain.save(updated)
            return updated.accessToken
        } catch GoogleAuthError.tokenExchangeFailed(let message) where message.contains("invalid_grant") {
            // Kullanıcı erişimi iptal etmiş ya da belirteç geçersiz: yeniden oturum gerekir.
            forgetLocally()
            throw GoogleAuthError.sessionExpired
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct TokenError: Decodable {
        let error: String
        let errorDescription: String?
        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private static func tokenRequest(
        _ form: [String: String],
        endpoint: String = "https://oauth2.googleapis.com/token"
    ) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(form).utf8)
        let (data, response) = try await URLSession.shared.compatData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let err = try? JSONDecoder().decode(TokenError.self, from: data) {
                throw GoogleAuthError.tokenExchangeFailed("\(err.error): \(err.errorDescription ?? "")")
            }
            throw GoogleAuthError.tokenExchangeFailed("HTTP \(status)")
        }
        if endpoint.hasSuffix("/revoke") {
            return TokenResponse(accessToken: "", expiresIn: 0, refreshToken: nil)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleAuthError.tokenExchangeFailed(String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    // MARK: Yardımcılar

    private static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .filter { !$0.value.isEmpty }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            }
            .joined(separator: "&")
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback HTTP sunucusu (tek istek)

/// 127.0.0.1'de rastgele bir kapıda `GET /callback?code&state` bekler,
/// tarayıcıya kısa bir sayfa döner ve kapanır.
///
/// Tüm durum `queue` üzerinde okunup yazılır (NWListener/NWConnection
/// geri çağrıları da o kuyrukta); bu yüzden `@unchecked Sendable`.
private final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var startResumed = false
    private let queue = DispatchQueue(label: "ssplus.oauth.loopback")

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.startResumed else { return }
                    self.startResumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard !self.startResumed else { return }
                    self.startResumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode(timeout: TimeInterval) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(GoogleAuthError.cancelled))
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) != nil
            if headerEnd || isComplete || error != nil {
                self.respond(connection, request: String(decoding: buf, as: UTF8.self))
            } else {
                self.receive(connection, buffer: buf)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"

        guard path.hasPrefix("/callback") else {
            send(connection, status: "404 Not Found", body: "")
            return
        }

        let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value
        let state = items.first { $0.name == "state" }?.value
        let oauthError = items.first { $0.name == "error" }?.value

        // Tarayıcıyı web sitesindeki sonuç sayfasına yönlendir: adres çubuğunda
        // 127.0.0.1 yerine ssplusapp.vercel.app görünür. (Yerel sayfa yalnızca
        // yönlendirme izlenemezse yedek olarak durur.)
        let target = (code != nil) ? SiteLinks.connected : SiteLinks.connectFailed
        redirect(connection, to: target, fallback: Self.resultPage(success: code != nil))

        if let code, let state {
            finish(.success((code, state)))
        } else if oauthError != nil {
            finish(.failure(GoogleAuthError.cancelled))
        }
    }

    /// Tarayıcıda gösterilen sonuç sayfası: markalı, kapatma düğmeli, kendini
    /// kapatmayı dener (tarayıcı izin verirse).
    private static func resultPage(success: Bool) -> String {
        let title = success ? L("Google Drive bağlandı") : L("Bağlantı kurulamadı")
        let detail = success
            ? L("Bu pencereyi kapatabilirsin; ekran görüntülerin artık Drive'a yüklenecek.")
            : L("Oturum açma tamamlanmadı. SS+ Ayarlar'dan tekrar deneyebilirsin.")
        let close = L("Pencereyi kapat")
        let iconPath = success
            ? "M20 6L9 17l-5-5"
            : "M18 6L6 18M6 6l12 12"
        let accent = success ? "#8E4BF0" : "#C8323E"
        return """
        <!doctype html>
        <html lang="tr"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>SS+ · \(title)</title>
        <style>
          :root{color-scheme:light dark;--ink:#1B1720;--muted:#6E6779;--paper:#FBFAFC;--card:#fff;--line:#E6E1EC}
          @media(prefers-color-scheme:dark){:root{--ink:#F0ECF5;--muted:#A79FB3;--paper:#121016;--card:#1A1721;--line:#2B2634}}
          *{box-sizing:border-box}
          body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--paper);color:var(--ink);
               font:16px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
          .card{width:min(440px,92vw);background:var(--card);border:1px solid var(--line);border-radius:20px;
                padding:40px 32px 32px;text-align:center;box-shadow:0 18px 50px rgba(0,0,0,.12)}
          .mark{width:64px;height:64px;margin:0 auto 20px;border-radius:18px;display:grid;place-items:center;
                background:linear-gradient(135deg,#FF5C9E,#8E4BF0)}
          .mark svg{width:32px;height:32px;stroke:#fff;stroke-width:3;fill:none;stroke-linecap:round;stroke-linejoin:round}
          .badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;letter-spacing:.08em;
                 text-transform:uppercase;color:\(accent);margin-bottom:10px}
          .badge svg{width:14px;height:14px;stroke:\(accent);stroke-width:3;fill:none;stroke-linecap:round;stroke-linejoin:round}
          h1{font-size:22px;margin:0 0 8px;letter-spacing:-.01em}
          p{margin:0 0 24px;color:var(--muted)}
          button{font:inherit;font-weight:600;color:#fff;background:\(accent);border:0;border-radius:12px;padding:12px 22px;cursor:pointer}
          button:hover{filter:brightness(1.08)}
          .app{margin-top:18px;font-size:12px;color:var(--muted)}
          .app a{color:var(--muted);text-decoration:none;border-bottom:1px solid var(--line)}
          .app a:hover{color:\(accent)}
        </style></head>
        <body>
          <div class="card">
            <div class="mark"><svg viewBox="0 0 24 24"><path d="M4 9V6a2 2 0 0 1 2-2h3M15 4h3a2 2 0 0 1 2 2v3M20 15v3a2 2 0 0 1-2 2h-3M9 20H6a2 2 0 0 1-2-2v-3"/></svg></div>
            <div class="badge"><svg viewBox="0 0 24 24"><path d="\(iconPath)"/></svg>SS+</div>
            <h1>\(title)</h1>
            <p>\(detail)</p>
            <button onclick="window.close()">\(close)</button>
            <div class="app"><a href="\(SiteLinks.home.absoluteString)">ssplusapp.vercel.app</a> · <a href="\(SiteLinks.privacy.absoluteString)">\(L("Gizlilik politikası"))</a></div>
          </div>
          <script>setTimeout(function(){try{window.close()}catch(e){}},1500)</script>
        </body></html>
        """
    }

    private func redirect(_ connection: NWConnection, to url: URL, fallback: String) {
        let response = "HTTP/1.1 302 Found\r\nLocation: \(url.absoluteString)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(fallback.utf8.count)\r\nConnection: close\r\n\r\n" + fallback
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<(String, String), Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        listener?.cancel()
        listener = nil
        cont.resume(with: result)
    }
}
