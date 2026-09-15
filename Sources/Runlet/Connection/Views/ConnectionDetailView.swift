import Foundation
import SwiftUI

// MARK: - Save Feedback

/// Outcome of the most recent Save action, shown next to the Save button.
/// `token` increments on every attempt so a repeated outcome still restarts
/// the auto-dismiss task keyed on this value.
private struct SaveFeedback: Equatable {
    enum Kind {
        case saved
        case failed
    }

    let kind: Kind
    let token: Int
}

// MARK: - Connection Detail View

struct ConnectionDetailView: View {
    @Environment(TabState.self) private var tab
    @Environment(ConnectionStore.self) private var store

    @State private var name = ""
    @State private var connectionMode: RedisConnectionMode = .standalone
    @State private var host = ""
    @State private var port: UInt16 = 6379
    @State private var username = ""
    @State private var password = ""
    @State private var testResult: String?
    @State private var isTesting = false

    @State private var ssh = SSHConfig()
    @State private var tls = TLSConfig()
    @State private var environment: ConnectionEnvironment = .unspecified
    @State private var uriInput = ""
    @State private var uriError: String?
    @State private var portText = "6379"
    @State private var sshPortText = "22"
    @State private var portError: String?
    @State private var sshPortError: String?
    @State private var isNew = false
    @State private var editingConfig: RedisConnectionConfig?

    /// Outcome of the most recent Save action. Success auto-dismisses after
    /// a short delay; failure stays until the next save or a different
    /// connection is loaded.
    @State private var saveFeedback: SaveFeedback?
    /// The connection whose successful save switched the panel to it. Keeps
    /// that save's feedback visible across the panel switch instead of
    /// clearing it as stale state.
    @State private var lastSavedConfigID: RedisConnectionConfig.ID?

    /// In-flight connection test. Cancelled by Cancel Test or by loading a
    /// different connection; a superseded probe (generation mismatch)
    /// discards its outcome instead of writing it into the form.
    @State private var probeTask: Task<Void, Never>?
    @State private var probeGeneration = 0

    /// The form submits only with a host, valid ports, and no test in flight.
    private var canSubmit: Bool {
        !host.isEmpty && portError == nil && (!ssh.enabled || sshPortError == nil)
    }

