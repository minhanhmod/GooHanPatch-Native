import SwiftUI

struct LicenseActivationView: View {
    @ObservedObject var manager: LicenseManager
    @State private var key = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedHyperBackdrop()
                    .ignoresSafeArea()

                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 42)

                            Text("OGIOS")
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(.white)

                            Text("Version: 1.1.0")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.top, 5)

                            Text("Package: OGIOS")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.secondaryAccent.opacity(0.9))
                                .padding(.top, 8)

                            VStack(spacing: 16) {
                                HStack(spacing: 10) {
                                    Image(systemName: manager.isBusy ? "arrow.triangle.2.circlepath" : "key.fill")
                                        .foregroundStyle(AppTheme.secondaryAccent)
                                        .font(.system(size: 16, weight: .bold))
                                    Text(manager.isBusy ? "Package initializing" : "Key required")
                                        .font(.system(size: 16, weight: .black, design: .rounded))
                                        .foregroundStyle(.white)
                                    Spacer()
                                }

                                Text("Enter your OGIOS license key to continue")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.68))
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                TextField("License key", text: $key)
                                    .focused($keyFocused)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.done)
                                    .onSubmit { activate() }
                                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .frame(height: 54)
                                    .background(Color.gray.opacity(0.22), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(AppTheme.accent.opacity(0.48), lineWidth: 1))
                                    .id("license-field")

                                Toggle("Remember key on this device", isOn: $manager.rememberKey)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .tint(AppTheme.accent)

                                Button(action: activate) {
                                    HStack(spacing: 9) {
                                        Image(systemName: manager.isBusy ? "hourglass" : "checkmark.shield.fill")
                                        Text(manager.isBusy ? "VERIFYING…" : "VERIFY AND CONTINUE")
                                    }
                                    .font(.system(size: 14, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                    .shadow(color: AppTheme.accent.opacity(0.30), radius: 14, y: 7)
                                }
                                .buttonStyle(.plain)
                                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isBusy)
                                .opacity(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)

                                if let message = manager.message {
                                    Text(message)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.red.opacity(0.95))
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.gray.opacity(0.20), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }

                                if let contactOwner = manager.contactOwner,
                                   let contactURL = ownerURL(from: contactOwner) {
                                    Button("Contact Owner…") {
                                        UIApplication.shared.open(contactURL)
                                    }
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(AppTheme.secondaryAccent)
                                    .buttonStyle(.plain)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                            }
                            .padding(20)
                            .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                            .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
                            .padding(.horizontal, 22)
                            .padding(.top, 26)
                            .id("activation-card")

                            Spacer(minLength: 42)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 28)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: keyFocused) { focused in
                        guard focused else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("activation-card", anchor: .center) }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func activate() {
        keyFocused = false
        manager.activate(key: key)
    }

    private func ownerURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("@") {
            return URL(string: "https://t.me/" + String(trimmed.dropFirst()))
        }
        return URL(string: "https://t.me/" + trimmed)
    }
}
