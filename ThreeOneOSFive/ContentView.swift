import SwiftUI
import Foundation
import CryptoKit
import Darwin
import CoreFoundation

private struct GooPatch: Codable, Identifiable, Hashable {
    let id: String
    let game: String
    // Admin category is presentation; authenticated .3105 Bundle ID is target.
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
private struct GooResponse: Decodable { let patches: [GooPatch] }
private struct GooCategory: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let targetGame: String?
    let sortOrder: Int
    let enabled: Bool

    static let defaultCategories: [GooCategory] = [
        GooCategory(id: "free_fire", name: "Free Fire", targetGame: "free_fire", sortOrder: 0, enabled: true),
        GooCategory(id: "free_fire_max", name: "Free Fire MAX", targetGame: "free_fire_max", sortOrder: 10, enabled: true)
    ]
}
private struct GooCategoriesResponse: Decodable { let categories: [GooCategory] }
// Every field is optional so a partially updated Admin server does not
// prevent the iPhone from applying all other available content updates.
private struct GooConfig: Codable {
    let title: String?
    let kicker: String?
    let subtitle: String?
    let notice: String?
    let footer: String?
    let accentHex: String?
    let freeFireName: String?
    let freeFireMaxName: String?
    let applyLabel: String?
    let restoreLabel: String?
    let supportUrl: String?
    let sectionLabel: String?
    let themeLabel: String?
    let emptyTitle: String?
    let emptySubtitle: String?
    // Additional editable text; absent on older Admin deployments.
    let navigationTitle: String?
    let heroTagline: String?
    let syncTitle: String?
    let settingsTitle: String?
    let serverLabel: String?
    let syncButtonLabel: String?
}
private struct GooPlan: Codable {
    struct Rule: Codable {
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
private enum GooError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
// Presentation-only privacy filter. Bundle IDs remain untouched in .3105,
// Admin sync and the on-device Patch transaction.
private enum GooPublicText {
    static func withoutBundleIdentifiers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\b(?:[A-Za-z][A-Za-z0-9_-]*\.){2,}[A-Za-z0-9_-]+\b"#,
            with: "ứng dụng đích",
            options: .regularExpression
        )
    }
}

enum GooPalette {
    static let all: [(String, String)] = [
        ("Đỏ", "#FF4757"),("Đỏ đậm", "#CD354C"),("Cam", "#F97342"),("Hổ phách", "#EFA53E"),
        ("Vàng", "#FFD45B"),("Chanh", "#C8DB57"),("Lục", "#69D688"),("Ngọc", "#2CC999"),
        ("Xanh biển", "#2BCBB3"),("Cyan", "#34CBDC"),("Lam", "#4CA6FF"),("Xanh trời", "#71BCFF"),
        ("Dương", "#458CF8"),("Cobalt", "#576AF0"),("Indigo", "#7770EF"),("Tím", "#9D70E8"),
        ("Oải hương", "#C196F6"),("Hồng tím", "#D27BD7"),("Hồng", "#F479B7"),("San hô", "#FF8A83"),
        ("Đồng", "#CE9B69"),("Bạc", "#A7B8CF"),("Trắng", "#F1F5FC"),("Xám", "#8795AA")
    ]
}
private extension Color {
    init(gooHex hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let n = UInt64(raw, radix: 16) ?? 0xff4757
        self.init(red: Double((n >> 16) & 255) / 255,
                  green: Double((n >> 8) & 255) / 255,
                  blue: Double(n & 255) / 255)
    }
}
private struct GooGridBackground: View {
    let tint: Color
    var body: some View {
        ZStack {
            Color(red: 0.042, green: 0.051, blue: 0.075)
            RadialGradient(colors: [tint.opacity(0.25), .clear], center: .topTrailing,
                           startRadius: 10, endRadius: 500)
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
        }.ignoresSafeArea()
    }
}

