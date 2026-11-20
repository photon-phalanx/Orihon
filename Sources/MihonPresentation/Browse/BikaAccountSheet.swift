import SwiftUI
import MihonData

struct BikaAccountSheet: View {
    let onClose: () -> Void
    @State private var account = ""
    @State private var password = ""
    @State private var profile: BikaProfile?
    @State private var loggedIn = false
    @State private var busy = false
    @State private var error: String?
    @State private var connected = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("哔咔账号").font(MihonType.titleLarge)
                Spacer()
                Button("完成", action: onClose).buttonStyle(MihonButtonStyle(.text))
            }.padding(16)
            MihonDivider()
            Form {
                if loggedIn {
                    Section("已登录") {
                        if let profile {
                            Text(profile.name)
                            Text("等级 \(profile.level)").foregroundStyle(.secondary)
                        }
                        if connected { Label("已连接正式线路", systemImage: "checkmark.circle") }
                        Button("刷新账号状态") { run { await refreshProfile() } }.disabled(busy)
                        Button("退出登录", role: .destructive) {
                            run {
                                await BikaAPI.shared.logout()
                                loggedIn = false
                                profile = nil
                                connected = false
                            }
                        }.disabled(busy)
                    }
                } else {
                    Section("登录哔咔") {
                        TextField("账号或邮箱", text: $account)
                            .textContentType(.username)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                            .accessibilityIdentifier("bika.account.username")
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("bika.account.password")
                        Button("登录") {
                            run {
                                do {
                                    try await BikaAPI.shared.login(account: account, password: password)
                                    password = ""
                                    loggedIn = true
                                    await refreshProfile()
                                } catch {
                                    guard !Task.isCancelled else { return }
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                        .disabled(busy || account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                        .accessibilityIdentifier("bika.account.login")
                    }
                }
                if busy { ProgressView("正在连接哔咔") }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("bika.account.error") }
            }
            .formStyle(.grouped)
        }
        .background(.background)
        .task {
            loggedIn = await BikaAPI.shared.isLoggedIn
            if loggedIn {
                busy = true
                await refreshProfile()
                busy = false
            }
        }
        .onDisappear { operation?.cancel(); password = "" }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        operation?.cancel()
        busy = true
        error = nil
        operation = Task { @MainActor in
            await action()
            busy = false
        }
    }

    @MainActor private func refreshProfile() async {
        do {
            async let user = BikaAPI.shared.profile()
            async let sources = BikaAPI.shared.sources()
            let (loaded, routes) = try await (user, sources)
            try Task.checkCancellation()
            profile = loaded
            connected = URL(string: routes.prodUrl) == BikaAPI.baseURL
        } catch {
            guard !Task.isCancelled else { return }
            loggedIn = await BikaAPI.shared.isLoggedIn
            self.error = error.localizedDescription
        }
    }
}
