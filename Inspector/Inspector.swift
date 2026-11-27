import SwiftUI
import Foundation
import CryptoKit
import UniformTypeIdentifiers

struct MetadataError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PackageMetadata {
    let bundle: String
    let schema: String
    let packageID: String
    let hash: String

    static func validBundle(_ value: String) -> Bool {
        value.utf8.count <= 255 &&
        value.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    static func read(_ data: Data) throws -> Self {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let format = json["format"] as? String,
           ["3105-project-v1", "3106-project-v1"].contains(format) {
            guard let bundle = json["bundle_id"] as? String, validBundle(bundle),
                  let id = json["package_id"] as? String, UUID(uuidString: id) != nil else {
                throw MetadataError(message: "Metadata JSON thiếu Bundle ID hoặc ID gói hợp lệ.")
            }
            return Self(bundle: bundle, schema: format, packageID: id, hash: hash)
        }
        let magic = Data("3105PATCH\0".utf8)
        guard data.starts(with: magic),
              let envelope = try PropertyListSerialization.propertyList(from: Data(data.dropFirst(magic.count)), options: [], format: nil) as? [String: Any],
              let version = envelope["schemaVersion"] as? Int, [2,3].contains(version),
              let rawID = envelope["packageID"] as? String,
              let id = UUID(uuidString: rawID)?.uuidString else {
            throw MetadataError(message: "Định dạng gói không được hỗ trợ.")
        }
        guard envelope["isPasswordProtected"] as? Bool == false else {
            throw MetadataError(message: "Gói có mật khẩu. Bản kiểm tra này chỉ đọc gói không có mật khẩu.")
        }
        guard let key = envelope["publicContentKey"] as? Data, key.count == 32,
              let fingerprint = envelope["keyFingerprint"] as? Data,
              Data(SHA256.hash(data: key)) == fingerprint,
              let encrypted = envelope["encryptedPayload"] as? Data, encrypted.count >= 28 else {
            throw MetadataError(message: "Metadata mã hóa không hợp lệ.")
        }
        let aad = Data("3105PATCH/v\(version)/payload/\(id)".utf8)
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        let plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: aad)
        guard let payload = try PropertyListSerialization.propertyList(from: plaintext, options: [], format: nil) as? [String: Any],
              let project = payload["project"] as? [String: Any],
              let rawProjectID = project["id"] as? String,
              UUID(uuidString: rawProjectID)?.uuidString == id else {
            throw MetadataError(message: "ID dự án không khớp metadata.")
        }
        guard project["isPrivate"] as? Bool != true else {
            throw MetadataError(message: "Không hỗ trợ gói riêng tư.")
        }
        guard let rules = project["rules"] as? [[String: Any]], (1...100).contains(rules.count) else {
            throw MetadataError(message: "Thiếu khai báo quy tắc hợp lệ.")
        }
        let ids = rules.compactMap { $0["bundleID"] as? String }
        guard ids.count == rules.count, let bundle = ids.first, validBundle(bundle),
              ids.allSatisfy({ $0 == bundle }) else {
            throw MetadataError(message: "Các khai báo Bundle ID không nhất quán.")
        }
        if let declared = project["bundleIdentifiers"] {
            guard let values = declared as? [String], Set(values) == Set([bundle]) else {
                throw MetadataError(message: "Danh sách Bundle ID không khớp.")
            }
        }
        if let dirs = project["directories"] {
            guard let values = dirs as? [[String: Any]],
                  values.allSatisfy({ ($0["bundleID"] as? String) == bundle }) else {
                throw MetadataError(message: "Bundle ID thư mục không khớp.")
            }
        }
        return Self(bundle: bundle, schema: String(version), packageID: id, hash: hash)
    }
}

@main
struct GoHanInspector: App {
    var body: some Scene { WindowGroup { InspectorView() } }
}
struct InspectorView: View {
    @State private var importing = false
    @State private var result: PackageMetadata?
    @State private var adminID = ""
    @State private var message = "Chọn file .3106 hoặc JSON metadata từ Admin."
    var body: some View {
        NavigationStack {
            Form {
                Section("HIGHT • Kiểm tra metadata") {
                    Text("Chỉ đọc file được chọn. Không áp dụng Patch, không truy cập ứng dụng khác.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Chọn tệp") { importing = true }
                    Text(message).font(.footnote)
                }
                if let result {
                    Section("Kết quả") {
                        LabeledContent("Bundle ID", value: result.bundle)
                        LabeledContent("Schema", value: result.schema)
                        Text(result.packageID).font(.caption).textSelection(.enabled)
                        Text("SHA-256: " + result.hash).font(.caption).textSelection(.enabled)
                    }
                    Section("Đối chiếu Admin") {
                        TextField("Bundle ID trong Admin", text: $adminID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !adminID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let match = adminID.trimmingCharacters(in: .whitespacesAndNewlines) == result.bundle
                            Label(match ? "Khớp Admin" : "Không khớp Admin", systemImage: match ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(match ? Color.green : Color.orange)
                        }
                    }
                }
            }
            .navigationTitle("GoHan iOS")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { selection in
                result = nil
                do {
                    guard let url = try selection.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let cap = 75 * 1024 * 1024
                    let bytes = try handle.read(upToCount: cap + 1) ?? Data()
                    guard bytes.count <= cap, !bytes.isEmpty else {
                        throw MetadataError(message: "File trống hoặc vượt 75 MB.")
                    }
                    result = try PackageMetadata.read(bytes)
                    message = "Đã nhận diện metadata thành công."
                } catch { message = error.localizedDescription }
            }
        }.tint(.pink)
    }
}
