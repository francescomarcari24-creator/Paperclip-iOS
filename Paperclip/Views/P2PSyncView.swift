import SwiftUI

struct P2PSyncView: View {
    @ObservedObject var syncManager = P2PSyncManager.shared
    @EnvironmentObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var manualHost: String = ""
    @State private var manualPort: String = "8765"
    @State private var showShareFolderSheet: TrustedDevices.TrustedDevice?

    var body: some View {
        NavigationStack {
            List {
                // Status card
                Section("Stato server locale") {
                    HStack(spacing: 12) {
                        Image(systemName: syncManager.isRunning ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right.slash")
                            .font(.title2)
                            .foregroundStyle(syncManager.isRunning ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(syncManager.deviceName)
                                .font(.headline)
                            Text(syncManager.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if syncManager.isSyncing {
                            ProgressView()
                        }
                    }

                    Toggle("Attiva server e ricerca Wi-Fi", isOn: Binding(
                        get: { syncManager.isRunning },
                        set: { on in
                            if on { syncManager.start() } else { syncManager.stop() }
                        }
                    ))

                    Toggle("Sincronizzazione automatica con dispositivi fidati", isOn: $syncManager.autoSyncEnabled)

                    if let summary = syncManager.lastSyncSummary {
                        Label(summary, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                // Discovered peers on LAN
                Section("Dispositivi rilevati sulla rete Wi-Fi (\(syncManager.discoveredPeers.count))") {
                    if syncManager.discoveredPeers.isEmpty {
                        Text("Nessun altro dispositivo Paperclip trovato sulla rete locale. Assicurati che entrambi i dispositivi siano sullo stesso Wi-Fi con la sincronizzazione aperta.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(syncManager.discoveredPeers) { peer in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "iphone.radiowaves.left.and.right")
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text("\(peer.host):\(peer.port)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                HStack(spacing: 10) {
                                    Button {
                                        syncManager.syncWithPeer(peer)
                                    } label: {
                                        Label("Sincronizza", systemImage: "arrow.triangle.2.circlepath")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(syncManager.isSyncing)

                                    Button {
                                        syncManager.initiatePairing(with: peer)
                                    } label: {
                                        Label("Associa", systemImage: "lock.shield")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(syncManager.isSyncing)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Trusted devices
                Section("Dispositivi fidati (\(syncManager.trustedDevices.count))") {
                    if syncManager.trustedDevices.isEmpty {
                        Text("Nessun dispositivo associato. Tocca 'Associa' su un dispositivo rilevato per abilitare la sincronizzazione automatica e le cartelle condivise.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(syncManager.trustedDevices) { dev in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dev.name)
                                            .font(.subheadline.weight(.semibold))
                                        if let host = dev.lastHost, let port = dev.lastPort {
                                            Text("\(host):\(port)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        TrustedDevices.remove(deviceId: dev.deviceId)
                                        syncManager.reloadStores()
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                    }
                                }

                                HStack(spacing: 10) {
                                    if let host = dev.lastHost, let port = dev.lastPort {
                                        Button {
                                            let peer = P2PPeer(id: dev.deviceId, name: dev.name, host: host, port: port, deviceId: dev.deviceId)
                                            syncManager.syncWithPeer(peer, trusted: dev)
                                        } label: {
                                            Label("Sincronizza", systemImage: "arrow.triangle.2.circlepath")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }

                                    Button {
                                        showShareFolderSheet = dev
                                    } label: {
                                        Label("Condividi cartella", systemImage: "folder.badge.person.crop")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Shared folders (Host & Guest)
                if !syncManager.hostShares.isEmpty || !syncManager.guestShares.isEmpty {
                    Section("Cartelle condivise") {
                        ForEach(syncManager.hostShares) { share in
                            HStack {
                                Image(systemName: "folder.fill.badge.person.crop")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(share.folderName)
                                        .font(.subheadline.weight(.semibold))
                                    Text("Condivisa da te (\(share.peerDeviceIds.count) dispositivi)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    SharedFolders.removeHostShare(shareId: share.shareId)
                                    syncManager.reloadStores()
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }

                        ForEach(syncManager.guestShares) { guest in
                            HStack {
                                Image(systemName: "folder.badge.gearshape")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(guest.folderName)
                                        .font(.subheadline.weight(.semibold))
                                    Text("Da \(guest.hostDeviceName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    syncManager.pullSharedFolder(guest)
                                } label: {
                                    Label("Aggiorna", systemImage: "arrow.down.circle")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent)

                                Button(role: .destructive) {
                                    SharedFolders.removeGuestShare(shareId: guest.shareId)
                                    syncManager.reloadStores()
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }

                // Manual IP connection
                Section("Connessione manuale (IP)") {
                    TextField("Indirizzo IP (es. 192.168.1.25)", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Porta (predefinita 8765)", text: $manualPort)
                        .keyboardType(.numberPad)

                    HStack(spacing: 12) {
                        Button {
                            let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
                            let port = Int(manualPort) ?? 8765
                            guard !host.isEmpty else { return }
                            let peer = P2PPeer(id: "\(host):\(port)", name: host, host: host, port: port, deviceId: nil)
                            syncManager.syncWithPeer(peer)
                        } label: {
                            Label("Sincronizza ora", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncManager.isSyncing)

                        Button {
                            let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
                            let port = Int(manualPort) ?? 8765
                            guard !host.isEmpty else { return }
                            let peer = P2PPeer(id: "\(host):\(port)", name: host, host: host, port: port, deviceId: nil)
                            syncManager.initiatePairing(with: peer)
                        } label: {
                            Label("Associa", systemImage: "lock.shield")
                        }
                        .buttonStyle(.bordered)
                        .disabled(manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncManager.isSyncing)
                    }
                }
            }
            .navigationTitle("Sincronizzazione P2P")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .onAppear {
                syncManager.reloadStores()
                if !syncManager.isRunning {
                    syncManager.start()
                }
            }
            .onChange(of: syncManager.lastSyncSummary) { _ in
                viewModel.reloadAll()
            }
            .alert(
                "Richiesta di associazione",
                isPresented: Binding(
                    get: { syncManager.pendingPairRequest != nil },
                    set: { if !$0 { syncManager.respondToPairing(accept: false) } }
                ),
                presenting: syncManager.pendingPairRequest
            ) { _ in
                Button("Rifiuta", role: .cancel) {
                    syncManager.respondToPairing(accept: false)
                }
                Button("Conferma associazione") {
                    syncManager.respondToPairing(accept: true)
                }
            } message: { req in
                Text("Il dispositivo \"\(req.deviceName)\" vuole associarsi.\n\nCodice di sicurezza: \(req.verificationCode)\n\nVerifica che lo stesso codice a 6 cifre sia visibile sull'altro dispositivo.")
            }
            .alert(
                "Codice di verifica: \(syncManager.outgoingPairCode ?? "")",
                isPresented: Binding(
                    get: { syncManager.outgoingPairCode != nil },
                    set: { if !$0 { syncManager.outgoingPairCode = nil } }
                )
            ) {
                Button("Annulla", role: .cancel) {
                    syncManager.outgoingPairCode = nil
                }
            } message: {
                Text("Conferma questo codice a 6 cifre su \"\(syncManager.outgoingPairPeerName ?? "")\" per completare l'associazione.")
            }
            .sheet(item: $showShareFolderSheet) { dev in
                ShareFolderPickerSheet(device: dev) { folder in
                    syncManager.inviteTrustedDeviceToFolder(folder: folder, device: dev)
                }
                .environmentObject(viewModel)
            }
        }
    }
}

private struct ShareFolderPickerSheet: View {
    let device: TrustedDevices.TrustedDevice
    var onSelect: (Folder) -> Void
    @EnvironmentObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if viewModel.folders.isEmpty {
                    Text("Nessuna cartella disponibile. Crea prima una cartella.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.folders) { folder in
                        Button {
                            onSelect(folder)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color(hexString: folder.colorHex))
                                Text(folder.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "paperplane")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Condividi con \(device.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
