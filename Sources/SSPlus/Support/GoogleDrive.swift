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

    static func createFolder(name: String) async throws -> DriveFile {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": folderMime])
        let data = try await request("POST", "\(base)/files?fields=id,name,webViewLink", body: body, contentType: "application/json")
        return try JSONDecoder().decode(DriveFile.self, from: data)
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

    /// Ayarlardaki klasör kimliğini doğrular; yoksa/silinmişse adıyla yeniden oluşturur.
    @discardableResult
    func ensureFolder() async throws -> String {
        let settings = SettingsStore.shared
        if !settings.driveFolderID.isEmpty,
           let existing = try await GoogleDriveAPI.fetchFile(id: settings.driveFolderID) {
            return existing.id
        }
        let name = settings.driveFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = try await GoogleDriveAPI.createFolder(name: name.isEmpty ? "SS+" : name)
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