private enum GooCache {
    static func path(_ name: String) throws -> URL {
        let app = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = app.appendingPathComponent("GooHanRemote", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    static func loadCatalog() -> [GooPatch] {
        guard let url = try? path("catalog.json"), let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([GooPatch].self, from: d)) ?? []
    }
    static func loadCategories() -> [GooCategory] {
        guard let url = try? path("categories.json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([GooCategory].self, from: data) else {
            return GooCategory.defaultCategories
        }
        return result
    }
    static func saveCategories(_ items: [GooCategory]) {
        guard let url = try? path("categories.json"),
              let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
    static func saveCatalog(_ items: [GooPatch]) {
        guard let url = try? path("catalog.json"), let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: url, options: .atomic)
    }
    static func loadConfig() -> GooConfig? {
        guard let url = try? path("config.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(GooConfig.self, from: data)
    }
    static func saveConfig(_ config: GooConfig) {
        guard let url = try? path("config.json"),
              let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: url, options: .atomic)
    }
    static func readPlan(_ id: String) -> GooPlan? {
        guard let url = try? path("plan_" + id + ".json"), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(GooPlan.self, from: data)
    }
    static func savePlan(_ data: Data, id: String) throws {
        try data.write(to: path("plan_" + id + ".json"), options: .atomic)
    }
    static func hasReceipt(for patch: GooPatch) -> Bool {
        guard let plan = readPlan(patch.id), let id = UUID(uuidString: plan.packageId) else { return false }
        return DevicePatchService.latestReceipt(projectID: id) != nil
    }
}

// This exercises the real PatchTransaction implementation, but ONLY inside
// a uniquely named temporary directory owned by the GooHan app. It does not
// resolve or access another application's container, and it grants no extra
// iOS privileges.
private enum GooHanSandboxTransactionProbe {
    static func run() throws -> String {
        let fm = FileManager.default
        let bundleID = "com.goohan.sandboxprobe"
        let root = fm.temporaryDirectory
            .appendingPathComponent("GooHanSandboxProbe-\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let target = documents.appendingPathComponent("probe.bin")
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let original = Data("GOOHAN_SANDBOX_ORIGINAL".utf8)
        let replacement = Data("GOOHAN_SANDBOX_REPLACED".utf8)

        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try original.write(to: target, options: .atomic)
        let project = PatchProject(
            name: "GooHan sandbox transaction diagnostic",
            bundleIdentifiers: [bundleID],
            rules: [
                PatchRule(
                    bundleID: bundleID,
                    relativePath: "Documents/probe.bin",
                    replacementFilename: "probe.bin",
                    replacementData: replacement
                )
            ]
        )
        let resolve: (String) throws -> URL = { identifier in
            guard identifier == bundleID else {
                throw GooError.message("Sandbox probe: Bundle ID không hợp lệ")
            }
            return root
        }

        let receipt = try PatchTransaction.apply(
            project: project,
            backupRoot: backups,
            containerResolver: resolve
        )
        // Attempt recovery even when an intermediate assertion fails. All
        // paths remain inside the unique, temporary probe directory.
        do {
            guard try Data(contentsOf: target) == replacement,
                  PatchTransaction.latestReceipt(projectID: project.id, backupRoot: backups) != nil else {
                throw GooError.message("Sandbox probe: ghi/biên nhận không khớp")
            }
            try PatchTransaction.restore(receipt: receipt, containerResolver: resolve)
            guard try Data(contentsOf: target) == original,
                  PatchTransaction.latestReceipt(projectID: project.id, backupRoot: backups) == nil else {
                throw GooError.message("Sandbox probe: khôi phục chưa chính xác")
            }
        } catch {
            try? PatchTransaction.restore(receipt: receipt, containerResolver: resolve)
            throw error
        }
        return "PASS: ghi → kiểm byte → lưu biên nhận → khôi phục bản gốc. Chỉ thử trong sandbox GooHan; chưa xác nhận quyền ghi ứng dụng khác."
    }
}

// Diagnostic only. Read the App Groups entitlement from the signed executable,
// not from the unsigned Xcode project or the untrusted embedded provision file.
// This makes no filesystem changes and NEVER grants access to another app.
private enum GooHanSigningPreflight {
    private typealias CreateSecTask = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CopyEntitlement = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?

    // nil = Security runtime did not expose the entitlement query.
    private static func signedAppGroups() -> [String]? {
        guard let library = dlopen(
            "/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY
        ) else { return nil }
        defer { dlclose(library) }
        guard let createSymbol = dlsym(library, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(library, "SecTaskCopyValueForEntitlement") else { return nil }
        let create = unsafeBitCast(createSymbol, to: CreateSecTask.self)
        let copy = unsafeBitCast(copySymbol, to: CopyEntitlement.self)
        guard let task = create(nil) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(task).release() }
        guard let key = CFStringCreateWithCString(
            kCFAllocatorDefault, "com.apple.security.application-groups",
            CFStringBuiltInEncodings.UTF8.rawValue
        ) else { return nil }
        let keyPointer = Unmanaged.passUnretained(key).toOpaque()
        guard let value = copy(task, keyPointer, nil) else { return [] }
        let object = Unmanaged<AnyObject>.fromOpaque(value).takeRetainedValue()
        guard let names = object as? [String] else { return nil }
        return names.filter { $0.hasPrefix("group.") }
    }

