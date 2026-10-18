import SwiftUI
import Foundation
import CryptoKit

private struct GooPatch: Codable, Identifiable, Hashable {
    let id: String
    let game: String
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
    let rules: [Rule]
}
private enum GooError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
private enum GooPalette {
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
    @AppStorage("GooHanServerURL") private var serverURL = "https://gohanpatch-adminpatch.zcloudviet.xyz"
    @AppStorage("GooHanThemeHex") private var themeHex = "#FF4757"
    @State private var game = "free_fire"
    @State private var catalog: [GooPatch] = GooCache.loadCatalog()
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

    private var color: Color { Color(gooHex: themeHex) }
    private var visible: [GooPatch] {
        catalog.filter { $0.game == game && ($0.enabled || GooCache.hasReceipt(for: $0)) }
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
                            Text(message).font(.footnote).foregroundColor(.white.opacity(0.8))
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
        HStack(spacing: 10) {
            gameButton("free_fire", ffName)
            gameButton("free_fire_max", maxName)
        }
    }
    private func gameButton(_ key: String, _ name: String) -> some View {
        Button { game = key } label: {
            Text(name).font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
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
                Text(notice).font(.footnote).foregroundColor(.white.opacity(0.62))
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
                        Text(patch.description).font(.caption2)
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
                    .labelsHidden().tint(color).disabled(busyId != nil)
                    .accessibilityLabel(active ? restoreLabel : applyLabel)
                }
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
                    Text(serverLabel).font(.headline)
                    TextField("https://...", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).textFieldStyle(.roundedBorder)
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
                    if let link = URL(string: supportUrl), link.scheme == "https" {
                        Link("Hỗ trợ", destination: link)
                            .font(.subheadline).foregroundColor(color)
                    }
                    Text("Bản này chỉ có thể thao tác với dữ liệu khi iOS thực sự cấp quyền. Không có thao tác chọn thư mục; nếu không đủ quyền, công tắc sẽ giữ trạng thái OFF và hiển thị lỗi.")
                        .font(.footnote).foregroundColor(.secondary)
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
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GooError.message("Máy chủ không trả HTTP 200")
        }
        guard data.count <= 80 * 1024 * 1024 else { throw GooError.message("Dữ liệu quá lớn") }
        return data
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
            var incoming: [GooPatch] = []
            for key in ["free_fire", "free_fire_max"] {
                var components = URLComponents(url: base.appendingPathComponent("api/patches"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "game", value: key)]
                guard let url = components.url else { continue }
                let response = try jsonDecoder().decode(GooResponse.self, from: await getData(url))
                incoming += response.patches.filter { $0.game == key }
            }
            let old = GooCache.loadCatalog()
            let activeMissing = old.filter { oldPatch in
                !incoming.contains(where: { $0.id == oldPatch.id }) && GooCache.hasReceipt(for: oldPatch)
            }
            catalog = incoming + activeMissing
            GooCache.saveCatalog(catalog)
            message = "Đã đồng bộ \(incoming.count) gói từ Admin." +
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
        let bundleID: String = patch.game == "free_fire" ? "com.dts.freefireth" : "com.dts.freefiremax"
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
    private func toggle(_ patch: GooPatch, on: Bool) async {
        guard busyId == nil else { return }
        busyId = patch.id
        defer { busyId = nil; redrawReceipt += 1 }
        do {
            if on {
                guard !GooCache.hasReceipt(for: patch) else { return }
                guard patch.enabled, patch.packageFormat == "3105" else {
                    throw GooError.message("Chỉ hỗ trợ gói .3105 đang được Admin xuất bản")
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
                message = "Đã áp dụng \(patch.feature) và lưu biên nhận khôi phục."
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
                message = "Đã khôi phục bản gốc cho \(patch.feature)."
            }
        } catch {
            message = "Không thể \(on ? "bật" : "tắt") \(patch.feature): \(error.localizedDescription)"
        }
    }
}