    /// Why the footer actions are disabled, for tooltips. Nil means submittable.
    private var submitDisabledReason: String? {
        if isTesting {
            return "Testing connection…"
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a host to enable"
        }
        if portError != nil {
            return "Fix the Redis port to enable"
        }
        if ssh.enabled {
            if ssh.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter the SSH host to enable"
            }
            if sshPortError != nil {
                return "Fix the SSH port to enable"
            }
        }
        return nil
    }
    @State private var connectionTimeout: TimeInterval = 10
    @State private var pingTimeout: TimeInterval = 5

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    Section("Import from URI") {
                        HStack {
                            TextField("URI", text: $uriInput)
                                .onChange(of: uriInput) { uriError = nil }
                            Button("Import") {
                                if let config = RedisConnectionConfig.parseURI(uriInput) {
                                    name = config.name
                                    connectionMode = config.mode
                                    host = config.host
                                    port = config.port
                                    username = config.username
                                    password = config.password
                                    tls = config.tls
                                    uriInput = ""
                                    uriError = nil
                                } else {
                                    uriError = "Invalid URI format. Expected: redis://[user:pass@]host:port"
                                }
                            }
                            .disabled(uriInput.isEmpty)
                        }
                        if let uriError {
                            Text(uriError)
                                .font(.subheadline)
                                .foregroundStyle(AppColor.error)
                        }
                    }

                    Section(isNew ? "New Connection" : "Connection") {
                        TextField("Name (optional, defaults to host)", text: $name)
                        HStack {
                            Text("Mode")
                            Spacer()
                            OptionsPicker(
                                "Connection mode",
                                selection: $connectionMode,
                                options: RedisConnectionMode.allCases,
                                label: \.title
                            )
                        }
                        TextField("Host", text: $host)
                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("", text: $portText)
                                .accessibilityLabel("Redis port")
                                .frame(width: AppSize.formFieldWidth)
                                .onChange(of: portText) { _, newValue in
                                    portError = nil
                                    if let parsed = UInt16(newValue), parsed > 0 {
                                        port = parsed
                                    } else {
                                        portError = "Invalid port (1–65535)"
                                    }
                                }
                        }
                        if let portError {
                            Text(portError)
                                .font(.subheadline)
                                .foregroundStyle(AppColor.error)
                        }
                        TextField("Username", text: $username)
                        SecureField("Password", text: $password)
                    }

                    Section("TLS/SSL") {
                        Toggle("Enable TLS", isOn: $tls.enabled)
                        if tls.enabled {
                            Toggle("Verify Server Certificate", isOn: $tls.verifyServerCertificate)
                            TextField("CA Certificate Path (optional)", text: $tls.caCertificatePath)
                            TextField("Client Certificate Path (optional)", text: $tls.clientCertificatePath)
                            TextField("Client Key Path (optional)", text: $tls.clientKeyPath)
                            Text("For mTLS, provide both client certificate and key")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("SSH Tunnel") {
                        Toggle("Enable SSH Tunnel", isOn: $ssh.enabled)
                        if ssh.enabled {
                            HStack {
                                Text("Mode")
                                Spacer()
                                OptionsPicker(
                                    "SSH mode",
                                    selection: $ssh.mode,
                                    options: SSHTunnelMode.allCases,
                                    label: \.title
                                )
                            }
                            TextField("Host", text: $ssh.host)
                            HStack {
                                Text("Port")
                                Spacer()
                                TextField("", text: $sshPortText)
                                    .accessibilityLabel("SSH port")
                                    .frame(width: AppSize.formFieldWidth)
                                    .onChange(of: sshPortText) { _, newValue in
                                        sshPortError = nil
                                        if let parsed = UInt16(newValue), parsed > 0 {
                                            ssh.port = parsed
                                        } else {
                                            sshPortError = "Invalid port (1–65535)"
                                        }
                                    }
                            }
                            if ssh.enabled, let sshPortError {
                                Text(sshPortError)
                                    .font(.subheadline)
                                    .foregroundStyle(AppColor.error)
                            }
                            TextField("User (optional)", text: $ssh.user)
                            if ssh.mode == .builtIn {
                                SecureField("Password (optional)", text: $ssh.password)
                                TextField("Private Key Path (optional)", text: $ssh.privateKeyPath)
                                Text("Provide a password or a private key file path")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Label(
                                    "Built-in mode does not verify the server's host key. "
                                        + "Use System SSH for known_hosts verification.",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.subheadline)
                                .foregroundStyle(AppColor.warning)
                            } else {
                                TextField("Private Key Path (optional)", text: $ssh.privateKeyPath)
                                Text(
                                    "Uses /usr/bin/ssh with ~/.ssh/config, keys and ssh-agent "
                                        + "(ProxyJump supported). Tunnels to the same host share one connection. "
                                        + "Password is ignored — use ssh-agent for passphrases."
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Environment") {
                        HStack {
                            Text("Environment")
                            Spacer()
                            OptionsPicker(
                                "Environment",
                                selection: $environment,
                                options: ConnectionEnvironment.allCases,
                                label: \.rawValue
                            )
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .onChange(of: tab.connectionPanel) { _, newValue in
                loadConfig(from: newValue)
            }
            .onAppear {
                loadConfig(from: tab.connectionPanel)
            }

            Divider()

            HStack {
                if isNew {
                    Button("Save") {
                        let config = createConfig()
                        if store.addConnection(config) {
                            presentSaveFeedback(.saved, configID: config.id)
                            tab.selectedConnection = config
                            tab.connectionPanel = .editConnection(config)
                        } else {
                            presentSaveFeedback(.failed, configID: nil)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canSubmit || isTesting)
                    .help(submitDisabledReason ?? "Save connection")

                    saveFeedbackView

                    testConnectionButton

                    testResultView
                } else if let config = editingConfig {
                    Button("Save") {
                        var updated = config
                        updated.name = name
                        updated.mode = connectionMode
                        updated.host = host
                        updated.port = port
                        updated.seedNodes = []
                        updated.username = username
                        updated.password = password
                        updated.ssh = ssh
                        updated.tls = tls
                        updated.environment = environment
                        if store.updateConnection(updated) {
                            presentSaveFeedback(.saved, configID: updated.id)
                            tab.selectedConnection = updated
                        } else {
                            presentSaveFeedback(.failed, configID: nil)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canSubmit || isTesting)
                    .help(submitDisabledReason ?? "Save connection")

                    saveFeedbackView

                    testConnectionButton

                    testResultView
                }

                Spacer()

                Button("Connect") {
                    // Connecting is intentionally transient: it neither saves a
                    // new connection nor persists edits to an existing one.
                    // Only the Save button writes to the store.
                    var config = createConfig()
                    if let existing = editingConfig {
                        config.id = existing.id
                    }
                    Task { await tab.connect(to: config) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSubmit || isTesting || (ssh.enabled && ssh.host.isEmpty))
                .help(submitDisabledReason ?? "Connect")
            }
            .padding(AppSpacing.large)
        }
    }

    private func createConfig() -> RedisConnectionConfig {
        var config = RedisConnectionConfig(
            name: name.isEmpty ? host : name,
            mode: connectionMode,
            host: host,
            port: port,
            seedNodes: [],
            username: username
        )
        config.password = password
        config.ssh = ssh
        config.tls = tls
        config.environment = environment
        config.connectionTimeout = connectionTimeout
        config.pingTimeout = pingTimeout
        return config
    }

    private func loadConfig(from panel: ConnectionPanel) {
        // A probe launched for the previous form is now stale: cancel it and
        // supersede its outcome so it can neither keep the footer locked nor
        // write its result into this form.
        probeTask?.cancel()
        probeGeneration += 1
        probeTask = nil
        isTesting = false
        testResult = nil
        switch panel {
        case .editConnection(let config):
            // Keep the feedback of a save that just switched this panel to
            // the saved connection; arriving at any other connection clears
            // stale feedback.
            if lastSavedConfigID != config.id {
                saveFeedback = nil
            }
            isNew = false
            editingConfig = config
            portText = "\(config.port)"
            sshPortText = "\(config.ssh.port)"
            portError = nil
            sshPortError = nil
            name = config.name
            connectionMode = config.mode
            host = config.host
            port = config.port
            username = config.username
            password = config.password
            ssh = config.ssh
            tls = config.tls
            environment = config.environment
            connectionTimeout = config.connectionTimeout
            pingTimeout = config.pingTimeout
        case .newConnection:
            saveFeedback = nil
            lastSavedConfigID = nil
            isNew = true
            editingConfig = nil
            name = ""
            connectionMode = .standalone
            host = "127.0.0.1"
            port = 6379
            portText = "6379"
            sshPortText = "22"
            portError = nil
            sshPortError = nil
            username = ""
            password = ""
            ssh = SSHConfig()
            tls = TLSConfig()
            environment = .unspecified
        default: break
        }
    }

    /// Records the outcome of a Save action. `configID` is the connection
    /// saved on success; it lets `loadConfig` keep this feedback visible
    /// across the panel switch that follows.
    private func presentSaveFeedback(_ kind: SaveFeedback.Kind, configID: RedisConnectionConfig.ID?) {
        lastSavedConfigID = configID
        saveFeedback = SaveFeedback(kind: kind, token: (saveFeedback?.token ?? 0) + 1)
    }

    @ViewBuilder
    private var saveFeedbackView: some View {
        if let saveFeedback {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: saveFeedback.kind == .saved ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(saveFeedback.kind == .saved ? AppColor.success : AppColor.error)
                Text(saveFeedback.kind == .saved ? "Saved" : "Save failed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .task(id: saveFeedback) {
                guard saveFeedback.kind == .saved else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.saveFeedback = nil
            }
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        if isTesting {
            HStack(spacing: AppSpacing.xSmall) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let result = testResult {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: result.hasPrefix("OK") ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.hasPrefix("OK") ? AppColor.success : AppColor.error)
                Text(result)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Test Connection swaps to Cancel while a probe runs, so a hung test
    /// (e.g. a wrong address mid-TCP-connect) never locks the form without
    /// an escape hatch.
    @ViewBuilder
    private var testConnectionButton: some View {
        if isTesting {
            Button("Cancel Test") {
                cancelConnectionProbe()
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Cancel the running connection test")
        } else {
            Button("Test Connection") {
                startConnectionProbe()
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!canSubmit || (ssh.enabled && ssh.host.isEmpty))
            .help(submitDisabledReason ?? "Test connection")
        }
    }

    /// Runs the connection probe for the form as it was when the button was
    /// pressed. The generation token makes the finished task a no-op if the
    /// form has since moved on (panel switch or supersede).
    private func startConnectionProbe() {
        guard probeTask == nil else { return }
        let config = createConfig()
        isTesting = true
        testResult = nil
        probeGeneration += 1
        let generation = probeGeneration

        probeTask = Task {
            let outcome = await ConnectionProbe(config: config).run()
            guard generation == probeGeneration else { return }
            probeTask = nil
            isTesting = false
            switch outcome {
            case .success(let latencyMs, let reply):
                let elapsed = String(format: "%.2f", latencyMs)
                if let reply, reply != "PONG" {
                    testResult = "OK — \(reply) (\(elapsed) ms)"
                } else {
                    testResult = "OK (\(elapsed) ms)"
                }
            case .failure(let message):
                testResult = "Failed — \(message)"
            case .cancelled:
                break
            }
        }
    }

    private func cancelConnectionProbe() {
        probeTask?.cancel()
    }
}
