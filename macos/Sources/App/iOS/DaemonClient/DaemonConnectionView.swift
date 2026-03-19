// DaemonConnectionView — iOS UI for connecting to a ghostty-daemon,
// picking a session, and interacting with the remote terminal.

import SwiftUI
import Network

struct DaemonConnectionView: View {
    @StateObject private var client = GSPClient()
    @StateObject private var browser = BonjourBrowser()
    @State private var host = ""
    @State private var port = "7337"
    @State private var authKey = ""
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            if client.attachedSessionId != nil {
                // Terminal view
                VStack(spacing: 0) {
                    RemoteTerminalView(screen: client.screen) { cols, rows in
                        client.sendResize(cols: cols, rows: rows)
                    }
                    .ignoresSafeArea(.keyboard)

                    // Input bar
                    HStack {
                        TextField("Input", text: $inputText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($inputFocused)
                            .onSubmit {
                                client.sendInput(inputText + "\r")
                                inputText = ""
                            }

                        Button("Send") {
                            client.sendInput(inputText + "\r")
                            inputText = ""
                        }

                        Button("Detach") {
                            client.detach()
                        }
                        .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                }
                .onAppear { inputFocused = true }
                .navigationBarHidden(true)

            } else if client.connected && client.authenticated {
                // Session picker
                sessionPickerView

            } else {
                // Connection form
                connectionFormView
            }
        }
    }

    private var connectionFormView: some View {
        Form {
            if !browser.daemons.isEmpty {
                Section("Discovered on Network") {
                    ForEach(browser.daemons) { daemon in
                        Button {
                            connectToEndpoint(daemon.endpoint)
                        } label: {
                            HStack {
                                Image(systemName: "terminal")
                                VStack(alignment: .leading) {
                                    Text(daemon.name)
                                        .font(.headline)
                                    Text("Tap to connect")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if browser.isSearching {
                Section("Discovered on Network") {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Searching...")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Manual Connection") {
                TextField("Host (e.g. 100.64.0.1)", text: $host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("Port", text: $port)
                    .keyboardType(.numberPad)

                SecureField("Auth Key (optional)", text: $authKey)
            }

            if let error = client.lastError {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            Section {
                Button("Connect") {
                    guard let p = UInt16(port), !host.isEmpty else { return }
                    client.connect(host: host, port: p, authKey: authKey)
                }
                .disabled(host.isEmpty)
            }
        }
        .navigationTitle("Ghostty Remote")
        .onAppear { browser.startBrowsing() }
        .onDisappear { browser.stopBrowsing() }
    }

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        // NWBrowser returns .service endpoints — resolve to host:port via NWConnection
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak client] state in
            if case .ready = state {
                // Extract resolved host/port
                if let path = conn.currentPath,
                   let remoteEndpoint = path.remoteEndpoint,
                   case .hostPort(let h, let p) = remoteEndpoint {
                    conn.cancel()
                    Task { @MainActor in
                        // Connect via GSPClient with resolved address
                        client?.connect(host: "\(h)", port: p.rawValue, authKey: "")
                    }
                }
            }
        }
        conn.start(queue: DispatchQueue(label: "resolve"))
    }

    private var sessionPickerView: some View {
        List {
            Section("Sessions") {
                ForEach(client.sessions) { session in
                    Button {
                        client.attach(sessionId: session.id)
                    } label: {
                        HStack {
                            Image(systemName: "terminal")
                                .foregroundColor(.primary)
                            VStack(alignment: .leading) {
                                let label = !session.name.isEmpty ? session.name
                                    : !session.title.isEmpty ? session.title
                                    : "Session \(session.id)"
                                Text(label)
                                    .font(.headline)
                                if !session.pwd.isEmpty {
                                    Text(session.pwd)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if session.attached {
                                Image(systemName: "link")
                                    .foregroundColor(.green)
                            }
                            if session.childExited {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }

            Section {
                Button("New Session") {
                    client.createSession()
                }

                Button("Refresh") {
                    client.listSessions()
                }
            }

            Section {
                Button("Disconnect") {
                    client.disconnect()
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("Sessions")
        .onAppear {
            client.listSessions()
        }
    }
}

#Preview {
    DaemonConnectionView()
}