    static func report() -> String {
        let os = AppInfo.versionTuple
        let candidate = HybridBackendAdvisor.proposedBackend(
            major: os.major, minor: os.minor, patch: os.patch, build: AppInfo.osBuild
        )
        let integrated = HybridBackendAdvisor.integratedBackend(
            major: os.major, minor: os.minor, patch: os.patch, build: AppInfo.osBuild
        )
        let groups = signedAppGroups()
        let groupStatus: String
        if let groups {
            if groups.isEmpty {
                groupStatus = "MISSING (IPA ký không có App Groups)"
            } else {
                let reachable = groups.contains {
                    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
                }
                groupStatus = "có \(groups.count) group; vùng chia sẻ \(reachable ? "truy cập được" : "không khả dụng")"
            }
        } else {
            groupStatus = "UNKNOWN (không đọc được entitlement)"
        }
        return "iOS \(os.major).\(os.minor).\(os.patch) / \(AppInfo.osBuild) • " +
               "App Groups: \(groupStatus) • " +
               "backend đề xuất: \(candidate.rawValue) • " +
               "backend tích hợp: \(integrated.rawValue) • " +
               "worse_query adapter: \(HybridBackendAdvisor.worseQueryImplemented ? "READY" : "MISSING"). " +
               "Đây chỉ là chẩn đoán chữ ký/cấu hình; không thử ghi dữ liệu ứng dụng khác."
    }
}

struct ContentView: View {
    @EnvironmentObject private var licenseManager: LicenseManager
    // The endpoint remains connected but is not exposed in the user settings UI.
    // This URL is public configuration, NOT a password or secret.
    private let serverURL = "https://gohanpatch-adminpatch.zcloudviet.xyz"
    @AppStorage("GooHanThemeHex") private var themeHex = "#FF4757"
    @State private var game = "free_fire"
    @State private var catalog: [GooPatch] = GooCache.loadCatalog()
    @State private var categories: [GooCategory] = GooCache.loadCategories()
    @State private var title = "GooHan Patch"
    @State private var kicker = "GOOHAN • PATCH MANAGER"
    @State private var subtitle = "Admin-managed Patch Library"
    @State private var notice = "Tự động áp dụng khi thiết bị có quyền truy cập phù hợp."
    @State private var footer = "Chỉ báo thành công khi tác vụ ghi/khôi phục trả về kết quả hợp lệ."
    @State private var navigationTitle = "GOOHAN PATCH"
    @State private var heroTagline = "ONE-TOGGLE PATCH • BACKUP & RESTORE"
    @State private var syncTitle = "ĐỒNG BỘ TỪ ADMIN"
    @State private var sectionLabel = "THƯ VIỆN PATCH"
    @State private var themeLabel = "24 màu giao diện"
    @State private var emptyTitle = "Chưa có gói Patch"
    @State private var emptySubtitle = "Kiểm tra Admin và nhấn đồng bộ."
    @State private var applyLabel = "Bật Patch"
    @State private var restoreLabel = "Tắt & Khôi phục"
    @State private var supportUrl = ""
    @State private var settingsTitle = "GooHan • Cài đặt"
    @State private var serverLabel = "Địa chỉ máy chủ HTTPS"
    @State private var syncButtonLabel = "Đồng bộ ngay"
    @State private var ffName = "Free Fire"
    @State private var maxName = "Free Fire MAX"
    @State private var busyId: String?
    @State private var syncing = false
    @State private var inspectingId: String?
    @State private var sandboxTesting = false
    @State private var message = "Đang chờ đồng bộ"
    @State private var showSettings = false
    @State private var redrawReceipt = 0
    @State private var reconciling = false
    @Environment(\.scenePhase) private var scenePhase

