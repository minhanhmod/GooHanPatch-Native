import SwiftUI
import Foundation
import CryptoKit
import UIKit

private struct GooPatch: Codable, Identifiable, Hashable {
    let id: String
    let game: String
    // Admin category is presentation; authenticated .3105 Bundle ID is target.
    let categoryId: String?
    let subId: String?
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
private struct GooCatalogSub: Codable, Identifiable, Hashable {
    let id: String
    let majorId: String
    let name: String
    let sortOrder: Int
    let enabled: Bool
}
// Public category thumbnails only. Cache lives in this app's own Caches directory.
// Full content-addressed URLs act as version keys; a changed icon is a new key.
private actor GooIconCache {
    static let shared = GooIconCache()
    private let memory = NSCache<NSURL, NSData>()
    private var pending: [URL: Task<Data?, Never>] = [:]
    private static let maxImageBytes = 4 * 1024 * 1024

    private init() {
        memory.countLimit = 80
        memory.totalCostLimit = 12 * 1024 * 1024
    }

    func data(for url: URL) async -> Data? {
        if let hit = memory.object(forKey: url as NSURL) { return hit as Data }
        if let task = pending[url] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            await Self.readOrDownload(url)
        }
        pending[url] = task
        let result = await task.value
        pending[url] = nil
        if let result {
            memory.setObject(result as NSData, forKey: url as NSURL, cost: result.count)
        }
        return result
    }

    func prefetch(_ urls: [URL]) async {
        let unique = Array(Set(urls))
        for start in stride(from: 0, to: unique.count, by: 4) {
            if Task.isCancelled { return }
            let batch = Array(unique[start..<min(start + 4, unique.count)])
            await withTaskGroup(of: Void.self) { group in
                for url in batch {
                    group.addTask { _ = await self.data(for: url) }
                }
            }
        }
    }

    private static func cacheFile(_ url: URL) -> URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = root.appendingPathComponent("GooHanCategoryIcons-v1", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(key + ".png")
    }

    private static func isCacheableImage(_ data: Data) -> Bool {
        // The file suffix is a versioned server path, not a reliable image codec.
        !data.isEmpty && data.count <= maxImageBytes && UIImage(data: data) != nil
    }

    private static func readOrDownload(_ url: URL) async -> Data? {
        let fm = FileManager.default
        let file = cacheFile(url)
        if let file, let data = try? Data(contentsOf: file), isCacheableImage(data) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return data
        }
        if let file { try? fm.removeItem(at: file) }
        do {
            let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url?.scheme == "https",
                  http.url?.host == url.host,
                  isCacheableImage(data) else { return nil }
            if let file {
                try? data.write(to: file, options: .atomic)
                prune(file.deletingLastPathComponent())
            }
            return data
        } catch {
            return nil
        }
    }

    private static func prune(_ directory: URL) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        let files = urls.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard url.pathExtension == "png", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.date < $1.date }
        var bytes = files.reduce(0) { $0 + $1.size }
        var count = files.count
        for file in files {
            if bytes <= 24 * 1024 * 1024 && count <= 80 { break }
            do {
                try fm.removeItem(at: file.url)
                count -= 1
                bytes -= file.size
            } catch { continue }
        }
    }
}

private struct GooIconRequest: Hashable {
    let url: URL?
    let revision: Int
}

private struct GooCachedIcon<Placeholder: View>: View {
    let url: URL?
    let revision: Int
    let placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var shownURL: URL?

    init(url: URL?, revision: Int, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.revision = revision
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if shownURL == url, let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url {
                // Render using the previously working loader immediately.
                // Cache failure, response format or storage errors never block display.
                AsyncImage(url: url) { phase in
                    if let loaded = phase.image {
                        loaded.resizable().scaledToFill()
                    } else {
                        placeholder()
                    }
                }
                .id(GooIconRequest(url: url, revision: revision))
            } else {
                placeholder()
            }
        }
        .task(id: GooIconRequest(url: url, revision: revision)) {
            guard let url else {
                image = nil
                shownURL = nil
                return
            }
            if shownURL == url, image != nil { return }
            let data = await GooIconCache.shared.data(for: url)
            guard !Task.isCancelled else { return }
            if let data, let decoded = UIImage(data: data) {
                image = decoded
                shownURL = url
            }
        }
    }
}

