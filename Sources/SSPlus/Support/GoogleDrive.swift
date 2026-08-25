import AppKit

// MARK: - Hatalar ve modeller

enum GoogleDriveError: LocalizedError {
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case let .http(status, message): return L("Google Drive hatası (%d): %@", status, message)
        case .badResponse: return L("Google Drive beklenmeyen bir yanıt verdi.")
        }
    }
}

struct DriveFile: Decodable {
    let id: String
    let name: String?
    let webViewLink: String?
    let trashed: Bool?
    let createdTime: String?
    let appProperties: [String: String]?
}

struct DriveUser: Decodable {
    let emailAddress: String
    let displayName: String?
}

// MARK: - Drive v3 istemcisi

enum GoogleDriveAPI {
    private static let base = "https://www.googleapis.com/drive/v3"
    private static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    static let folderMime = "application/vnd.google-apps.folder"

    /// Oturum açarken (belirteç henüz kaydedilmeden) hesabı okumak için.
    static func about(accessToken: String) async throws -> DriveUser {
        var request = URLRequest(url: URL(string: "\(base)/about?fields=user(emailAddress,displayName)")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        struct About: Decodable { let user: DriveUser }
        return try JSONDecoder().decode(About.self, from: data).user
    }

    /// Var olan klasör; silinmiş/erişilemezse nil.
    static func fetchFile(id: String) async throws -> DriveFile? {
        do {
            let data = try await request("GET", "\(base)/files/\(id)?fields=id,name,trashed,webViewLink")
            let file = try JSONDecoder().decode(DriveFile.self, from: data)
            return file.trashed == true ? nil : file
        } catch GoogleDriveError.http(404, _) {
            return nil
        }
    }

    /// Uygulamanın kendi klasörünü işaretleyen özel özellik: ad/konum
    /// değişse de yeniden bulunabilsin (appProperties yalnızca bu istemciye görünür).
    static let folderTag = ["ssplus": "folder"]

    static func createFolder(name: String) async throws -> DriveFile {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": folderMime,
            "appProperties": folderTag,
        ])
        let data = try await request("POST", "\(base)/files?fields=id,name,webViewLink,createdTime,appProperties", body: body, contentType: "application/json")
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    /// Klasöre etiketi sonradan ekler (etiketsiz eski derlemelerin klasörleri için).
    static func tagFolder(fileID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["appProperties": folderTag])
        _ = try await request("PATCH", "\(base)/files/\(fileID)", body: body, contentType: "application/json")
    }

    /// Daha önce bu uygulamanın oluşturduğu klasörü bulur: önce etikete, sonra
    /// ada göre. En ESKİ eşleşme döner (geçmişi taşıyan asıl klasör); yeniden
    /// kurulumda açılmış boş kopyalar yok sayılır. `drive.file` kapsamında
    /// files.list zaten yalnızca bu istemcinin oluşturduklarını döndürür.
    static func findFolder(named name: String) async throws -> DriveFile? {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        // Sorgular: etiket → tam ad → bu uygulamanın TÜM klasörleri (istemci
        // tarafında ada göre süz). Üçüncüsü, sunucu tarafı ad eşleşmesinin
        // kaçırabileceği durumlara (kodlama, boşluk) karşı emniyettir.
        let queries: [(q: String, filterByName: Bool)] = [
            ("mimeType='\(folderMime)' and trashed=false and appProperties has { key='ssplus' and value='folder' }", false),
            ("mimeType='\(folderMime)' and trashed=false and name='\(escaped)'", false),
            ("mimeType='\(folderMime)' and trashed=false", true),
        ]
        struct FileList: Decodable { let files: [DriveFile] }
        for entry in queries {
            // URLComponents "+" karakterini kodlamaz; Google onu BOŞLUK sayar
            // ("SS+" → "SS "). Bu yüzden sorgu dizesi burada elle, sıkı biçimde kodlanır.
            let urlString = "\(base)/files?" + encodedQuery([
                ("q", entry.q),
                ("fields", "files(id,name,webViewLink,createdTime,appProperties)"),
                ("orderBy", "createdTime"),
                ("pageSize", entry.filterByName ? "100" : "10"),
                ("spaces", "drive"),
            ])
            let data = try await request("GET", urlString)
            let files = try JSONDecoder().decode(FileList.self, from: data).files
            let match = entry.filterByName ? files.first { $0.name == name } : files.first
            if let match { return match }
        }
        return nil
    }

    /// Sıkı yüzde kodlama: yalnızca harf/rakam ve "-._~" olduğu gibi kalır.
    private static func encodedQuery(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    static func rename(fileID: String, to name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        _ = try await request("PATCH", "\(base)/files/\(fileID)", body: body, contentType: "application/json")
    }

    /// Çok parçalı yükleme: JSON üst veri + dosya içeriği.
    static func upload(data: Data, name: String, mimeType: String, parent: String) async throws -> DriveFile {
        let boundary = "ssplus-\(UUID().uuidString)"
        let meta = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(meta)
        body.append("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)
        let response = try await request(
            "POST",
            "\(uploadBase)/files?uploadType=multipart&fields=id,name,webViewLink",
            body: body,
            contentType: "multipart/related; boundary=\(boundary)"
        )
        return try JSONDecoder().decode(DriveFile.self, from: response)
    }

    /// Büyük dosyalar (video) için sürdürülebilir yükleme: içerik diskten
    /// akıtılır, belleğe alınmaz. Metadata ile oturum açılır, dosya PUT edilir.
    static func uploadResumable(fileURL: URL, name: String, mimeType: String, parent: String) async throws -> DriveFile {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        let meta = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])

        // 1) Oturum: Location başlığında yükleme adresi döner
        var token = try await GoogleAuth.shared.validAccessToken()
        var location: URL?
        for attempt in 0..<2 {
            var start = URLRequest(url: URL(string: "\(uploadBase)/files?uploadType=resumable&fields=id,name,webViewLink")!)
            start.httpMethod = "POST"
            start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            start.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
            start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            start.httpBody = meta
            let (data, response) = try await URLSession.shared.data(for: start)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 401, attempt == 0 {
                token = try await GoogleAuth.shared.validAccessToken(forceRefresh: true)
                continue
            }
            try check(response, data)
            guard let loc = http?.value(forHTTPHeaderField: "Location"), let url = URL(string: loc) else {
                throw GoogleDriveError.badResponse
            }
            location = url
            break
        }
        guard let location else { throw GoogleDriveError.badResponse }

        // 2) İçerik: diskten akıtılır
        var put = URLRequest(url: location)
        put.httpMethod = "PUT"
        put.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        put.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await URLSession.shared.upload(for: put, fromFile: fileURL)
        try check(response, data)
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    /// Var olan dosyanın içeriğini değiştirir (aynı kimlik, aynı bağlantı).
    static func update(fileID: String, data: Data, mimeType: String) async throws -> DriveFile {
        let response = try await request(
            "PATCH",
            "\(uploadBase)/files/\(fileID)?uploadType=media&fields=id,name,webViewLink",
            body: data,
            contentType: mimeType
        )
        return try JSONDecoder().decode(DriveFile.self, from: response)
    }

    /// "Bağlantıya sahip herkes görüntüleyebilir".
    static func shareAnyone(fileID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
        _ = try await request("POST", "\(base)/files/\(fileID)/permissions", body: body, contentType: "application/json")
    }

    // MARK: İstek

    /// Bearer ekler; 401'de belirteci bir kez yeniler ve tekrar dener.
    private static func request(_ method: String, _ urlString: String, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GoogleDriveError.badResponse }
        var token = try await GoogleAuth.shared.validAccessToken()
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                token = try await GoogleAuth.shared.validAccessToken(forceRefresh: true)
                continue
            }
            try check(response, data)
            return data
        }
        throw GoogleDriveError.badResponse
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GoogleDriveError.http(status, errorMessage(from: data))
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(160), as: UTF8.self)
    }
}

