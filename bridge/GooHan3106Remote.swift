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

private struct GH6RecoveryEntry: Identifiable {
    let id: String
    let name: String
    let receipt: PatchTransactionReceipt
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

    static func recoverable() -> [GH6RecoveryEntry] {
        guard let example = try? url(for: "00000000000000000000000000000000"),
              let files = try? FileManager.default.contentsOfDirectory(
                at: example.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
              ) else { return [] }
        return files.compactMap { file -> GH6RecoveryEntry? in
            guard file.pathExtension == "json",
                  let plan = read(file.deletingPathExtension().lastPathComponent),
                  let receipt = activeReceipt(for: file.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            return GH6RecoveryEntry(
                id: file.deletingPathExtension().lastPathComponent,
                name: plan.name,
                receipt: receipt
            )
        }
    }
}

struct GooHan3106RemoteView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var licenseManager = LicenseManager()
    @State private var inputKey = ""
    @State private var packages: [GH6Package] = []
    @State private var categories: [GH6Category] = []
    @State private var selectedCategory = "free_fire_max"
    @AppStorage("GooHanThemeHex") private var themeHex = "#F479B7"
    @AppStorage("gohan.hybrid.package-format") private var packagePreference = "auto"
    @State private var showSettings = false
    @State private var showLegacyUnlockConfirmation = false
    @State private var busyPackageID: String?
    @State private var syncing = false
    @State private var statusText = "Đang kết nối GooHan Admin…"
    @State private var refreshReceipt = 0
    private var accent: Color { Color(gh6Hex: themeHex) }
    private var modelDisplayName: String {
        switch packagePreference {
        case "3105": return "Low"
        case "3106": return "Hight"
        default: return "Auto"
        }
    }
    private var effectiveFormat: String {
        let os = AppInfo.versionTuple
        if packagePreference == "3105" { return "3105" }
        if packagePreference == "3106" { return "3106" }
        // Upstream 3106 already selects its native kernel/bad_query/worse_query
        // backend by iOS version. This preference only chooses the Admin format.
        return os.major >= 27 || (os.major == 26 && os.minor >= 7) ? "3106" : "3105"
    }

    private var visiblePackages: [GH6Package] {
        packages.filter { patch in
            let active = GH6PlanStorage.activeReceipt(for: patch.id) != nil
            return (patch.categoryId ?? patch.game) == selectedCategory &&
                (patch.enabled || active) &&
                (patch.packageFormat == effectiveFormat || active)
        }
        .sorted {
            $0.sortOrder == $1.sortOrder
                ? $0.feature < $1.feature
                : $0.sortOrder < $1.sortOrder
        }
    }

    private var recoverable: [GH6RecoveryEntry] {
        _ = refreshReceipt
        return GH6PlanStorage.recoverable()
    }

    private var filteredCategories: [GH6Category] {
        categories.filter { category in
            category.enabled || packages.contains { patch in
                (patch.categoryId ?? patch.game) == category.id &&
                GH6PlanStorage.activeReceipt(for: patch.id) != nil
            }
        }.sorted {
            $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    categoryPicker
                    syncCard
                    HStack {
                        Label("CHỌN CHỨC NĂNG", systemImage: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        Spacer()
                        Text("\(visiblePackages.count) gói")
                            .foregroundColor(.white.opacity(0.58))
                    }
                    .foregroundColor(accent)

                    if licenseManager.isActive {
                        if visiblePackages.isEmpty {
                            panel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Chưa có chức năng")
                                        .font(.headline)
                                    Text("Chưa có gói .\(effectiveFormat) trong mục này. Hãy đồng bộ từ Admin.")
                                        .font(.footnote)
                                        .foregroundColor(.white.opacity(0.62))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(visiblePackages) { patch in
                            packageCard(patch)
                        }
                    } else {
                        licenseCard
                    }

                    panel {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: "info.circle.fill").foregroundColor(accent)
                            Text(statusText)
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.82))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Telegram: @gohanios")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(accent)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                }
                .padding(.horizontal, 17)
                .padding(.top, 20)
                .padding(.bottom, 26)
            }
            .background(GH6GridBackground(tint: accent))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("GOHAN iOS")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundColor(accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(accent)
                    }
                    .accessibilityLabel("Cài đặt GooHan")
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(accent)
        .sheet(isPresented: $showSettings) { settingsPanel }
        .task { licenseManager.beginLaunchSession() }
        .onChange(of: licenseManager.isActive) { nowActive in
            if nowActive { Task { await sync() } }
        }
    }