private struct GooGlassPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.05), value: configuration.isPressed)
    }
}
private struct GooCategory: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let targetGame: String?
    let sortOrder: Int
    let enabled: Bool
    var iconUrl: String? = nil
    var subcategories: [GooCatalogSub]? = nil

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
// Presentation only: animated glass bubbles, compatible with older SwiftUI.
// Static color-wash wallpaper: no looping animation or moving blur layers.
private struct GooGridBackground: View {
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.043, blue: 0.071)
            if !reduceTransparency {
                GeometryReader { geo in
                    let radius = max(geo.size.width, geo.size.height)
                    ZStack {
                        RadialGradient(colors: [tint.opacity(0.53), tint.opacity(0.19), .clear],
                                       center: UnitPoint(x: 0.10, y: 0.12),
                                       startRadius: 0, endRadius: radius * 0.65)
                        RadialGradient(colors: [Color.indigo.opacity(0.42), Color.blue.opacity(0.12), .clear],
                                       center: UnitPoint(x: 0.95, y: 0.36),
                                       startRadius: 0, endRadius: radius * 0.58)
                        RadialGradient(colors: [tint.opacity(0.36), tint.opacity(0.09), .clear],
                                       center: UnitPoint(x: 0.74, y: 0.94),
                                       startRadius: 0, endRadius: radius * 0.60)
                        RadialGradient(colors: [Color.cyan.opacity(0.15), .clear],
                                       center: UnitPoint(x: 0.05, y: 0.73),
                                       startRadius: 0, endRadius: radius * 0.42)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// Lightweight glass appearance. No backdrop sampling, blur or per-card shadow.
private struct GooBubbleGlass: ViewModifier {
    let tint: Color
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                if reduceTransparency {
                    shape.fill(Color(red: 0.12, green: 0.13, blue: 0.18))
                } else {
                    shape.fill(LinearGradient(
                        colors: [.white.opacity(0.17), tint.opacity(0.08), .black.opacity(0.22)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.64), .white.opacity(0.18), tint.opacity(0.40), .white.opacity(0.22)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                    .allowsHitTesting(false)
            }
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

struct ContentView: View {
    @EnvironmentObject private var licenseManager: LicenseManager
    // The endpoint remains connected but is not exposed in the user settings UI.
    // This URL is public configuration, NOT a password or secret.
    private let serverURL = "https://gohanpatch-adminpatch.zcloudviet.xyz"
    @AppStorage("GooHanThemeHex") private var themeHex = "#FF4757"
    @State private var game = "free_fire"
    @State private var majorOpen = false
    @State private var selectedSub: String? = nil
    @Environment(\.accessibilityReduceMotion) private var catalogReduceMotion
    @State private var catalog: [GooPatch] = GooCache.loadCatalog()
    @State private var categories: [GooCategory] = GooCache.loadCategories()
    @State private var iconRevision = 0
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
    @State private var message = "Đang chờ đồng bộ"
    @State private var showSettings = false
    @State private var redrawReceipt = 0
    @State private var reconciling = false
    @Environment(\.scenePhase) private var scenePhase

    private var color: Color { Color(gooHex: themeHex) }
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
            (($0.packageFormat.lowercased() == "3105" && $0.enabled) || GooCache.hasReceipt(for: $0))
        }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.feature < $1.feature : $0.sortOrder < $1.sortOrder }
    }
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    gamePicker
                    infoCard
                    if majorOpen && selectedSub != nil {
                    HStack {
                        Label(sectionLabel, systemImage: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        Spacer()
                        Text("\(groupedPackages.count) gói").foregroundColor(.white.opacity(0.55))
                    }
                    .foregroundColor(color)
                    if groupedPackages.isEmpty {
                        card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(emptyTitle).font(.headline)
                                Text(emptySubtitle)
                                    .font(.footnote).foregroundColor(.white.opacity(0.56))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(groupedPackages) { patch in patchCard(patch) }
                    }
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
        .task(id: iconRevision) {
            let urls = availableCategories.compactMap { iconAddress($0.iconUrl) }
            await GooIconCache.shared.prefetch(urls)
        }
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
    // Presentation-only navigation. Category IDs are not modified by grouping.
    private var selectedMajor: GooCategory? {
        availableCategories.first { $0.id == game }
    }
    private var groups: [GooCatalogSub] {
        (selectedMajor?.subcategories ?? []).filter { $0.enabled }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
    }
    private func displayGroup(_ patch: GooPatch) -> String? {
        guard let sub = patch.subId, !sub.isEmpty else { return "" }
        if groups.contains(where: { $0.id == sub }) { return sub }
        // Keep active receipts accessible even if the Admin hides a subgroup.
        if GooCache.hasReceipt(for: patch) { return "" }
        if selectedMajor?.subcategories?.contains(where: { $0.id == sub }) == true { return nil }
        return ""
    }
    private var groupedPackages: [GooPatch] {
        guard let sub = selectedSub else { return [] }
        return visible.filter { displayGroup($0) == sub }
    }
    private func catalogAnimate(_ change: () -> Void) {
        withAnimation(catalogReduceMotion ? nil : .easeOut(duration: 0.05), change)
    }
    private func iconAddress(_ path: String?) -> URL? {
        guard let path,
              path.range(of: #"^/uploads/major/[a-z0-9_]{2,64}/[0-9a-f]{64}\.png$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: path, relativeTo: LicenseManager.serverURL)?.absoluteURL
    }
    private func catalogGlass<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .modifier(GooBubbleGlass(tint: color, radius: 24))
    }
    private var gamePicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !majorOpen {
                Label("APP", systemImage: "square.grid.2x2.fill")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundColor(color)
                if availableCategories.isEmpty {
                    Text("Chưa có mục lớn. Hãy đồng bộ từ Admin.").font(.footnote).foregroundColor(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                    ForEach(availableCategories) { category in
                        Button {
                            catalogAnimate { game = category.id; selectedSub = nil; majorOpen = true }
                        } label: {
                            catalogGlass {
                                VStack(spacing: 9) {
                                    GooCachedIcon(url: iconAddress(category.iconUrl), revision: iconRevision) {
                                        ZStack {
                                            LinearGradient(colors: [color.opacity(0.7), Color.black.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                            Image(systemName: "square.grid.2x2.fill").font(.system(size: 27, weight: .semibold)).foregroundColor(.white)
                                        }
                                    }
                                    .frame(width: 66, height: 66)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    Text(category.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.78)
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }.frame(maxWidth: .infinity)
                            }
                        }.buttonStyle(GooGlassPress())
                    }
                }
            } else {
                Button {
                    catalogAnimate {
                        if selectedSub != nil { selectedSub = nil }
                        else { majorOpen = false }
                    }
                } label: {
                    Label(selectedSub == nil ? "Tất cả mục lớn" : (selectedMajor?.name ?? "Mục lớn"), systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold)).foregroundColor(color)
                }.buttonStyle(GooGlassPress())
                Text(selectedSub == nil ? (selectedMajor?.name ?? "Mục lớn") : (groups.first { $0.id == selectedSub }?.name ?? "Chung"))
                    .font(.title2.bold()).foregroundColor(.white)
                if selectedSub == nil {
                    ForEach(groups) { group in
                        groupRow(group.id, group.name)
                    }
                    if groups.isEmpty || visible.contains(where: { displayGroup($0) == "" }) {
                        groupRow("", "Chung")
                    }
                }
            }
        }
    }
    private func groupRow(_ id: String, _ name: String) -> some View {
        Button {
            catalogAnimate { selectedSub = id }
        } label: {
            catalogGlass {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.title2).foregroundColor(color)
                    Text(name).font(.headline).foregroundColor(.white)
                    Spacer()
                    Text(String(visible.filter { displayGroup($0) == id }.count))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(color)
                }.padding(6)
            }
        }.buttonStyle(GooGlassPress())
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
                    .labelsHidden().tint(color).disabled(busyId != nil || reconciling)
                    .accessibilityLabel(active ? restoreLabel : applyLabel)
                }
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(17)
            .modifier(GooBubbleGlass(tint: color, radius: 24))
    }

    private func settingsSection<Content: View>(_ title: String, icon: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.13), in: Circle())
                    .overlay(Circle().strokeBorder(color.opacity(0.40), lineWidth: 1))
                Text(title).font(.headline)
                Spacer(minLength: 0)
            }
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GooBubbleGlass(tint: color, radius: 26))
    }

    private var settingsView: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    settingsSection(themeLabel, icon: "paintpalette.fill") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 15) {
                            ForEach(0..<GooPalette.all.count, id: \.self) { index in
                                let item = GooPalette.all[index]
                                Button { themeHex = item.1 } label: {
                                    Circle().fill(Color(gooHex: item.1))
                                        .overlay(Circle().strokeBorder(.white.opacity(0.32), lineWidth: 1))
                                        .overlay {
                                            if themeHex == item.1 {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 14, weight: .heavy))
                                                    .foregroundColor(.white)
                                                    .shadow(color: .black.opacity(0.7), radius: 2)
                                            }
                                        }
                                        .frame(width: 34, height: 34)
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(.white.opacity(themeHex == item.1 ? 0.94 : 0), lineWidth: 2))
                                        .frame(minHeight: 44)
                                }
                                .buttonStyle(GooGlassPress())
                                .accessibilityLabel(item.0)
                                .accessibilityAddTraits(themeHex == item.1 ? .isSelected : [])
                            }
                        }
                    }

                    settingsSection("License", icon: "key.fill") {
                        if let expiry = licenseManager.expirationDate {
                            Text("Có hiệu lực đến")
                                .font(.caption).foregroundColor(.white.opacity(0.70))
                            Text(expiry.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline.weight(.semibold))
                        }
                        Button { licenseManager.deactivate() } label: {
                            HStack {
                                Label("Đăng xuất License", systemImage: "rectangle.portrait.and.arrow.right")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.orange)
                            .padding(.vertical, 10)
                        }.buttonStyle(GooGlassPress())
                    }

                    settingsSection("Đồng bộ & hỗ trợ", icon: "arrow.triangle.2.circlepath") {
                        Button {
                            showSettings = false
                            Task { await sync() }
                        } label: {
                            Label(syncButtonLabel, systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(color.opacity(0.22), in: Capsule())
                                .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
                                .foregroundColor(.white)
                        }.buttonStyle(GooGlassPress())
                        if let link = URL(string: supportUrl), link.scheme == "https" {
                            Link(destination: link) {
                                HStack {
                                    Label("Hỗ trợ", systemImage: "questionmark.circle")
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.caption)
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(color)
                                .padding(.vertical, 8)
                            }
                        }
                    }

                    Text("GoHan iOS")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 22)
            }
            .background(GooGridBackground(tint: color))
            .navigationTitle(settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Xong") { showSettings = false }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(color)
            }}
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
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
            if majorOpen && !availableCategories.contains(where: { $0.id == game }) {
                majorOpen = false
                selectedSub = nil
            } else if let sub = selectedSub, !sub.isEmpty, !groups.contains(where: { $0.id == sub }) {
                selectedSub = nil
            }
            if !availableCategories.contains(where: { $0.id == game }),
               let first = availableCategories.first { game = first.id }
            GooCache.saveCatalog(catalog)
            GooCache.saveCategories(categories)
            iconRevision &+= 1
            message = "Đã đồng bộ \(incoming.count) gói / \(fetchedCategories.count) mục lớn từ Admin." +
                      (configWarning.map { " \($0)" } ?? "")
        } catch {
            message = "Lỗi đồng bộ: \(error.localizedDescription). Các gói đang bật vẫn được giữ để khôi phục."
        }
    }
    private func project(from plan: GooPlan, for patch: GooPatch) throws -> PatchProject {
        guard plan.format == "3105-project-v1", plan.game == patch.game,
              let uuid = UUID(uuidString: plan.packageId),
              (1...100).contains(plan.rules.count) else {
            throw GooError.message("Kế hoạch .3105 không hợp lệ")
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
            throw GooError.message("Ứng dụng đích trong gói .3105 không khớp dữ liệu Admin")
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