// MARK: - Yükleme koordinatörü

enum DriveUploadState: Equatable {
    case uploading
    case done(URL)
    case failed(String)
}

/// Ekran görüntüsünü yerel kayıttan sonra Drive'a yükler, isteğe bağlı olarak
/// herkese açık paylaşır ve linki panoya kopyalar; önizleme kartını bilgilendirir.
@MainActor
final class DriveUploadCoordinator {
    static let shared = DriveUploadCoordinator()

    /// Yerel dosya → Drive dosya kimliği (düzenleyiciden yeniden kaydetme aynı dosyayı günceller).
    private var fileIDs: [URL: String] = [:]
    private var expiryAlertShown = false

    private init() {}

    var isActive: Bool {
        SettingsStore.shared.driveUploadEnabled && GoogleAuth.shared.isSignedIn
    }

    func upload(imageData: Data, mimeType: String, localURL: URL) {
        guard isActive else { return }
        PreviewPanelController.shared.setUploadState(.uploading, for: localURL)
        Task {
            do {
                let (file, link) = try await perform(data: imageData, mimeType: mimeType, localURL: localURL)
                if let link {
                    if SettingsStore.shared.driveShareAnyone, SettingsStore.shared.driveCopyLink {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(link.absoluteString, forType: .string)
                        ClipboardStore.shared.markOwnChange(pasteboard.changeCount)
                    }
                    PreviewPanelController.shared.setUploadState(.done(link), for: localURL)
                } else {
                    PreviewPanelController.shared.setUploadState(.failed(L("Bağlantı alınamadı")), for: localURL)
                }
                _ = file
            } catch {
                PreviewPanelController.shared.setUploadState(.failed(error.localizedDescription), for: localURL)
                if case GoogleAuthError.sessionExpired = error, !expiryAlertShown {
                    expiryAlertShown = true
                    AppState.shared.presentError(error)
                }
            }
        }
    }

