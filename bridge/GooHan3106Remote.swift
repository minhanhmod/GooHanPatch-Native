import SwiftUI
import Foundation
import CryptoKit

// GooHan remote catalog runs on the COMPLETE upstream 3106 application.
// Actual writes/restores use upstream DevicePatchService and SandboxAccess;
// no substitute patch driver or custom sandbox escape is implemented here.
private struct GH6Package: Decodable, Identifiable {
    let id: String
    let game: String
    let categoryId: String?
    let targetBundleId: String?
    let feature: String
    let version: String
    let sha256: String
    let size: Int
    let downloadPath: String
    let enabled: Bool
    let sortOrder: Int
    let packageFormat: String
    let description: String
}
private struct GH6PackageList: Decodable { let patches: [GH6Package] }
private struct GH6Category: Decodable, Identifiable {
    let id: String
    let name: String
    let targetGame: String?
    let sortOrder: Int
    let enabled: Bool
}
private struct GH6CategoryList: Decodable { let categories: [GH6Category] }

private struct GH6Plan: Decodable {
    struct Rule: Decodable {
        let relativePath: String
        let replacementData: Data
    }
    let format: String
    let packageId: String
    let name: String
    let game: String
    let bundleId: String?
    let rules: [Rule]
}

private enum GH6Error: LocalizedError {
    case text(String)
    var errorDescription: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

private enum GH6PlanStorage {
    static func url(for id: String) throws -> URL {
        guard id.count == 32, id.allSatisfy({ $0.isHexDigit }) else {
            throw GH6Error.text("Mã gói không hợp lệ")
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = base.appendingPathComponent("GooHan3106Remote", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(id + ".json")
    }

    static func read(_ id: String) -> GH6Plan? {
        guard let path = try? url(for: id),
              let data = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(GH6Plan.self, from: data)
    }

    static func save(_ data: Data, id: String) throws {
        try data.write(to: url(for: id), options: .atomic)
    }

    static func activeReceipt(for id: String) -> PatchTransactionReceipt? {
        guard let plan = read(id),
              let projectID = UUID(uuidString: plan.packageId) else { return nil }
        return DevicePatchService.latestReceipt(projectID: projectID)
    }
}

struct GooHan3106RemoteView: View {
    @StateObject private var licenseManager = LicenseManager()
    @State private var inputKey = ""
    @State private var packages: [GH6Package] = []
    @State private var categories: [GH6Category] = []
    @State private var selectedCategory = "free_fire_max"
    @State private var busyPackageID: String?
    @State private var syncing = false
    @State private var statusText = "Đang kết nối GooHan Admin…"
    @State private var refreshReceipt = 0
    @Environment(\.dismiss) private var dismiss

    private var visiblePackages: [GH6Package] {
        packages.filter {
            $0.enabled &&
            $0.packageFormat == "3106" &&
            ($0.categoryId ?? $0.game) == selectedCategory
        }
        .sorted {
            $0.sortOrder == $1.sortOrder
                ? $0.feature < $1.feature
                : $0.sortOrder < $1.sortOrder
        }
    }

    private var filteredCategories: [GH6Category] {
        categories.filter {
            $0.enabled || packages.contains {
                ($0.categoryId ?? $0.game) == $0.id
            }
        }.sorted {
            $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Image(systemName: "bolt.shield.fill")
                            .font(.largeTitle).foregroundColor(.pink)
                        VStack(alignment: .leading) {
                            Text("GOOHAN PATCH")
                                .font(.system(size: 26, weight: .black, design: .rounded))
                            Text("Native 3106 engine • Admin ZCloudViet")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 8)

                    if !licenseManager.isActive {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Kích hoạt License GooHan").font(.headline)
                            SecureField("Nhập License Key", text: $inputKey)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            Button("Xác thực License") {
                                licenseManager.activate(key: inputKey)
                            }
                            .buttonStyle(.borderedProminent).tint(.pink)
                            .disabled(inputKey.isEmpty || licenseManager.isBusy)
                            if licenseManager.isBusy { ProgressView() }
                            if let error = licenseManager.message {
                                Text(error).font(.footnote).foregroundColor(.secondary)
                            }
                        }
                        .padding(16)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        HStack {
                            Text("Đã xác thực GooHan Admin")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                Task { await sync() }
                            } label: {
                                Label("Đồng bộ", systemImage: "arrow.clockwise")
                            }
                            .disabled(syncing || busyPackageID != nil)
                        }

                        if !filteredCategories.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(filteredCategories) { category in
                                        Button(category.name) {
                                            selectedCategory = category.id
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(category.id == selectedCategory ? .pink : .secondary)
                                    }
                                }
                            }
                        }

                        Text("Thư viện .3106 • \(visiblePackages.count) gói")
                            .font(.headline)
                        if visiblePackages.isEmpty {
                            Text("Không có gói .3106 được phát hành trong mục này.")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        ForEach(visiblePackages) { patch in
                            let active = GH6PlanStorage.activeReceipt(for: patch.id) != nil
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(patch.feature).font(.headline)
                                        Text("v\(patch.version) • \(active ? "Đang bật" : "Đã tắt")")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if busyPackageID == patch.id {
                                        ProgressView()
                                    } else {
                                        Toggle(
                                            patch.feature,
                                            isOn: Binding(
                                                get: {
                                                    _ = refreshReceipt
                                                    return GH6PlanStorage.activeReceipt(for: patch.id) != nil
                                                },
                                                set: { on in
                                                    Task { await toggle(patch, on: on) }
                                                }
                                            )
                                        )
                                        .labelsHidden()
                                        .tint(.pink)
                                        .disabled(busyPackageID != nil || syncing)
                                    }
                                }
                                if !patch.description.isEmpty {
                                    Text(patch.description)
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .padding(15)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }

                    Text(statusText)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    Text("Áp dụng/khôi phục bằng DevicePatchService của 3106. Yêu cầu chữ ký có App Groups hợp lệ trên iOS 27. Sao lưu được giữ cho tới khi hoàn tất khôi phục; thao tác lỗi không được báo thành công.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(18)
            }
            .navigationTitle("GooHan • 3106")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .tint(.pink)
        .task { licenseManager.beginLaunchSession() }
        .onChange(of: licenseManager.isActive) { nowActive in
            if nowActive { Task { await sync() } }
        }
    }

    private func decoder() -> JSONDecoder {
        let result = JSONDecoder()
        result.keyDecodingStrategy = .convertFromSnakeCase
        return result
    }

    private func sync() async {
        guard !syncing && busyPackageID == nil else { return }
        syncing = true
        defer { syncing = false }
        do {
            let base = LicenseManager.serverURL
            let categoryData = try await licenseManager.authenticatedData(
                from: base.appendingPathComponent("api/categories")
            )
            let patchData = try await licenseManager.authenticatedData(
                from: base.appendingPathComponent("api/patches")
            )
            let incomingCategories = try decoder().decode(
                GH6CategoryList.self, from: categoryData
            ).categories
            let incomingPatches = try decoder().decode(
                GH6PackageList.self, from: patchData
            ).patches
            categories = incomingCategories
            packages = incomingPatches
            if !categories.contains(where: { $0.id == selectedCategory }),
               let first = categories.first {
                selectedCategory = first.id
            }
            statusText = "Đã đồng bộ \(incomingPatches.count) gói / \(incomingCategories.count) mục từ GooHan Admin."
        } catch {
            statusText = "Lỗi đồng bộ GooHan: \(error.localizedDescription)"
        }
    }

    private func project(from plan: GH6Plan, patch: GH6Package) throws -> PatchProject {
        guard patch.packageFormat == "3106",
              plan.format == "3105-project-v1" || plan.format == "3106-project-v1",
              plan.game == patch.game,
              let projectID = UUID(uuidString: plan.packageId),
              (1...100).contains(plan.rules.count) else {
            throw GH6Error.text("Kế hoạch Patch .3106 không hợp lệ")
        }
        guard patch.game == "free_fire" || patch.game == "free_fire_max" else {
            throw GH6Error.text("Hiện hỗ trợ Free Fire / Free Fire MAX")
        }
        let fallback = patch.game == "free_fire"
            ? "com.dts.freefireth" : "com.dts.freefiremax"
        let target = plan.bundleId ?? fallback
        guard target == fallback,
              patch.targetBundleId == nil || patch.targetBundleId == target else {
            throw GH6Error.text("Bundle ID trong gói không khớp Admin")
        }
        var seen = Set<String>()
        var totalBytes = 0
        let rules = try plan.rules.map { rule -> PatchRule in
            let clean = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            guard seen.insert(clean).inserted else {
                throw GH6Error.text("Các đường dẫn trong gói bị trùng")
            }
            totalBytes += rule.replacementData.count
            guard totalBytes <= 75 * 1024 * 1024 else {
                throw GH6Error.text("Gói vượt giới hạn 75 MB")
            }
            return PatchRule(
                bundleID: target,
                relativePath: clean,
                replacementFilename: (clean as NSString).lastPathComponent,
                replacementData: rule.replacementData
            )
        }
        return PatchProject(
            id: projectID,
            name: plan.name,
            author: "GooHan Admin",
            bundleIdentifiers: [target],
            rules: rules
        )
    }

    private func toggle(_ patch: GH6Package, on: Bool) async {
        guard busyPackageID == nil && !syncing else { return }
        busyPackageID = patch.id
        defer {
            busyPackageID = nil
            refreshReceipt += 1
        }
        do {
            if on {
                try await licenseManager.ensureAuthorized()
                guard patch.enabled, patch.packageFormat == "3106",
                      patch.id.count == 32,
                      patch.id.allSatisfy({ $0.isHexDigit }),
                      patch.downloadPath == "/downloads/" + patch.id,
                      patch.size > 0 && patch.size <= 75 * 1024 * 1024,
                      patch.sha256.count == 64 &&
                      patch.sha256.allSatisfy({ $0.isHexDigit }) else {
                    throw GH6Error.text("Metadata gói Patch không hợp lệ")
                }
                // The native 3106 SandboxAccess backend is selected by iOS.
                // Never treat presence of a .3106 package as proof of R/W.
                guard SandboxAccess.backend != .unsupported else {
                    throw GH6Error.text("iOS hiện tại không có backend 3106")
                }
                if SandboxAccess.needsWorseQuery && !SandboxAccess.hasAppGroup {
                    throw GH6Error.text("IPA đã ký thiếu quyền App Groups cần cho iOS 27")
                }
                let remote = LicenseManager.serverURL
                    .appendingPathComponent("downloads")
                    .appendingPathComponent(patch.id)
                let data = try await licenseManager.authenticatedData(from: remote)
                let sha = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined()
                guard data.count == patch.size, sha == patch.sha256.lowercased() else {
                    throw GH6Error.text("Tệp tải về không khớp SHA-256/kích thước")
                }
                let plan = try decoder().decode(GH6Plan.self, from: data)
                let project = try project(from: plan, patch: patch)
                try GH6PlanStorage.save(data, id: patch.id)
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.apply(project: project)
                }.value
                guard DevicePatchService.latestReceipt(projectID: project.id) != nil,
                      receipt.projectID == project.id else {
                    throw GH6Error.text("Không có biên nhận xác nhận đã ghi")
                }
                statusText = "Đã áp dụng \(patch.feature) bằng engine 3106 và lưu bản sao để khôi phục."
            } else {
                guard let receipt = GH6PlanStorage.activeReceipt(for: patch.id) else {
                    throw GH6Error.text("Không tìm thấy biên nhận để khôi phục")
                }
                try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.restore(receipt: receipt)
                }.value
                guard GH6PlanStorage.activeReceipt(for: patch.id) == nil else {
                    throw GH6Error.text("Giao dịch khôi phục chưa hoàn tất")
                }
                statusText = "Đã khôi phục \(patch.feature) từ bản sao lưu."
            }
        } catch {
            statusText = "Không thể \(on ? "bật" : "tắt") \(patch.feature): \(error.localizedDescription)"
        }
    }
}
