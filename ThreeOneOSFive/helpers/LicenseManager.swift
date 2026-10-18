import Combine
import Foundation
import Security

/// Online-first access control. The server validates every protected API call;
/// nothing inside the IPA is an offline master key.
@MainActor
final class LicenseManager: ObservableObject {
    static let serverURL = URL(string: "https://gohanpatch-adminpatch.zcloudviet.xyz")!

    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var expirationDate: Date?
    @Published private(set) var message: String? = "Cần kích hoạt License Key"
    @Published var rememberKey = true
    @Published private(set) var contactOwner: String? = nil

    private let service = "com.goohanpatch.serverlicense.v1"
    private let keyAccount = "key"
    private let sessionAccount = "session"
    private let deviceAccount = "device-id"
    private var workInProgress = false

    func beginLaunchSession() {
        guard !workInProgress else { return }
        workInProgress = true
        // Initial launch is locked; an already-open session remains visible
        // during short periodic rechecks and is closed if validation fails.
        isBusy = true
        Task {
            defer { self.workInProgress = false; self.isBusy = false }
            do {
                try await self.validateSession()
                self.isActive = true
                self.message = nil
            } catch {
                // Session tokens expire after 24h. Transparently renew using the
                // user's Keychain-stored key; the server checks expiry/revocation.
                guard let key = self.string(for: self.keyAccount) else {
                    self.isActive = false
                    self.message = "Nhập License Key để tiếp tục. \(error.localizedDescription)"
                    return
                }
                do {
                    try await self.redeem(key)
                    self.message = nil
                } catch {
                    self.isActive = false
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func activate(key: String) {
        guard !workInProgress else { return }
        workInProgress = true
        isBusy = true
        message = "Đang xác minh với máy chủ…"
        Task {
            defer { self.workInProgress = false; self.isBusy = false }
            do {
                try await self.redeem(key.trimmingCharacters(in: .whitespacesAndNewlines))
                self.message = nil
            } catch {
                self.isActive = false
                self.message = error.localizedDescription
            }
        }
    }

    func refresh() { beginLaunchSession() }
    func rememberedKey() -> String? { string(for: keyAccount) }
    func deactivate() {
        remove(keyAccount)
        remove(sessionAccount)
        expirationDate = nil
        isActive = false
        message = "Đã đăng xuất khỏi tài khoản License"
    }

    /// Called before each Patch activation and all content downloads.
    func ensureAuthorized() async throws {
        do {
            try await validateSession()
            isActive = true
        } catch {
            isActive = false
            throw error
        }
    }

    func authenticatedData(from url: URL, maxSize: Int = 80 * 1024 * 1024) async throws -> Data {
        try await ensureAuthorized()
        guard let token = string(for: sessionAccount) else { throw LicenseError.denied("Cần nhập lại Key") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw LicenseError.denied("Không nhận được phản hồi máy chủ") }
        if http.statusCode == 401 || http.statusCode == 403 {
            isActive = false
            throw LicenseError.denied("Phiên truy cập bị từ chối. Vui lòng xác thực lại")
        }
        guard http.statusCode == 200 else { throw LicenseError.denied("Lỗi máy chủ HTTP \(http.statusCode)") }
        guard data.count <= maxSize else { throw LicenseError.denied("Dữ liệu vượt giới hạn") }
        return data
    }

    private func validateSession() async throws {
        guard let token = string(for: sessionAccount) else { throw LicenseError.denied("Chưa kích hoạt") }
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/license/status"))
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = response as? HTTPURLResponse, status.statusCode == 200 else {
            throw LicenseError.denied("Key hết hạn, đã thu hồi, phiên hết hạn hoặc máy chủ không khả dụng")
        }
        let payload = try JSONDecoder().decode(LicenseReply.self, from: data)
        guard payload.ok, payload.expiresAt > payload.serverTime else {
            throw LicenseError.denied("Key đã hết hạn")
        }
        expirationDate = Date(timeIntervalSince1970: TimeInterval(payload.expiresAt))
    }

    private func redeem(_ key: String) async throws {
        guard !key.isEmpty else { throw LicenseError.denied("Vui lòng nhập Key") }
        let deviceID = deviceID()
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/license/activate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ActivationRequest(key: key, deviceId: deviceID))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseError.denied("Máy chủ không phản hồi") }
        if http.statusCode != 200 {
            let error = try? JSONDecoder().decode(ServerError.self, from: data)
            throw LicenseError.denied(error?.error ?? "Key không hợp lệ (HTTP \(http.statusCode))")
        }
        let payload = try JSONDecoder().decode(LicenseReply.self, from: data)
        guard payload.ok, let token = payload.token, payload.expiresAt > payload.serverTime else {
            throw LicenseError.denied("Không thể xác nhận Key")
        }
        save(token, for: sessionAccount)
        // Stored locally, never embedded in the IPA; used to refresh short-lived sessions.
        if rememberKey { save(key.uppercased(), for: keyAccount) }
        else { remove(keyAccount) }
        expirationDate = Date(timeIntervalSince1970: TimeInterval(payload.expiresAt))
        isActive = true
    }

    private func deviceID() -> String {
        if let value = string(for: deviceAccount), value.count == 32 { return value }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        save(value, for: deviceAccount)
        return value
    }
    private struct ActivationRequest: Encodable { let key: String; let deviceId: String }
    private struct LicenseReply: Decodable {
        let ok: Bool
        let token: String?
        let expiresAt: Int
        let serverTime: Int
        enum CodingKeys: String, CodingKey { case ok, token, expiresAt = "expires_at", serverTime = "server_time" }
    }
    private struct ServerError: Decodable { let error: String }
    private enum LicenseError: LocalizedError {
        case denied(String)
        var errorDescription: String? { if case .denied(let v) = self { return v }; return nil }
    }

    private func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func save(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    private func remove(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