    /// Video kaydı: ayarda açıksa diskten sürdürülebilir yüklemeyle gönderilir.
    func uploadVideo(localURL: URL) {
        guard isActive, SettingsStore.shared.driveUploadVideos else { return }
        let mime = localURL.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime"
        PreviewPanelController.shared.setUploadState(.uploading, for: localURL)
        Task {
            do {
                var folder = try await ensureFolder()
                let file: DriveFile
                do {
                    file = try await GoogleDriveAPI.uploadResumable(fileURL: localURL, name: localURL.lastPathComponent, mimeType: mime, parent: folder)
                } catch GoogleDriveError.http(404, _) {
                    SettingsStore.shared.driveFolderID = ""
                    folder = try await ensureFolder()
                    file = try await GoogleDriveAPI.uploadResumable(fileURL: localURL, name: localURL.lastPathComponent, mimeType: mime, parent: folder)
                }
                if SettingsStore.shared.driveShareAnyone {
                    try await GoogleDriveAPI.shareAnyone(fileID: file.id)
                }
                guard let link = file.webViewLink.flatMap(URL.init) else {
                    PreviewPanelController.shared.setUploadState(.failed(L("Bağlantı alınamadı")), for: localURL)
                    return
                }
                if SettingsStore.shared.driveShareAnyone, SettingsStore.shared.driveCopyLink {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(link.absoluteString, forType: .string)
                    ClipboardStore.shared.markOwnChange(pasteboard.changeCount)
                }
                PreviewPanelController.shared.setUploadState(.done(link), for: localURL)
            } catch {
                PreviewPanelController.shared.setUploadState(.failed(error.localizedDescription), for: localURL)
                if case GoogleAuthError.sessionExpired = error, !expiryAlertShown {
                    expiryAlertShown = true
                    AppState.shared.presentError(error)
                }
            }
        }
    }

    private func perform(data: Data, mimeType: String, localURL: URL) async throws -> (DriveFile, URL?) {
        if let existing = fileIDs[localURL] {
            let file = try await GoogleDriveAPI.update(fileID: existing, data: data, mimeType: mimeType)
            return (file, file.webViewLink.flatMap(URL.init))
        }

        var folder = try await ensureFolder()
        let file: DriveFile
        do {
            file = try await GoogleDriveAPI.upload(data: data, name: localURL.lastPathComponent, mimeType: mimeType, parent: folder)
        } catch GoogleDriveError.http(404, _) {
            // Klasör bu arada silinmiş: yeniden oluştur ve bir kez daha dene.
            SettingsStore.shared.driveFolderID = ""
            folder = try await ensureFolder()
            file = try await GoogleDriveAPI.upload(data: data, name: localURL.lastPathComponent, mimeType: mimeType, parent: folder)
        }
        fileIDs[localURL] = file.id

        if SettingsStore.shared.driveShareAnyone {
            try await GoogleDriveAPI.shareAnyone(fileID: file.id)
        }
        return (file, file.webViewLink.flatMap(URL.init))
    }

    /// Ayarlardaki klasör kimliğini doğrular; yoksa (ör. yeniden kurulum) Drive'da
    /// daha önce oluşturulmuş SS+ klasörünü ARAR ve onu benimser; o da yoksa
    /// yenisini oluşturur. Böylece her yeniden kurulumda yeni "SS+" klasörü açılmaz.
    @discardableResult
    func ensureFolder() async throws -> String {
        let settings = SettingsStore.shared
        if !settings.driveFolderID.isEmpty,
           let existing = try await GoogleDriveAPI.fetchFile(id: settings.driveFolderID) {
            return existing.id
        }
        let trimmed = settings.driveFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "SS+" : trimmed

        if let found = try await GoogleDriveAPI.findFolder(named: name) {
            if found.appProperties?["ssplus"] != "folder" {
                try? await GoogleDriveAPI.tagFolder(fileID: found.id)
            }
            if let foundName = found.name, !foundName.isEmpty { settings.driveFolderName = foundName }
            settings.driveFolderID = found.id
            return found.id
        }

        let created = try await GoogleDriveAPI.createFolder(name: name)
        settings.driveFolderID = created.id
        return created.id
    }

    func renameFolder() async throws {
        let settings = SettingsStore.shared
        let name = settings.driveFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = try await ensureFolder()
        try await GoogleDriveAPI.rename(fileID: id, to: name)
    }

    var folderURL: URL? {
        let id = SettingsStore.shared.driveFolderID
        guard !id.isEmpty else { return nil }
        return URL(string: "https://drive.google.com/drive/folders/\(id)")
    }
}