    private var hero: some View {
        panel(animated: true) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Spacer()
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(accent)
                }
                Text("GôHan iOS")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text("Aim • Chams • Mod Skin")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white.opacity(0.70))
            }
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if filteredCategories.isEmpty {
                    categoryButton("free_fire", title: "Free Fire")
                    categoryButton("free_fire_max", title: "Free Fire MAX")
                    categoryButton("free_fire_vn", title: "Free Fire VN")
                } else {
                    ForEach(filteredCategories) { category in
                        categoryButton(category.id, title: category.name)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func categoryButton(_ id: String, title: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedCategory = id
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .lineLimit(1)
                .foregroundColor(.white)
                .padding(.horizontal, 17)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .background(
                    selectedCategory == id ? accent.opacity(0.22) : Color.black.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(selectedCategory == id ? accent : .white.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var syncCard: some View {
        panel(animated: true) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: "cloud.fill")
                        .foregroundColor(accent)
                    Text("ĐỒNG BỘ TỪ ADMIN")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    Spacer()
                    if syncing {
                        ProgressView().tint(accent)
                    } else {
                        Button {
                            Task { await sync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(accent)
                        }
                        .disabled(!licenseManager.isActive || busyPackageID != nil)
                        .accessibilityLabel("Đồng bộ thư viện từ Admin")
                    }
                }
                Text("Các chức năng được cập nhật từ phía Admin.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.65))
            }
        }
    }

    private var licenseCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Kích hoạt License GooHan", systemImage: "key.fill")
                    .font(.headline)
                    .foregroundColor(accent)
                SecureField("Nhập License Key", text: $inputKey)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button {
                    licenseManager.activate(key: inputKey)
                } label: {
                    Text("Kích hoạt")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputKey.isEmpty || licenseManager.isBusy)
                if licenseManager.isBusy { ProgressView().tint(accent) }
                if let message = licenseManager.message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.67))
                }
            }
        }
    }

    private func packageCard(_ patch: GH6Package) -> some View {
        let active = GH6PlanStorage.activeReceipt(for: patch.id) != nil
        return panel {
            HStack(spacing: 13) {
                Image(systemName: active ? "checkmark.shield.fill" : "bolt.shield.fill")
                    .font(.system(size: 24))
                    .frame(width: 35)
                    .foregroundColor(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(patch.feature)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("v\(patch.version) • \(active ? "Đang bật" : "Đã tắt")")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                    if !patch.description.isEmpty {
                        Text(patch.description)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.52))
                            .lineLimit(2)
                    }
                    Text(active ? "Tắt & Khôi phục" : "Bật Chức Năng")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(accent)
                }
                Spacer(minLength: 6)
                if busyPackageID == patch.id {
                    ProgressView().tint(accent)
                } else {
                    Toggle("", isOn: Binding(
                        get: {
                            _ = refreshReceipt
                            return GH6PlanStorage.activeReceipt(for: patch.id) != nil
                        },
                        set: { on in Task { await toggle(patch, on: on) } }
                    ))
                    .labelsHidden()
                    .tint(accent)
                    .disabled(busyPackageID != nil || syncing || (!active && !patch.enabled))
                    .accessibilityLabel(active ? "Tắt và khôi phục" : "Bật Patch")
                }
            }
        }
    }

    private func panel<Content: View>(
        animated: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return content()
            .padding(17)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.14, blue: 0.19).opacity(0.90),
                                Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.86),
                                accent.opacity(0.09)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    if animated {
                        GH6LiquidGlassShine(accent: accent)
                            .clipShape(shape)
                    }
                }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            accent.opacity(0.20),
                            Color.white.opacity(0.07)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: accent.opacity(animated ? 0.16 : 0.08),
                    radius: animated ? 20 : 11, x: 0, y: 8)
    }

    private var settingsPanel: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Màu iPA")
                        .font(.headline)
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6),
                        spacing: 16
                    ) {
                        ForEach(0..<GH6Palette.all.count, id: \.self) { index in
                            let item = GH6Palette.all[index]
                            Button { withAnimation(.easeInOut(duration: 0.24)) { themeHex = item.1 } } label: {
                                Circle()
                                    .fill(Color(gh6Hex: item.1))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle().stroke(
                                            .white,
                                            lineWidth: themeHex == item.1 ? 2.5 : 0
                                        )
                                    )
                            }
                            .accessibilityLabel(item.0)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("Model Panel").font(.headline)
                        Picker("Model Panel", selection: $packagePreference) {
                            Text("Auto").tag("auto")
                            Text("Low").tag("3105")
                            Text("Hight").tag("3106")
                        }
                        .pickerStyle(.segmented)
                    }

                    if let expires = licenseManager.expirationDate {
                        Text("License có hiệu lực đến: \(expires.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    if !recoverable.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(recoverable) { entry in
                                    Button {
                                        Task { await restore(entry) }
                                    } label: {
                                        Label("Khôi phục \(entry.name)", systemImage: "arrow.uturn.backward")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .disabled(busyPackageID != nil || syncing)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Label("Khôi phục bản gốc", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                        .tint(accent)
                    }

                    if SandboxAccess.backend == .kernel && appState.needsUnlock {
                        Button {
                            showLegacyUnlockConfirmation = true
                        } label: {
                            Label("Kích hoạt quyền truy cập", systemImage: "lock.open.fill")
                        }
                        .disabled(appState.kernelExploitRunning)
                    }

                    Button("Đồng bộ ngay") {
                        showSettings = false
                        Task { await sync() }
                    }
                    .disabled(!licenseManager.isActive || syncing)
                    Button("Đăng xuất License") {
                        licenseManager.deactivate()
                        showSettings = false
                    }
                    .foregroundColor(.orange)
                }
                .padding(20)
            }
            .navigationTitle("GôHan iOS • Cài đặt")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { showSettings = false }
                }
            }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Xác nhận kích hoạt quyền truy cập",
            isPresented: $showLegacyUnlockConfirmation,
            titleVisibility: .visible
        ) {
            Button("Tiếp tục kích hoạt", role: .destructive) {
                appState.runKernelExploitIfNeeded()
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Chỉ dành cho thiết bị iOS 17/18 tương thích. Quá trình kích hoạt quyền truy cập có thể khiến thiết bị treo hoặc khởi động lại.")
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
        guard (patch.packageFormat == "3105" || patch.packageFormat == "3106"),
              plan.format == "3105-project-v1" || plan.format == "3106-project-v1",
              plan.game == patch.game,
              let projectID = UUID(uuidString: plan.packageId),
              (1...100).contains(plan.rules.count) else {
            throw GH6Error.text("Kế hoạch Patch không hợp lệ")
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

    private func restore(_ entry: GH6RecoveryEntry) async {
        guard busyPackageID == nil else { return }
        busyPackageID = entry.id
        defer {
            busyPackageID = nil
            refreshReceipt += 1
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try DevicePatchService.restore(receipt: entry.receipt)
            }.value
            guard GH6PlanStorage.activeReceipt(for: entry.id) == nil else {
                throw GH6Error.text("Biên nhận khôi phục chưa đóng")
            }
            statusText = "Đã khôi phục \(entry.name)."
        } catch {
            statusText = "Khôi phục thất bại: \(error.localizedDescription)"
        }
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
                guard patch.enabled, patch.packageFormat == effectiveFormat,
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
                    throw GH6Error.text("iOS hiện tại không có backend Patch khả dụng")
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
                statusText = "Đã áp dụng \(patch.feature) và lưu bản sao để khôi phục."
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


private enum GH6Palette {
    static let all: [(String, String)] = [
        ("Đỏ", "#FF4757"), ("Đỏ đậm", "#CD354C"), ("Cam", "#F97342"), ("Hổ phách", "#EFA53E"),
        ("Vàng", "#FFD45B"), ("Chanh", "#C8DB57"), ("Lục", "#69D688"), ("Ngọc", "#2CC999"),
        ("Xanh biển", "#2BCBB3"), ("Cyan", "#34CBDC"), ("Lam", "#4CA6FF"), ("Xanh trời", "#71BCFF"),
        ("Dương", "#458CF8"), ("Cobalt", "#576AF0"), ("Indigo", "#7770EF"), ("Tím", "#9D70E8"),
        ("Oải hương", "#C196F6"), ("Hồng tím", "#D27BD7"), ("Hồng", "#F479B7"), ("San hô", "#FF8A83"),
        ("Đồng", "#CE9B69"), ("Bạc", "#A7B8CF"), ("Trắng", "#F1F5FC"), ("Xám", "#8795AA")
    ]
}
private extension Color {
    init(gh6Hex hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let n = UInt64(raw, radix: 16) ?? 0xF479B7
        self.init(red: Double((n >> 16) & 255) / 255,
                  green: Double((n >> 8) & 255) / 255,
                  blue: Double(n & 255) / 255)
    }
}
private struct GH6GridBackground: View {
    let tint: Color
    var body: some View {
        ZStack {
            Color(red: 0.042, green: 0.051, blue: 0.075)
            RadialGradient(colors: [tint.opacity(0.25), .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 500)
            Canvas { context, size in
                var path = Path()
                let gap: CGFloat = 30
                for x in stride(from: CGFloat(0), through: size.width + gap, by: gap) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(0), through: size.height + gap, by: gap) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(tint.opacity(0.12)), lineWidth: 0.7)
            }
        }
        .ignoresSafeArea()
    }
}


// Animated material highlight, deliberately limited to the hero and sync card.
// Respect Reduce Motion and keep the native engine / transaction logic untouched.
private struct GH6LiquidGlassShine: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RadialGradient(
                    colors: [accent.opacity(0.14), .clear],
                    center: .topLeading,
                    startRadius: 8,
                    endRadius: 250
                )

                LinearGradient(
                    colors: [.clear, .white.opacity(0.13), .white.opacity(0.04), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: max(proxy.size.width * 0.46, 80))
                .rotationEffect(.degrees(18))
                .blur(radius: 12)
                .offset(x: reduceMotion ? 0 :
                        (moving ? proxy.size.width * 1.2 : -proxy.size.width * 1.2))
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 6.5).repeatForever(autoreverses: false)) {
                    moving = true
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
