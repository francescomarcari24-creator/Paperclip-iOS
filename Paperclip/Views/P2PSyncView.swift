import SwiftUI

struct P2PSyncView: View {
    @ObservedObject var syncManager = P2PSyncManager.shared
    @ObservedObject var trustedDevices = TrustedDevices.shared
    @ObservedObject var sharedFolders = SharedFolders.shared
    @EnvironmentObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var manualHost: String = ""
    @State private var manualPort: String = "8765"
    @State private var peerForFolderShare: PeerDevice?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if !syncManager.incomingInvites.isEmpty {
                    invitesSection
                }
                peersSection
                trustedSection
                if !sharedFolders.shares.isEmpty {
                    sharedFoldersSection
                }
                manualSection
            }
            .navigationTitle("Sincronizzazione P2P")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .onAppear {
                syncManager.onArchiveUpdated = {
                    viewModel.reloadAll()
                }
                if !syncManager.isServerRunning {
                    syncManager.startP2P()
                }
            }
            .alert(
                "Associazione dispositivo",
                isPresented: Binding(
                    get: { syncManager.pendingPairing != nil },
                    set: { if !$0 { syncManager.cancelPairing() } }
                ),
                presenting: syncManager.pendingPairing
            ) { _ in
                Button("Annulla", role: .cancel) {
                    syncManager.cancelPairing()
                }
                Button("Conferma codice") {
                    syncManager.confirmPairing()
                }
            } message: { pending in
                Text("Dispositivo: \"\(pending.name)\"\n\nCodice di sicurezza a 6 cifre:\n\(pending.code)\n\nVerifica che lo stesso codice compaia sull'altro dispositivo prima di confermare.")
            }
            .sheet(item: $peerForFolderShare) { peer in
                ShareFolderPickerSheet(peer: peer) { folder in
                    syncManager.invitePeerToFolder(peer: peer, folderId: folder.id, folderName: folder.name)
                }
                .environmentObject(viewModel)
            }
        }
    }

    private var statusSection: some View {
        Section("Stato server locale") {
            HStack(spacing: 12) {
                Image(systemName: syncManager.isServerRunning ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundStyle(syncManager.isServerRunning ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(syncManager.deviceName)
                        .font(.headline)
                    if let ip = syncManager.localIpAddress {
                        Text("IP locale: \(ip)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
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
                get: { syncManager.isServerRunning },
                set: { on in
                    if on { syncManager.startP2P() } else { syncManager.stopP2P() }
                }
            ))

            Toggle("Sincronizzazione automatica con dispositivi fidati", isOn: $syncManager.autoSyncEnabled)
        }
    }

    private var invitesSection: some View {
        Section("Inviti a cartelle condivise (\(syncManager.incomingInvites.count))") {
            ForEach(syncManager.incomingInvites) { invite in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(invite.fromName) vuole condividere la cartella \"\(invite.folderName)\"")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        Button {
                            syncManager.acceptInvite(invite)
                        } label: {
                            Label("Accetta", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            syncManager.declineInvite(invite)
                        } label: {
                            Label("Rifiuta", systemImage: "xmark.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var peersSection: some View {
        Section("Dispositivi rilevati sulla rete Wi-Fi (\(syncManager.discoveredPeers.count))") {
            if syncManager.discoveredPeers.isEmpty {
                Text("Nessun altro dispositivo Paperclip trovato sulla rete locale. Assicurati che entrambi i dispositivi siano sullo stesso Wi-Fi con la sincronizzazione aperta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(syncManager.discoveredPeers) { peer in
                    peerRow(peer)
                }
            }
        }
    }

    private func peerRow(_ peer: PeerDevice) -> some View {
        let isTrusted = trustedDevices.byId(peer.deviceId) != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isTrusted ? "checkmark.shield.fill" : "iphone.radiowaves.left.and.right")
                    .foregroundStyle(isTrusted ? .green : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.name)
                        .font(.subheadline.weight(.semibold))
                    Text("\(peer.ip):\(peer.port)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                if isTrusted {
                    Button {
                        syncManager.syncWithPeer(peer)
                    } label: {
                        Label("Sincronizza", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncManager.isSyncing)

                    Button {
                        peerForFolderShare = peer
                    } label: {
                        Label("Condividi cartella", systemImage: "folder.badge.person.crop")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        syncManager.requestPairing(with: peer)
                    } label: {
                        Label("Associa (Codice a 6 cifre)", systemImage: "lock.shield")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(syncManager.isSyncing)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var trustedSection: some View {
        Section("Dispositivi fidati (\(trustedDevices.devices.count))") {
            if trustedDevices.devices.isEmpty {
                Text("Nessun dispositivo associato. Tocca 'Associa' su un dispositivo rilevato per abilitare la sincronizzazione automatica.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(trustedDevices.devices) { dev in
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dev.name)
                                .font(.subheadline.weight(.semibold))
                            Text(dev.deviceId)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            trustedDevices.remove(dev.deviceId)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var sharedFoldersSection: some View {
        Section("Cartelle condivise (\(sharedFolders.shares.count))") {
            ForEach(sharedFolders.shares) { share in
                let folderName = viewModel.folders.first(where: { $0.id == share.folderId })?.name ?? "Cartella #\(share.folderId)"
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "folder.fill.badge.person.crop")
                            .foregroundStyle(Color.accentColor)
                        Text(folderName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    ForEach(share.partners) { partner in
                        HStack {
                            Text("Condivisa con \(partner.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let onlinePeer = syncManager.discoveredPeers.first(where: { $0.deviceId == partner.deviceId }) {
                                Button {
                                    syncManager.syncSharedFolders(with: onlinePeer)
                                } label: {
                                    Label("Sincronizza", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption2.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                            }
                            Button(role: .destructive) {
                                sharedFolders.removePartner(shareId: share.id, deviceId: partner.deviceId)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var manualSection: some View {
        Section("Connessione manuale (IP)") {
            TextField("Indirizzo IP (es. 192.168.1.25)", text: $manualHost)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Porta", text: $manualPort)
                .keyboardType(.numberPad)

            HStack(spacing: 12) {
                Button {
                    let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
                    let port = Int(manualPort) ?? 8765
                    guard !host.isEmpty else { return }
                    let peer = PeerDevice(id: "\(host):\(port)", deviceId: host, name: host, ip: host, port: port)
                    syncManager.requestPairing(with: peer)
                } label: {
                    Label("Associa per IP", systemImage: "lock.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncManager.isSyncing)
            }
        }
    }
}

private struct ShareFolderPickerSheet: View {
    let peer: PeerDevice
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
            .navigationTitle("Condividi con \(peer.name)")
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