    private var color: Color { Color(gooHex: themeHex) }
    // Fixed catalog edition. Does not grant access or change engine support.
    private var selectedPackageFormat: String { "3105" }
    private var availableCategories: [GooCategory] {
        // Keep a category visible while its active patches still need restoration.
        let activeIDs = Set(catalog.filter { GooCache.hasReceipt(for: $0) }
            .map { $0.categoryId ?? $0.game })
        return categories.filter { $0.enabled || activeIDs.contains($0.id) }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
    }
    private var visible: [GooPatch] {
        catalog.filter {
            ($0.categoryId ?? $0.game) == game &&
            ($0.enabled || GooCache.hasReceipt(for: $0)) &&
            ($0.packageFormat.lowercased() == selectedPackageFormat || GooCache.hasReceipt(for: $0))
        }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.feature < $1.feature : $0.sortOrder < $1.sortOrder }
    }
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    gamePicker
                    infoCard
                    HStack {
                        Label(sectionLabel, systemImage: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        Spacer()
                        Text("\(visible.count) gói").foregroundColor(.white.opacity(0.55))
                    }
                    .foregroundColor(color)
                    if visible.isEmpty {
                        card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(emptyTitle).font(.headline)
                                Text(emptySubtitle)
                                    .font(.footnote).foregroundColor(.white.opacity(0.56))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(visible) { patch in patchCard(patch) }
                    card {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: "info.circle.fill").foregroundColor(color)
                            Text(GooPublicText.withoutBundleIdentifiers(message))
                                .font(.footnote).foregroundColor(.white.opacity(0.8))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(footer)
                        .font(.caption2).foregroundColor(.white.opacity(0.44))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center).padding(.vertical, 14)
                }.padding(.horizontal, 17).padding(.top, 18).padding(.bottom, 25)
            }
            .background(GooGridBackground(tint: color))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Group {
                        if navigationTitle == "GOOHAN PATCH" {
                            HStack(spacing: 5) {
                                Text("GOOHAN").fontWeight(.black).foregroundColor(color)
                                Text("PATCH").fontWeight(.medium)
                            }
                        } else {
                            Text(navigationTitle).fontWeight(.black).foregroundColor(color)
                                .lineLimit(1).minimumScaleFactor(0.65)
                        }
                    }.font(.system(size: 15, design: .rounded))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3").foregroundColor(color)
                    }.accessibilityLabel("Cài đặt và 24 màu")
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { settingsView }
        .task {
            if let saved = GooCache.loadConfig() { applyConfig(saved) }
            await sync()
            await reconcileExternalRestores()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await reconcileExternalRestores() }
            }
        }
    }

    private var header: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(kicker)
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .tracking(1.5).foregroundColor(color)
                    Spacer()
                    Image(systemName: "shield.lefthalf.filled").foregroundColor(color)
                }
                Text(title).font(.system(size: 33, weight: .black, design: .rounded)).lineLimit(2)
                Text(subtitle).font(.subheadline).foregroundColor(.white.opacity(0.62))
                Text(heroTagline)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.4).foregroundColor(color)
            }
        }
    }
    private var gamePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableCategories) { category in
                    gameButton(category.id, category.name)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Danh sách mục lớn đồng bộ từ Admin")
    }
    private func gameButton(_ key: String, _ name: String) -> some View {
        Button { game = key } label: {
            Text(name).font(.system(size: 13, weight: .bold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(game == key ? color.opacity(0.23) : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(game == key ? color : .white.opacity(0.08)))
                .foregroundColor(.white)
        }.buttonStyle(.plain)
    }
    private var infoCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "cloud.fill").foregroundColor(color)
                    Text(syncTitle)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Spacer()
                    if syncing { ProgressView().tint(color) }
                    else {
                        Button { Task { await sync() } } label: {
                            Image(systemName: "arrow.clockwise").foregroundColor(color)
                        }.disabled(busyId != nil)
                    }
                }
                Text(GooPublicText.withoutBundleIdentifiers(notice)).font(.footnote).foregroundColor(.white.opacity(0.62))
                if selectedPackageFormat == "3106" {
                    Text("Gói .3106 được kiểm tra tính toàn vẹn bằng SHA-256. Backend ghi/khôi phục trên iOS 27 chưa được tích hợp.")
                        .font(.caption).foregroundColor(.orange)
                    Button {
                        Task { await runSandboxTransactionProbe() }
                    } label: {
                        HStack(spacing: 8) {
                            if sandboxTesting {
                                ProgressView().tint(color)
                            } else {
                                Image(systemName: "checkmark.shield")
                            }
                            Text(sandboxTesting ? "Đang thử giao dịch trong sandbox…" :
                                 "Thử ghi & khôi phục trong sandbox GooHan")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(color)
                    }
                    .buttonStyle(.plain)
                    .disabled(sandboxTesting || syncing || inspectingId != nil || busyId != nil)
                }
            }
        }
    }
    private func patchCard(_ patch: GooPatch) -> some View {
        let active = GooCache.hasReceipt(for: patch)
        return card {
            HStack(spacing: 13) {
                Image(systemName: active ? "checkmark.shield.fill" : "bolt.shield.fill")
                    .font(.system(size: 24, weight: .medium)).foregroundColor(color)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(patch.feature).font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("v\(patch.version)  ·  \(active ? "Đang bật" : "Đã tắt")")
                        .font(.caption).foregroundColor(.white.opacity(0.56))
                    if !patch.description.isEmpty {
                        Text(GooPublicText.withoutBundleIdentifiers(patch.description)).font(.caption2)
                            .foregroundColor(.white.opacity(0.46)).lineLimit(2)
                    }
                    Text(active ? restoreLabel : applyLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color.opacity(0.8))
                }
                Spacer(minLength: 3)
                if busyId == patch.id { ProgressView().tint(color) }
                else {
                    Toggle("", isOn: Binding(
                        get: { _ = redrawReceipt; return GooCache.hasReceipt(for: patch) },
                        set: { newValue in Task { await toggle(patch, on: newValue) } }
                    ))
                    .labelsHidden().tint(color)
                    .disabled(busyId != nil || reconciling ||
                              (!active && (!GooHanPackagePreference.canApply(format: patch.packageFormat) ||
                                !ExploitSupportPolicy.isSupported(
                                    major: AppInfo.versionTuple.major,
                                    minor: AppInfo.versionTuple.minor,
                                    patch: AppInfo.versionTuple.patch,
                                    build: AppInfo.osBuild
                                ))))
                    .accessibilityLabel(active ? restoreLabel : applyLabel)
                }
            }
            if patch.packageFormat == "3106" && !active {
                Button {
                    Task { await inspectPackage(patch) }
                } label: {
                    HStack(spacing: 7) {
                        if inspectingId == patch.id {
                            ProgressView().tint(color)
                        } else {
                            Image(systemName: "checkmark.shield")
                        }
                        Text(inspectingId == patch.id ? "Đang kiểm tra gói .3106" : "Kiểm tra gói .3106 (không ghi tệp)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(color)
                }
                .disabled(inspectingId != nil || syncing || busyId != nil)
                .buttonStyle(.plain)
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(17).background(Color(red: 0.093, green: 0.103, blue: 0.13).opacity(0.96),
                                         in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(.white.opacity(0.085), lineWidth: 1))
    }
    private var settingsView: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(themeLabel).font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 16) {
                        ForEach(0..<GooPalette.all.count, id: \.self) { index in
                            let item = GooPalette.all[index]
                            Button { themeHex = item.1 } label: {
                                Circle().fill(Color(gooHex: item.1)).frame(width: 36, height: 36)
                                    .overlay(Circle().stroke(.white, lineWidth: themeHex == item.1 ? 2.5 : 0))
                            }.accessibilityLabel(item.0)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model Panel").font(.headline)
                        Text("Đang chọn Low")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    if let link = URL(string: supportUrl), link.scheme == "https" {
                        Link("Hỗ trợ", destination: link)
                            .font(.subheadline).foregroundColor(color)
                    }
                    Text("Bản này chỉ có thể thao tác với dữ liệu khi iOS thực sự cấp quyền. Không có thao tác chọn thư mục; nếu không đủ quyền, công tắc sẽ giữ trạng thái OFF và hiển thị lỗi.")
                        .font(.footnote).foregroundColor(.secondary)
                    if let expiry = licenseManager.expirationDate {
                        Text("License có hiệu lực đến: \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    Button("Đăng xuất License") { licenseManager.deactivate() }
                        .foregroundColor(.orange)
                    Button(syncButtonLabel) {
                        showSettings = false
                        Task { await sync() }
                    }.buttonStyle(.borderedProminent).tint(color)
                }.padding(20)
            }
            .navigationTitle(settingsTitle)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Xong") { showSettings = false }
            }}
        }.preferredColorScheme(.dark)
    }
    private func baseURL() throws -> URL {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else {
            throw GooError.message("Hãy nhập một URL HTTPS hợp lệ")
        }
        return url
    }
    private func getData(_ url: URL) async throws -> Data {
        try await licenseManager.authenticatedData(from: url)
    }
    private func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    private func applyConfig(_ cfg: GooConfig) {
        title = cfg.title ?? title
        kicker = cfg.kicker ?? kicker
        subtitle = cfg.subtitle ?? subtitle
        notice = cfg.notice ?? notice
        footer = cfg.footer ?? footer
        navigationTitle = cfg.navigationTitle ?? navigationTitle
        heroTagline = cfg.heroTagline ?? heroTagline
        syncTitle = cfg.syncTitle ?? syncTitle
        sectionLabel = cfg.sectionLabel ?? sectionLabel
        themeLabel = cfg.themeLabel ?? themeLabel
        emptyTitle = cfg.emptyTitle ?? emptyTitle
        emptySubtitle = cfg.emptySubtitle ?? emptySubtitle
        applyLabel = cfg.applyLabel ?? applyLabel
        restoreLabel = cfg.restoreLabel ?? restoreLabel
        supportUrl = cfg.supportUrl ?? supportUrl
        settingsTitle = cfg.settingsTitle ?? settingsTitle
        serverLabel = cfg.serverLabel ?? serverLabel
        syncButtonLabel = cfg.syncButtonLabel ?? syncButtonLabel
        ffName = cfg.freeFireName ?? ffName
        maxName = cfg.freeFireMaxName ?? maxName
        if UserDefaults.standard.object(forKey: "GooHanThemeHex") == nil,
           let hex = cfg.accentHex,
           hex.range(of: "^#[A-Fa-f0-9]{6}$", options: .regularExpression) != nil {
            themeHex = hex
        }
    }
    private func sync() async {
        if syncing { return }
        syncing = true
        defer { syncing = false }
        do {
            let base = try baseURL()
            // A configuration read error must be visible, not silently ignored.
            // Patches still sync even when the branding endpoint is unavailable.
            var configWarning: String?
            do {
                let payload = try await getData(base.appendingPathComponent("api/config"))
                let cfg = try jsonDecoder().decode(GooConfig.self, from: payload)
                applyConfig(cfg)
                GooCache.saveConfig(cfg)
            } catch {
                configWarning = "Không tải được nội dung từ Admin: \(error.localizedDescription)"
            }
            // v5.11: fetch all public categories and patches in the same sync.
            // If the server is still v5.10.1, retain the previous FF/FF MAX API.
            let incoming: [GooPatch]
            let fetchedCategories: [GooCategory]
            do {
                let metadata = try await getData(base.appendingPathComponent("api/categories"))
                let response = try jsonDecoder().decode(GooCategoriesResponse.self, from: metadata)
                let packages = try await getData(base.appendingPathComponent("api/patches"))
                incoming = try jsonDecoder().decode(GooResponse.self, from: packages).patches
                fetchedCategories = response.categories
            } catch {
                var legacy: [GooPatch] = []
                for key in ["free_fire", "free_fire_max"] {
                    var parts = URLComponents(url: base.appendingPathComponent("api/patches"), resolvingAgainstBaseURL: false)!
                    parts.queryItems = [URLQueryItem(name: "game", value: key)]
                    guard let url = parts.url else { continue }
                    let response = try jsonDecoder().decode(GooResponse.self, from: await getData(url))
                    legacy += response.patches.filter { $0.game == key }
                }
                incoming = legacy
                fetchedCategories = [
                    GooCategory(id: "free_fire", name: ffName, targetGame: "free_fire", sortOrder: 0, enabled: true),
                    GooCategory(id: "free_fire_max", name: maxName, targetGame: "free_fire_max", sortOrder: 10, enabled: true)
                ]
            }
            let old = GooCache.loadCatalog()
            let activeMissing = old.filter { oldPatch in
                !incoming.contains(where: { $0.id == oldPatch.id }) && GooCache.hasReceipt(for: oldPatch)
            }
            let categoryIDs = Set(fetchedCategories.map(\.id))
            let retainedCategories = categories.filter { previous in
                !categoryIDs.contains(previous.id) && activeMissing.contains {
                    ($0.categoryId ?? $0.game) == previous.id
                }
            }
            // Update visible state only after receiving both API payloads.
            catalog = incoming + activeMissing
            categories = fetchedCategories + retainedCategories
            if !availableCategories.contains(where: { $0.id == game }),
               let first = availableCategories.first { game = first.id }
            GooCache.saveCatalog(catalog)
            GooCache.saveCategories(categories)
            message = "Đã đồng bộ \(incoming.count) gói / \(fetchedCategories.count) mục lớn từ Admin." +
                      (configWarning.map { " \($0)" } ?? "")
        } catch {
            message = "Lỗi đồng bộ: \(error.localizedDescription). Các gói đang bật vẫn được giữ để khôi phục."
        }
    }
    private func project(from plan: GooPlan, for patch: GooPatch) throws -> PatchProject {
        guard (patch.packageFormat == "3105" || patch.packageFormat == "3106"),
              plan.format == "3105-project-v1", plan.game == patch.game,
              let uuid = UUID(uuidString: plan.packageId),
              (1...100).contains(plan.rules.count) else {
            throw GooError.message("Kế hoạch Patch không hợp lệ")
        }
        // New packages carry the authenticated target bundle in the server plan;
        // old FF/MAX packages remain compatible with the original fixed mapping.
        let fallback = patch.game == "free_fire" ? "com.dts.freefireth" : "com.dts.freefiremax"
        let bundleID = plan.bundleId ?? fallback
        guard (try? PatchPathValidator.canonicalBundleIdentifier(bundleID)) == bundleID,
              !bundleID.lowercased().hasPrefix("com.apple."),
              !bundleID.lowercased().hasPrefix("systemgroup."),
              !bundleID.lowercased().hasPrefix("group.com.apple."),
              let serverBundle = patch.targetBundleId ?? ((plan.bundleId == nil) ? fallback : nil),
              bundleID == serverBundle else {
            throw GooError.message("Ứng dụng đích trong gói Patch không khớp dữ liệu Admin")
        }
        var seen = Set<String>()
        let rules: [PatchRule] = try plan.rules.map { rule in
            let safe = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            guard seen.insert(safe).inserted else { throw GooError.message("Gói có đường dẫn trùng") }
            return PatchRule(bundleID: bundleID, relativePath: safe,
                             replacementFilename: (safe as NSString).lastPathComponent,
                             replacementData: rule.replacementData)
        }
        return PatchProject(id: uuid, name: plan.name, bundleIdentifiers: [bundleID], rules: rules)
    }
    // If another process already restored every destination to its original
    // fingerprint, close only the stale receipt and refresh the visible switch.
    // Divergent/unknown contents are never overwritten by this reconciliation.
    private func reconcileExternalRestores() async {
        guard busyId == nil && !reconciling else { return }
        reconciling = true
        defer { reconciling = false; redrawReceipt += 1 }
        let snapshot = catalog
        let count = await Task.detached(priority: .utility) { () -> Int in
            var closed = 0
            for patch in snapshot {
                guard let plan = GooCache.readPlan(patch.id),
                      let id = UUID(uuidString: plan.packageId),
                      let receipt = DevicePatchService.latestReceipt(projectID: id) else {
                    continue
                }
                if (try? DevicePatchService.reconcileAlreadyRestored(receipt: receipt)) == true {
                    closed += 1
                }
            }
            return closed
        }.value
        if count > 0 {
            message = "Đã phát hiện \(count) gói được khôi phục từ bên ngoài. Công tắc đã cập nhật về OFF; có thể bật lại."
        }
    }

    private func runSandboxTransactionProbe() async {
        guard !sandboxTesting && !syncing && busyId == nil && inspectingId == nil else { return }
        sandboxTesting = true
        defer { sandboxTesting = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try GooHanSandboxTransactionProbe.run()
            }.value
            message = "Kiểm tra giao dịch GooHan: \(result)"
        } catch {
            message = "Kiểm tra giao dịch GooHan thất bại: \(error.localizedDescription). Không có thay đổi nào tới ứng dụng khác."
        }
    }

    // Download and validate an Admin-distributed .3106 plan without requesting
    // filesystem access. This is NOT a substitute for a verified iOS 27 backend.
    private func inspectPackage(_ patch: GooPatch) async {
        guard inspectingId == nil && busyId == nil && !syncing else { return }
        inspectingId = patch.id
        defer { inspectingId = nil }
        do {
            guard patch.packageFormat == "3106", patch.enabled else {
                throw GooError.message("Chỉ kiểm tra gói .3106 đã được xuất bản")
            }
            guard patch.id.count == 32, patch.id.allSatisfy({ $0.isHexDigit }),
                  patch.downloadPath == "/downloads/" + patch.id,
                  patch.size > 0 && patch.size <= 75 * 1024 * 1024,
                  patch.sha256.count == 64,
                  patch.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw GooError.message("Metadata gói .3106 không hợp lệ")
            }
            try await licenseManager.ensureAuthorized()
            let base = try baseURL()
            let remote = base.appendingPathComponent("downloads").appendingPathComponent(patch.id)
            let data = try await getData(remote)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == patch.size, hash == patch.sha256.lowercased() else {
                throw GooError.message("Gói .3106 không khớp SHA-256 hoặc kích thước")
            }
            let plan = try jsonDecoder().decode(GooPlan.self, from: data)
            let project = try project(from: plan, for: patch)
            let total = project.rules.reduce(0) { $0 + $1.replacementData.count }
            message = "Đã kiểm tra .3106: \(project.rules.count) tệp, \(total) byte, Bundle ID hợp lệ. Chưa ghi vào game vì backend iOS 27 chưa được tích hợp."
        } catch {
            message = "Kiểm tra .3106 thất bại: \(error.localizedDescription)"
        }
    }

    private func toggle(_ patch: GooPatch, on: Bool) async {
        guard busyId == nil && !reconciling else { return }
        busyId = patch.id
        defer { busyId = nil; redrawReceipt += 1 }
        do {
            if on {
                try await licenseManager.ensureAuthorized()
                guard !GooCache.hasReceipt(for: patch) else { return }
                guard patch.enabled, patch.packageFormat == "3105" else {
                    throw GooError.message("Chỉ hỗ trợ gói .3105 đang được Admin xuất bản")
                }
                guard let section = categories.first(where: { $0.id == (patch.categoryId ?? patch.game) }),
                      section.enabled else {
                    throw GooError.message("Mục lớn đã bị ẩn hoặc không tồn tại")
                }
                if let requiredGame = section.targetGame {
                    guard patch.game == requiredGame,
                          patch.targetBundleId == nil || patch.targetBundleId ==
                            (requiredGame == "free_fire" ? "com.dts.freefireth" : "com.dts.freefiremax") else {
                        throw GooError.message("Gói Patch không thuộc ứng dụng của mục Free Fire / MAX")
                    }
                } else if patch.targetBundleId == nil {
                    throw GooError.message("Admin chưa trả thông tin ứng dụng đích cho gói Patch. Hãy kiểm tra Web Admin, đăng lại .3105 rồi Đồng bộ Admin.")
                }
                guard patch.id.count == 32, patch.id.allSatisfy({ $0.isHexDigit }),
                      patch.downloadPath == "/downloads/" + patch.id,
                      patch.size > 0 && patch.size <= 75 * 1024 * 1024 else {
                    throw GooError.message("Thông tin gói Patch không hợp lệ")
                }
                let root = try baseURL()
                let remote = root.appendingPathComponent("downloads").appendingPathComponent(patch.id)
                let data = try await getData(remote)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count == patch.size, hash == patch.sha256.lowercased() else {
                    throw GooError.message("Không khớp SHA-256 hoặc kích thước file")
                }
                let plan = try jsonDecoder().decode(GooPlan.self, from: data)
                let project = try project(from: plan, for: patch)
                // Persist before applying so recovery stays reachable after a network outage.
                try GooCache.savePlan(data, id: patch.id)
                _ = try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.apply(project: project)
                }.value
                guard GooCache.hasReceipt(for: patch) else {
                    throw GooError.message("Không thấy biên nhận Patch; không thể xác nhận thành công")
                }
                message = "Đã áp dụng \(patch.feature) vào ứng dụng đích; đã lưu biên nhận khôi phục."
            } else {
                guard let plan = GooCache.readPlan(patch.id), let id = UUID(uuidString: plan.packageId),
                      let receipt = DevicePatchService.latestReceipt(projectID: id) else {
                    throw GooError.message("Không tìm thấy biên nhận để khôi phục")
                }
                try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.restore(receipt: receipt)
                }.value
                guard DevicePatchService.latestReceipt(projectID: id) == nil else {
                    throw GooError.message("Khôi phục chưa hoàn tất; vẫn giữ trạng thái bật")
                }
                message = "Đã tắt \(patch.feature). Tệp đã là bản gốc hoặc đã được khôi phục từ bản sao lưu."
            }
        } catch {
            message = "Không thể \(on ? "bật" : "tắt") \(patch.feature): \(error.localizedDescription)"
        }
    }
}

