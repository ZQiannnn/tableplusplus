import SwiftUI

struct ConnectionFormView: View {
    let initial: ConnectionProfile?
    var onSave: (ConnectionProfile) -> Void
    var onCancel: () -> Void
    var onConnect: (ConnectionProfile, String) -> Void

    @State private var profile: ConnectionProfile
    @State private var password: String = ""
    @State private var sshPassword: String = ""
    @State private var sslMode: String = "PREFERRED"
    @State private var tab: FormTab = .connection
    @State private var testing: Bool = false
    @State private var connecting: Bool = false
    @State private var resultMessage: String?
    @State private var resultIsError: Bool = false

    enum FormTab: String, Hashable { case connection, ssh, advanced }

    init(initial: ConnectionProfile?,
         onSave: @escaping (ConnectionProfile) -> Void,
         onCancel: @escaping () -> Void,
         onConnect: @escaping (ConnectionProfile, String) -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        self.onConnect = onConnect
        _profile = State(initialValue: initial ?? ConnectionProfile.new())
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("", selection: $tab) {
                Label(L10n.t("form.tab.connection"), systemImage: "link").tag(FormTab.connection)
                Label(L10n.t("form.tab.ssh"), systemImage: "lock.shield").tag(FormTab.ssh)
                Label(L10n.t("form.tab.advanced"), systemImage: "slider.horizontal.3").tag(FormTab.advanced)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Group {
                switch tab {
                case .connection: basicTab
                case .ssh: sshTab
                case .advanced: advancedTab
                }
            }
            .padding(.horizontal, 16)

            if let msg = resultMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: resultIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(resultIsError ? .red : .green)
                        .font(.system(size: 12))
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(resultIsError ? .red : .green)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            Divider().padding(.top, 12)

            footer
        }
        .frame(width: 380)
        .background(Color(.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.95, green: 0.57, blue: 0.07),
                                 Color(red: 0.0, green: 0.46, blue: 0.56)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "cylinder.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 0) {
                Text(initial == nil ? L10n.t("form.newMysql") : L10n.t("form.editMysql"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.t("form.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var basicTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(L10n.t("form.section.identity")) {
                field(L10n.t("form.name")) {
                    TextField("", text: $profile.name).textFieldStyle(.roundedBorder)
                }
            }

            section(L10n.t("form.section.server")) {
                HStack(spacing: 8) {
                    field(L10n.t("form.host")) {
                        TextField("127.0.0.1", text: $profile.host).textFieldStyle(.roundedBorder)
                    }
                    field(L10n.t("form.port")) {
                        TextField("3306", value: $profile.port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder)
                    }
                    .frame(width: 84)
                }
                field(L10n.t("form.database")) {
                    TextField(L10n.t("form.optional"), text: Binding(
                        get: { profile.database ?? "" },
                        set: { profile.database = $0.isEmpty ? nil : $0 }
                    )).textFieldStyle(.roundedBorder)
                }
            }

            section(L10n.t("form.section.auth")) {
                field(L10n.t("form.user")) {
                    TextField("root", text: $profile.user).textFieldStyle(.roundedBorder)
                }
                field(L10n.t("form.password")) {
                    SecureField(initial == nil ? "" : L10n.t("form.unchanged"), text: $password).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var sshTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("form.useSsh"))
                    .font(.system(size: 13))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { profile.ssh != nil },
                    set: { enabled in
                        profile.ssh = enabled
                            ? (profile.ssh ?? SSHConfig(host: "", port: 22, user: "", auth: .password))
                            : nil
                    }
                ))
                .toggleStyle(.switch).labelsHidden().scaleEffect(0.75).frame(width: 30, height: 13)
            }

            if profile.ssh != nil {
                section(L10n.t("form.section.sshServer")) {
                    HStack(spacing: 8) {
                        field(L10n.t("form.host")) {
                            TextField("ssh.example.com", text: Binding(
                                get: { profile.ssh?.host ?? "" },
                                set: { profile.ssh?.host = $0 }
                            )).textFieldStyle(.roundedBorder)
                        }
                        field(L10n.t("form.port")) {
                            TextField("22", value: Binding(
                                get: { profile.ssh?.port ?? 22 },
                                set: { profile.ssh?.port = $0 }
                            ), format: .number.grouping(.never)).textFieldStyle(.roundedBorder)
                        }
                        .frame(width: 84)
                    }
                    field(L10n.t("form.user")) {
                        TextField("ec2-user", text: Binding(
                            get: { profile.ssh?.user ?? "" },
                            set: { profile.ssh?.user = $0 }
                        )).textFieldStyle(.roundedBorder)
                    }
                    field(L10n.t("form.password")) {
                        SecureField("", text: $sshPassword).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(L10n.t("form.section.encryption")) {
                field(L10n.t("form.sslMode")) {
                    Picker("", selection: $sslMode) {
                        ForEach(["PREFERRED", "REQUIRED", "DISABLED", "VERIFY_CA", "VERIFY_IDENTITY"], id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                }

                HStack {
                    Text(L10n.t("form.useSSL"))
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $profile.useSSL)
                        .toggleStyle(.switch).labelsHidden().scaleEffect(0.75).frame(width: 30, height: 13)
                }
            }

            section(L10n.t("form.section.other")) {
                HStack {
                    Text(L10n.t("form.favorite"))
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $profile.favorite)
                        .toggleStyle(.switch).labelsHidden().scaleEffect(0.75).frame(width: 30, height: 13)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.t("form.cancel"), action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 8) {
                Button(testing ? L10n.t("form.testing") : L10n.t("form.test")) {
                    runTest()
                }
                .disabled(testing || connecting)
                Button(L10n.t("form.save")) {
                    if !password.isEmpty {
                        KeychainService.savePassword(password, for: profile.id)
                    }
                    onSave(profile)
                }
                    .disabled(connecting)
                Button(connecting ? L10n.t("form.connecting") : L10n.t("form.connect")) {
                    runConnect()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(connecting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func effectivePassword() -> String {
        if !password.isEmpty { return password }
        return KeychainService.readPassword(for: profile.id) ?? ""
    }

    private func runTest() {
        testing = true
        resultMessage = nil
        let snapshot = profile
        let pwd = effectivePassword()
        Task {
            do {
                let d = try await DriverRegistry.open(profile: snapshot, password: pwd); try? await d.close()
                await MainActor.run {
                    resultIsError = false
                    resultMessage = L10n.t("form.connectSuccess")
                    testing = false
                }
            } catch {
                await MainActor.run {
                    resultIsError = true
                    resultMessage = error.localizedDescription
                    testing = false
                }
            }
        }
    }

    private func runConnect() {
        connecting = true
        resultMessage = nil
        let snapshot = profile
        let pwd = effectivePassword()
        Task {
            do {
                let d = try await DriverRegistry.open(profile: snapshot, password: pwd); try? await d.close()
                await MainActor.run {
                    if !password.isEmpty {
                        KeychainService.savePassword(password, for: snapshot.id)
                    }
                    connecting = false
                    onConnect(snapshot, pwd)
                }
            } catch {
                await MainActor.run {
                    resultIsError = true
                    resultMessage = error.localizedDescription
                    connecting = false
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            content()
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
