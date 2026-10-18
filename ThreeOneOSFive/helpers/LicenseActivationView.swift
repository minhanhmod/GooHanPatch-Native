import SwiftUI

struct LicenseActivationView: View {
    @ObservedObject var manager: LicenseManager
    @State private var key = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 55)
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 48, weight: .black))
                        .foregroundColor(Color(red: 0.35, green: 0.65, blue: 1))
                        .padding(25)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 28))
                    Text("GOOHAN PATCH")
                        .font(.system(size: 31, weight: .black, design: .rounded))
                    Text("Kích hoạt License Key")
                        .font(.title3.bold())
                    Text("Nhập key do Admin cung cấp. Máy chủ sẽ xác minh key, thời hạn và thiết bị trước khi mở ứng dụng.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                    VStack(spacing: 16) {
                        TextField("GOOHAN-XXXXXX-XXXXXX-XXXXXX-XXXXXX", text: $key)
                            .focused($typing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .textContentType(.password)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .padding(15)
                            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                        Toggle("Ghi nhớ key trên iPhone", isOn: $manager.rememberKey)
                            .tint(.blue)
                            .font(.subheadline)
                        Button {
                            typing = false
                            manager.activate(key: key)
                        } label: {
                            HStack(spacing: 9) {
                                if manager.isBusy { ProgressView().tint(.white) }
                                Image(systemName: "checkmark.shield.fill")
                                Text("XÁC THỰC VÀO ỨNG DỤNG")
                            }
                            .font(.system(size: 14, weight: .heavy))
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(manager.isBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let message = manager.message {
                            Text(message)
                                .font(.footnote)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                        }
                        if manager.isBusy { ProgressView("Đang liên hệ máy chủ…") }
                    }
                    .padding(20)
                    .background(Color(red: 0.09, green: 0.11, blue: 0.16), in: RoundedRectangle(cornerRadius: 22))

                    // Safety route: a license can expire while a Patch is active.
                    // Users must still be able to restore local backups, without a key.
                    GooHanRecoveryPanel()
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
            }
            .background(Color(red: 0.035, green: 0.047, blue: 0.075).ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }
}
