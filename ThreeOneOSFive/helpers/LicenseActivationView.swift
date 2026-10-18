import SwiftUI

// Branding is intentionally public: users must be able to see the activation
// screen before they have a license. License validation stays server-side.
private struct ActivationScreenBranding: Codable {
    let activationBadge: String?
    let activationTitle: String?
    let activationSubtitle: String?
    let activationDescription: String?
    let activationPlaceholder: String?
    let activationRememberLabel: String?
    let activationButtonLabel: String?
    let activationRecoveryNote: String?
    let accentHex: String?
}

private extension Color {
    init(goohanHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let code = UInt64(hex, radix: 16) ?? 0xFF4757
        self.init(red: Double((code >> 16) & 0xFF) / 255,
                  green: Double((code >> 8) & 0xFF) / 255,
                  blue: Double(code & 0xFF) / 255)
    }
}

/// Uses the same 30-point grid and persisted 24-color selection as ContentView.
private struct ActivationGridBackground: View {
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

struct LicenseActivationView: View {
    @ObservedObject var manager: LicenseManager
    @AppStorage("GooHanThemeHex") private var themeHex = "#FF4757"
    @State private var branding: ActivationScreenBranding?
    @State private var key = ""
    @State private var showColors = false
    @FocusState private var typing: Bool

    private let brandingCacheKey = "GooHanActivationBranding.v1"
    private var tint: Color { Color(goohanHex: themeHex) }

    private func content(_ text: String?, fallback: String) -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return text
    }

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    activationCard
                    colorPicker
                    Text(content(branding?.activationRecoveryNote,
                                 fallback: "Khi Key hết hạn, bạn vẫn có thể khôi phục tệp gốc đã sao lưu."))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                    // Never require a license to restore files from a backup.
                    GooHanRecoveryPanel()
                }
                .padding(.horizontal, 17)
                .padding(.top, 28)
                .padding(.bottom, 30)
            }
            .background(ActivationGridBackground(tint: tint))
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .task { await loadBranding() }
        .onAppear {
            if let previous = manager.rememberedKey(), key.isEmpty { key = previous }
        }
    }

    private var header: some View {
        VStack(spacing: 13) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 28, weight: .black))
                .foregroundColor(tint)
                .frame(width: 72, height: 72)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 21))
                .overlay(RoundedRectangle(cornerRadius: 21).stroke(tint.opacity(0.35)))
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(content(branding?.activationBadge, fallback: "GOOHAN • LICENSE ACCESS"))
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(tint)
            }
            Text(content(branding?.activationTitle, fallback: "GOOHAN PATCH"))
                .font(.system(size: 30, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
            Text(content(branding?.activationSubtitle, fallback: "Kích hoạt License Key"))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text(content(branding?.activationDescription,
                         fallback: "Nhập Key do Admin cấp để xác thực và sử dụng GooHan Patch."))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.63))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation { showColors.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "paintpalette.fill").foregroundColor(tint)
                    Text("24 màu giao diện").font(.system(size: 13, weight: .bold))
                    Spacer()
                    Image(systemName: showColors ? "chevron.up" : "chevron.down")
                        .foregroundColor(tint)
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            if showColors {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 14) {
                    ForEach(0..<GooPalette.all.count, id: \.self) { index in
                        let item = GooPalette.all[index]
                        Button { themeHex = item.1 } label: {
                            Circle().fill(Color(goohanHex: item.1)).frame(width: 36, height: 36)
                                .overlay(Circle().stroke(.white, lineWidth: themeHex == item.1 ? 2.5 : 0))
                        }
                        .accessibilityLabel(item.0)
                    }
                }
                .padding(15)
                .background(Color(red: 0.093, green: 0.103, blue: 0.13),
                            in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "checkmark.shield.fill").foregroundColor(tint)
                Text("LICENSE KEY")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(1)
                Spacer()
                Image(systemName: "lock.shield").foregroundColor(tint)
            }
            TextField(content(branding?.activationPlaceholder,
                              fallback: "GOHANIOS-XXXXXX-XXXXXX-XXXXXX"), text: $key)
                .focused($typing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(15)
                .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.08)))
                .submitLabel(.done)
                .onSubmit {
                    typing = false
                    if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        manager.activate(key: key)
                    }
                }
            Toggle(content(branding?.activationRememberLabel,
                           fallback: "Ghi nhớ Key trên iPhone"), isOn: $manager.rememberKey)
                .tint(tint)
                .font(.subheadline)
            Button {
                typing = false
                manager.activate(key: key)
            } label: {
                HStack(spacing: 9) {
                    if manager.isBusy { ProgressView().tint(.white) }
                    else { Image(systemName: "checkmark.shield.fill") }
                    Text(content(branding?.activationButtonLabel,
                                 fallback: "XÁC THỰC VÀO ỨNG DỤNG"))
                        .lineLimit(2).multilineTextAlignment(.center)
                }
                .font(.system(size: 14, weight: .heavy))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(tint, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(manager.isBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(manager.isBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            if let message = manager.message {
                Text(message).font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(19)
        .background(Color(red: 0.093, green: 0.103, blue: 0.13).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(.white.opacity(0.085)))
    }

    @MainActor private func loadBranding() async {
        // Cached labels are shown immediately when the user is offline.
        if let cached = UserDefaults.standard.data(forKey: brandingCacheKey),
           let decoded = try? JSONDecoder().decode(ActivationScreenBranding.self, from: cached) {
            branding = decoded
        }
        do {
            var request = URLRequest(url: LicenseManager.serverURL.appendingPathComponent("api/config"))
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let remote = try decoder.decode(ActivationScreenBranding.self, from: data)
            branding = remote
            if let stored = try? JSONEncoder().encode(remote) {
                UserDefaults.standard.set(stored, forKey: brandingCacheKey)
            }
            // The user's explicit 24-color selection is never overridden.
            if UserDefaults.standard.object(forKey: "GooHanThemeHex") == nil,
               let hex = remote.accentHex,
               hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil {
                themeHex = hex
            }
        } catch {
            // A branding outage must not prevent Key activation.
        }
    }
}