// Available even when a key expires. Restoring the original files never
// needs a server session, so an expired/revoked key cannot trap an active Patch.
struct GooHanRecoveryPanel: View {
    @State private var result = ""
    @State private var busy = false
    @State private var refreshID = UUID()

    private var recoverable: [GooPatch] {
        _ = refreshID
        return GooCache.loadCatalog().filter { GooCache.hasReceipt(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                Text("Khôi phục tệp gốc")
            }.font(.headline)
            Text("Ngay cả khi key đã hết hạn, bạn vẫn có thể khôi phục những gói đã bật trên thiết bị này.")
                .font(.caption).foregroundColor(.white.opacity(0.65))
            ForEach(recoverable) { patch in
                Button("Khôi phục \(patch.feature)") {
                    guard !busy else { return }
                    busy = true
                    Task {
                        defer { busy = false; refreshID = UUID() }
                        do {
                            guard let plan = GooCache.readPlan(patch.id),
                                  let id = UUID(uuidString: plan.packageId),
                                  let receipt = DevicePatchService.latestReceipt(projectID: id) else { return }
                            try await Task.detached(priority: .userInitiated) {
                                try DevicePatchService.restore(receipt: receipt)
                            }.value
                            result = "Đã khôi phục \(patch.feature)"
                        } catch { result = error.localizedDescription }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            }
            if recoverable.isEmpty {
                Text("Không có bản Patch nào cần khôi phục.")
                    .font(.caption).foregroundColor(.white.opacity(0.4))
            }
            if !result.isEmpty { Text(GooPublicText.withoutBundleIdentifiers(result)).font(.caption).foregroundColor(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(red: 0.09, green: 0.11, blue: 0.16), in: RoundedRectangle(cornerRadius: 22))
    }
}
