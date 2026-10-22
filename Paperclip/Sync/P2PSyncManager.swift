import Foundation
import Network
import UIKit
import Darwin

struct PeerDevice: Identifiable, Equatable {
    let id: String
    let deviceId: String
    let name: String
    let ip: String
    let port: Int
}

struct PairingMessage: Codable {
    let deviceId: String
    let name: String
    let publicKey: String
}

struct PendingPairing: Identifiable, Equatable {
    var id: String { deviceId }
    let deviceId: String
    let name: String
    let code: String
    let secret: String
    let outgoing: Bool
}

struct FolderInvite: Codable, Identifiable, Equatable {
    var id: String { shareId }
    let shareId: String
    let folderName: String
    let fromDeviceId: String
    let fromName: String
    let secret: String
    let port: Int
    var ip: String? = nil
}

struct SharedFolderPayload: Codable {
    let rootFolderId: Int64
    let folders: [Folder]
    let tags: [Tag]
    let items: [ArchiveItem]
    let crossRefs: [ItemTagCrossRef]
    let contents: [ItemContent]?
}

struct SyncPayload: Codable {
    let deviceId: String
    let port: Int
    let folders: [Folder]
    let tags: [Tag]
    let items: [ArchiveItem]
    let crossRefs: [ItemTagCrossRef]
    let contents: [ItemContent]?
}

final class P2PSyncManager: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = P2PSyncManager()

    private static let serviceType = "_paperclip-sync._tcp."
    private static let servicePrefix = "Paperclip_"
    private static let headerDevice = "x-paperclip-device"
    private static let headerPort = "x-paperclip-port"
    private static let headerTime = "x-paperclip-time"
    private static let headerSignature = "x-paperclip-signature"
    private static let headerShare = "x-paperclip-share"
    private static let signatureMaxAgeMs: Int64 = 10 * 60 * 1000

    let deviceId: String
    var deviceName: String { ShareSelection.deviceName }

    @Published private(set) var isServerRunning: Bool = false
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var statusMessage: String = "P2P Non Attivo"
    @Published private(set) var localIpAddress: String? = nil
    @Published private(set) var discoveredPeers: [PeerDevice] = []
    @Published private(set) var pendingPairing: PendingPairing? = nil
    @Published private(set) var incomingInvites: [FolderInvite] = []
    @Published var autoSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: "p2p_auto_sync_enabled") }
    }

    private var serverSocketFD: Int32 = -1
    private var localPort: Int = 0
    private var netService: NetService?
    private var browser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private let database = PaperclipDatabase.shared
    private let trustedDevices = TrustedDevices.shared
    private let sharedFolders = SharedFolders.shared
    private let merger = ArchiveMerger()
    /// Le sincronizzazioni girano una alla volta, così due merge non scrivono insieme sul database.
    private let syncQueue = DispatchQueue(label: "com.paperclip.p2p.sync", qos: .userInitiated)
    private var pendingChangeSync: DispatchWorkItem?
    var onArchiveUpdated: (() -> Void)?

    private override init() {
        let key = "paperclip_p2p_stable_device_id"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            self.deviceId = saved
        } else {
            let generated = "iPhone_" + UUID().uuidString.prefix(6)
            UserDefaults.standard.set(generated, forKey: key)
            self.deviceId = generated
        }
        self.autoSyncEnabled = UserDefaults.standard.bool(forKey: "p2p_auto_sync_enabled")
        super.init()
    }

    // MARK: - Start / Stop P2P Server & Bonjour

    func startP2P() {
        guard !isServerRunning else { return }
        localIpAddress = Self.findLocalWiFiAddress()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            updateStatus("Impossibile creare il socket P2P")
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            updateStatus("Errore apertura porta locale P2P")
            return
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        localPort = Int(UInt16(bigEndian: boundAddr.sin_port))
        serverSocketFD = fd
        isServerRunning = true
        updateStatus("In ascolto sulla rete Wi-Fi locale (porta \(localPort))…")
        AppLogger.shared.info("P2P", "Server HTTP P2P avviato su porta \(localPort) (\(localIpAddress ?? "IP sconosciuto"))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(fd: fd)
        }

        DispatchQueue.main.async {
            self.startBonjour(port: self.localPort)
        }
    }

    func stopP2P() {
        guard isServerRunning else { return }
        isServerRunning = false
        if serverSocketFD >= 0 {
            Darwin.close(serverSocketFD)
            serverSocketFD = -1
        }
        netService?.stop()
        netService = nil
        browser?.stop()
        browser = nil
        resolvingServices.removeAll()
        DispatchQueue.main.async {
            self.discoveredPeers = []
            self.statusMessage = "P2P Disattivato"
        }
    }

    private func startBonjour(port: Int) {
        let service = NetService(domain: "local.", type: Self.serviceType, name: "\(Self.servicePrefix)\(deviceId)", port: Int32(port))
        let nameData = Data(deviceName.prefix(60).utf8)
        let txtData = NetService.data(fromTXTRecord: ["name": nameData])
        service.setTXTRecord(txtData)
        service.delegate = self
        service.publish()
        self.netService = service

        let netBrowser = NetServiceBrowser()
        netBrowser.delegate = self
        netBrowser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        self.browser = netBrowser
    }

    // MARK: - NetServiceBrowserDelegate & NetServiceDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !service.name.contains(deviceId) else { return }
        resolvingServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 8.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        DispatchQueue.main.async {
            self.discoveredPeers.removeAll { $0.id == service.name }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }
        var resolvedIp: String? = nil
        for addrData in addresses {
            addrData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                if family == sa_family_t(AF_INET) {
                    var sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                    resolvedIp = String(cString: buffer)
                }
            }
            if resolvedIp != nil { break }
        }

        guard let ip = resolvedIp, ip != localIpAddress, sender.port > 0 else { return }
        let peerDeviceId = sender.name.hasPrefix(Self.servicePrefix)
            ? String(sender.name.dropFirst(Self.servicePrefix.count))
            : sender.name

        var readableName = peerDeviceId
        if let txt = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txt)
            if let nameBytes = dict["name"], let str = String(data: nameBytes, encoding: .utf8), !str.isEmpty {
                readableName = str
            }
        }
        if readableName == peerDeviceId, let trusted = trustedDevices.byId(peerDeviceId) {
            readableName = trusted.name
        }

        let peer = PeerDevice(id: sender.name, deviceId: peerDeviceId, name: readableName, ip: ip, port: sender.port)
        DispatchQueue.main.async {
            self.discoveredPeers.removeAll { $0.id == peer.id }
            self.discoveredPeers.append(peer)
            AppLogger.shared.info("P2P", "Trovato dispositivo \(peer.name) (\(peer.ip):\(peer.port))")

            if self.autoSyncEnabled && self.trustedDevices.byId(peer.deviceId) != nil && !self.isSyncing {
                self.syncWithPeer(peer)
            }
        }
    }

    // MARK: - Pairing, Sync & Shared Folders Actions

    func requestPairing(with peer: PeerDevice) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let pairing = TrustedDevices.Pairing()
                let msg = PairingMessage(deviceId: self.deviceId, name: self.deviceName, publicKey: pairing.publicKey)
                let body = try JSONEncoder().encode(msg)
                let (head, respData) = try self.exchange(ip: peer.ip, port: peer.port, requestLine: "POST /pair/request", body: body, headers: [:])
                guard head.isOk else {
                    throw NSError(domain: "P2P", code: head.status ?? 500, userInfo: [NSLocalizedDescriptionKey: head.firstLine])
                }
                let response = try JSONDecoder().decode(PairingMessage.self, from: respData)
                let derived = try pairing.derive(peerPublicKey: response.publicKey, requesterKey: pairing.publicKey, responderKey: response.publicKey)
                DispatchQueue.main.async {
                    self.pendingPairing = PendingPairing(
                        deviceId: peer.deviceId,
                        name: response.name,
                        code: derived.code,
                        secret: derived.secret,
                        outgoing: true
                    )
                }
            } catch {
                self.updateStatus("Associazione non riuscita: \(error.localizedDescription)")
            }
        }
    }

    func confirmPairing() {
        guard let pending = pendingPairing else { return }
        trustedDevices.add(TrustedDevices.Device(
            deviceId: pending.deviceId,
            name: pending.name,
            secret: pending.secret,
            pairedAt: ArchiveItem.nowMillis()
        ))
        pendingPairing = nil
        updateStatus("\(pending.name) associato: ora potete sincronizzare l'archivio!")
    }

    func cancelPairing() {
        pendingPairing = nil
    }

    func syncWithPeer(_ peer: PeerDevice) {
        guard let trusted = trustedDevices.byId(peer.deviceId) else {
            updateStatus("Associa prima \(peer.name) per sincronizzare l'intero archivio.")
            return
        }
        syncQueue.async {
            DispatchQueue.main.async { self.isSyncing = true }
            self.updateStatus("Sincronizzazione in corso con \(peer.name)…")
            defer { DispatchQueue.main.async { self.isSyncing = false } }

            do {
                let getHeaders = self.signedHeaders(secret: trusted.secret, method: "GET", path: "/sync")
                let (getHead, getBody) = try self.exchange(ip: peer.ip, port: peer.port, requestLine: "GET /sync", body: Data(), headers: getHeaders)
                if getHead.status == 403 {
                    throw NSError(domain: "P2P", code: 403, userInfo: [NSLocalizedDescriptionKey: "L'altro dispositivo non ti riconosce: associateli di nuovo"])
                }
                guard getHead.isOk else {
                    throw NSError(domain: "P2P", code: getHead.status ?? 500, userInfo: [NSLocalizedDescriptionKey: getHead.firstLine])
                }

                let remotePayload = try JSONDecoder().decode(SyncPayload.self, from: getBody)
                self.updateStatus("Ricezione ed elaborazione dati da \(peer.name)…")
                self.mergePayload(remotePayload, ip: peer.ip, port: peer.port, secret: trusted.secret)

                let localPayload = self.buildLocalPayload()
                let postBody = try JSONEncoder().encode(localPayload)
                let postHeaders = self.signedHeaders(secret: trusted.secret, method: "POST", path: "/sync")
                let (postHead, _) = try self.exchange(ip: peer.ip, port: peer.port, requestLine: "POST /sync", body: postBody, headers: postHeaders)
                guard postHead.isOk else {
                    throw NSError(domain: "P2P", code: postHead.status ?? 500, userInfo: [NSLocalizedDescriptionKey: postHead.firstLine])
                }

                DispatchQueue.main.async {
                    self.onArchiveUpdated?()
                    self.statusMessage = "Sincronizzazione completata con successo con \(peer.name)!"
                }
                AppLogger.shared.info("P2P", "Sincronizzazione completata con \(peer.name)")
            } catch {
                self.updateStatus("Errore di sincronizzazione: \(error.localizedDescription)")
                AppLogger.shared.error("P2P", "Errore sync con \(peer.name): \(error.localizedDescription)")
            }
        }
    }

    func invitePeerToFolder(peer: PeerDevice, folderId: Int64, folderName: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let secret = SharedFolders.newSecret()
            let shareId = self.sharedFolders.addPartner(
                folderId: folderId,
                partner: SharedFolders.Partner(deviceId: peer.deviceId, name: peer.name, secret: secret)
            )
            let invite = FolderInvite(
                shareId: shareId,
                folderName: folderName,
                fromDeviceId: self.deviceId,
                fromName: self.deviceName,
                secret: secret,
                port: self.localPort
            )
            do {
                let body = try JSONEncoder().encode(invite)
                let (head, _) = try self.exchange(ip: peer.ip, port: peer.port, requestLine: "POST /share/invite", body: body, headers: [:])
                guard head.isOk else {
                    throw NSError(domain: "P2P", code: 403, userInfo: [NSLocalizedDescriptionKey: head.firstLine])
                }
                self.updateStatus("Invito inviato a \(peer.name) per la cartella \"\(folderName)\"")
            } catch {
                DispatchQueue.main.async {
                    self.sharedFolders.removePartner(shareId: shareId, deviceId: peer.deviceId)
                }
                self.updateStatus("Invito non inviato: \(error.localizedDescription)")
            }
        }
    }

    func acceptInvite(_ invite: FolderInvite) {
        incomingInvites.removeAll { $0.shareId == invite.shareId }
        let existingNames = Set(database.getAllFolders().filter { $0.parentId == nil }.map(\.name))
        let name = existingNames.contains(invite.folderName) ? "\(invite.folderName) (\(invite.fromName))" : invite.folderName
        let folderId = database.saveFolder(Folder(name: name))
        sharedFolders.addPartner(
            folderId: folderId,
            partner: SharedFolders.Partner(deviceId: invite.fromDeviceId, name: invite.fromName, secret: invite.secret),
            shareId: invite.shareId
        )
        onArchiveUpdated?()
        if let ip = invite.ip, let peer = discoveredPeers.first(where: { $0.deviceId == invite.fromDeviceId }) ?? Optional(PeerDevice(id: invite.fromDeviceId, deviceId: invite.fromDeviceId, name: invite.fromName, ip: ip, port: invite.port)) {
            syncSharedFolders(with: peer)
        }
    }

    func declineInvite(_ invite: FolderInvite) {
        incomingInvites.removeAll { $0.shareId == invite.shareId }
    }

    /// Chiamato dopo ogni creazione, modifica o eliminazione di un elemento: se almeno un dispositivo
    /// associato (o partner di una cartella condivisa) è raggiungibile, avvia la sincronizzazione.
    /// Le modifiche ravvicinate vengono raggruppate in un'unica sincronizzazione.
    func scheduleSyncAfterLocalChange() {
        DispatchQueue.main.async {
            guard self.isServerRunning else { return }
            self.pendingChangeSync?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.syncConnectedPeers() }
            self.pendingChangeSync = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func syncConnectedPeers() {
        let trustedPeers = discoveredPeers.filter { trustedDevices.byId($0.deviceId) != nil }
        let sharePartners = discoveredPeers.filter { peer in
            trustedDevices.byId(peer.deviceId) == nil &&
                sharedFolders.shares.contains { $0.partners.contains { $0.deviceId == peer.deviceId } }
        }
        guard !trustedPeers.isEmpty || !sharePartners.isEmpty else { return }
        AppLogger.shared.info("P2P", "Modifica locale: sincronizzazione automatica con \(trustedPeers.count + sharePartners.count) dispositivi")
        trustedPeers.forEach { syncWithPeer($0) }
        sharePartners.forEach { syncSharedFolders(with: $0) }
    }

    func syncSharedFolders(with peer: PeerDevice) {
        syncQueue.async {
            for share in self.sharedFolders.shares {
                guard let partner = share.partners.first(where: { $0.deviceId == peer.deviceId }) else { continue }
                let path = "/share/\(share.id)"
                do {
                    let getHeaders = self.signedHeaders(secret: partner.secret, method: "GET", path: path)
                    let (getHead, getBody) = try self.exchange(ip: peer.ip, port: peer.port, requestLine: "GET \(path)", body: Data(), headers: getHeaders)
                    guard getHead.isOk else { continue }
                    let remote = try JSONDecoder().decode(SharedFolderPayload.self, from: getBody)
                    self.mergeShared(share: share, partner: partner, payload: remote, ip: peer.ip, port: peer.port)

                    let rows = ShareSelection.ofFolder(database: self.database, folderId: share.folderId, includeTrashed: true)
                    let localPayload = SharedFolderPayload(
                        rootFolderId: share.folderId,
                        folders: rows.folders,
                        tags: rows.tags,
                        items: rows.items,
                        crossRefs: rows.crossRefs,
                        contents: rows.contents
                    )
                    let postBody = try JSONEncoder().encode(localPayload)
                    let postHeaders = self.signedHeaders(secret: partner.secret, method: "POST", path: path)
                    _ = try self.exchange(ip: peer.ip, port: peer.port, requestLine: "POST \(path)", body: postBody, headers: postHeaders)
                    DispatchQueue.main.async {
                        self.sharedFolders.markSynced(shareId: share.id, deviceId: partner.deviceId)
                        self.onArchiveUpdated?()
                        self.statusMessage = "Cartella condivisa sincronizzata con \(partner.name)"
                    }
                } catch {
                    self.updateStatus("Errore sync cartella condivisa: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - HTTP Server Loop & Handlers

    private func acceptLoop(fd: Int32) {
        while isServerRunning && serverSocketFD == fd {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &clientLen)
                }
            }
            if clientFD < 0 { break }

            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &clientAddr.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
            let peerIp = String(cString: ipBuffer)

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(fd: clientFD, peerIp: peerIp)
            }
        }
    }

    private func handleClient(fd: Int32, peerIp: String) {
        defer { Darwin.close(fd) }
        guard let (head, body) = Self.readHttpMessage(fd: fd) else { return }
        let parts = head.firstLine.split(separator: " ").map(String.init)
        let method = parts.first ?? ""
        let path = parts.count > 1 ? parts[1] : ""

        let senderDeviceId = head.headers[Self.headerDevice]
        let trusted = trustedDevices.byId(senderDeviceId).flatMap { dev -> TrustedDevices.Device? in
            isSignedBy(head: head, secret: dev.secret, senderId: dev.deviceId, method: method, path: path) ? dev : nil
        }

        if path == "/sync" && trusted == nil {
            Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 403 Forbidden", body: Data())
            return
        }

        if method == "GET" && path == "/sync" {
            if let data = try? JSONEncoder().encode(buildLocalPayload()) {
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 200 OK", body: data)
            } else {
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 500 Internal Server Error", body: Data())
            }
        } else if method == "POST" && path == "/sync" {
            let payload = try? JSONDecoder().decode(SyncPayload.self, from: body)
            Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 200 OK", body: Data())
            if let payload = payload, let trusted = trusted {
                mergePayload(payload, ip: peerIp, port: payload.port, secret: trusted.secret)
                DispatchQueue.main.async { self.onArchiveUpdated?() }
            }
        } else if method == "POST" && path == "/pair/request" {
            guard let req = try? JSONDecoder().decode(PairingMessage.self, from: body),
                  req.deviceId == senderDeviceId else {
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 403 Forbidden", body: Data())
                return
            }
            let pairing = TrustedDevices.Pairing()
            if let derived = try? pairing.derive(peerPublicKey: req.publicKey, requesterKey: req.publicKey, responderKey: pairing.publicKey) {
                DispatchQueue.main.async {
                    self.pendingPairing = PendingPairing(
                        deviceId: req.deviceId,
                        name: req.name,
                        code: derived.code,
                        secret: derived.secret,
                        outgoing: false
                    )
                }
                let resp = PairingMessage(deviceId: deviceId, name: deviceName, publicKey: pairing.publicKey)
                let respBytes = (try? JSONEncoder().encode(resp)) ?? Data()
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 200 OK", body: respBytes)
            } else {
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 403 Forbidden", body: Data())
            }
        } else if method == "POST" && path == "/share/invite" {
            if var invite = try? JSONDecoder().decode(FolderInvite.self, from: body),
               invite.fromDeviceId == senderDeviceId {
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 200 OK", body: Data())
                invite.ip = peerIp
                if sharedFolders.byId(invite.shareId) == nil {
                    DispatchQueue.main.async {
                        self.incomingInvites.removeAll { $0.shareId == invite.shareId }
                        self.incomingInvites.append(invite)
                    }
                }
            } else {
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 403 Forbidden", body: Data())
            }
        } else if path.hasPrefix("/share/") {
            let shareId = String(path.dropFirst("/share/".count))
            guard let share = sharedFolders.byId(shareId),
                  let partner = share.partners.first(where: { $0.deviceId == senderDeviceId }),
                  isSignedBy(head: head, secret: partner.secret, senderId: partner.deviceId, method: method, path: path) else {
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 403 Forbidden", body: Data())
                return
            }
            if method == "GET" {
                let rows = ShareSelection.ofFolder(database: database, folderId: share.folderId, includeTrashed: true)
                let payload = SharedFolderPayload(
                    rootFolderId: share.folderId,
                    folders: rows.folders,
                    tags: rows.tags,
                    items: rows.items,
                    crossRefs: rows.crossRefs,
                    contents: rows.contents
                )
                let data = (try? JSONEncoder().encode(payload)) ?? Data()
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 200 OK", body: data)
            } else if method == "POST" {
                let payload = try? JSONDecoder().decode(SharedFolderPayload.self, from: body)
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 200 OK", body: Data())
                if let payload = payload, let peerPort = head.headers[Self.headerPort].flatMap(Int.init) {
                    mergeShared(share: share, partner: partner, payload: payload, ip: peerIp, port: peerPort)
                    DispatchQueue.main.async {
                        self.sharedFolders.markSynced(shareId: share.id, deviceId: partner.deviceId)
                        self.onArchiveUpdated?()
                    }
                }
            }
        } else if method == "GET" && path.hasPrefix("/media/") {
            let fileName = (path as NSString).lastPathComponent
            let fileUrl = FileStorageManager.shared.mediaDirectory.appendingPathComponent(fileName)
            let allowed: Bool = {
                if trusted != nil { return true }
                if let shareId = head.headers[Self.headerShare],
                   let share = sharedFolders.byId(shareId),
                   let partner = share.partners.first(where: { $0.deviceId == senderDeviceId }),
                   isSignedBy(head: head, secret: partner.secret, senderId: partner.deviceId, method: "GET", path: path) {
                    return true
                }
                return false
            }()
            if allowed, let fileData = try? Data(contentsOf: fileUrl) {
                Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 200 OK", body: fileData)
            } else {
                Self.writeHttpResponse(fd: fd, status: allowed ? "HTTP/1.1 404 Not Found" : "HTTP/1.1 403 Forbidden", body: Data())
            }
        } else {
            Self.writeHttpResponse(fd: fd, status: "HTTP/1.1 404 Not Found", body: Data())
        }
    }

    // MARK: - Payload & Media Helpers

    private func buildLocalPayload() -> SyncPayload {
        SyncPayload(
            deviceId: deviceId,
            port: localPort,
            folders: database.getAllFolders(),
            tags: database.getAllTags(),
            items: database.getAllItems(),
            crossRefs: database.getAllCrossRefs(),
            contents: database.getAllItemContents()
        )
    }

    private func mergePayload(_ payload: SyncPayload, ip: String, port: Int, secret: String) {
        let rows = ArchiveRows(
            folders: payload.folders,
            tags: payload.tags,
            items: payload.items,
            crossRefs: payload.crossRefs,
            contents: payload.contents
        )
        _ = merger.merge(rows: rows, placement: .byPath) { path in
            let fileName = path.map { ($0 as NSString).lastPathComponent } ?? ""
            let headers = self.signedHeaders(secret: secret, method: "GET", path: "/media/\(fileName)")
            return self.localizeMedia(path: path, ip: ip, port: port, headers: headers)
        }
    }

    private func mergeShared(share: SharedFolders.Share, partner: SharedFolders.Partner, payload: SharedFolderPayload, ip: String, port: Int) {
        let rows = ArchiveRows(
            folders: payload.folders,
            tags: payload.tags,
            items: payload.items,
            crossRefs: payload.crossRefs,
            contents: payload.contents
        )
        _ = merger.merge(rows: rows, placement: .intoFolder(remoteRootId: payload.rootFolderId, localRootId: share.folderId)) { path in
            let fileName = path.map { ($0 as NSString).lastPathComponent } ?? ""
            var headers = self.signedHeaders(secret: partner.secret, method: "GET", path: "/media/\(fileName)")
            headers[Self.headerShare] = share.id
            return self.localizeMedia(path: path, ip: ip, port: port, headers: headers)
        }
    }

    private func localizeMedia(path: String?, ip: String, port: Int, headers: [String: String]) -> String? {
        guard let path = path, !path.isEmpty else { return path }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        let fileName = (path as NSString).lastPathComponent
        guard !fileName.isEmpty else { return path }
        let localUrl = FileStorageManager.shared.mediaDirectory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: localUrl.path) {
            if let (head, data) = try? exchange(ip: ip, port: port, requestLine: "GET /media/\(fileName)", body: Data(), headers: headers),
               head.isOk, !data.isEmpty {
                try? data.write(to: localUrl, options: .atomic)
            }
        }
        return localUrl.path
    }

    private func signedHeaders(secret: String, method: String, path: String) -> [String: String] {
        let time = String(ArchiveItem.nowMillis())
        let sig = SharedFolders.sign(secret: secret, message: "\(method) \(path) \(time) \(deviceId)")
        return [
            Self.headerTime: time,
            Self.headerSignature: sig
        ]
    }

    private func isSignedBy(head: HttpHead, secret: String, senderId: String, method: String, path: String) -> Bool {
        guard let timeStr = head.headers[Self.headerTime],
              let time = Int64(timeStr),
              abs(ArchiveItem.nowMillis() - time) <= Self.signatureMaxAgeMs,
              let given = head.headers[Self.headerSignature] else {
            return false
        }
        let expected = SharedFolders.sign(secret: secret, message: "\(method) \(path) \(time) \(senderId)")
        return expected.lowercased() == given.lowercased()
    }

    // MARK: - Low-level HTTP over POSIX Socket

    private struct HttpHead {
        let firstLine: String
        let contentLength: Int
        let headers: [String: String]

        var status: Int? {
            let parts = firstLine.split(separator: " ")
            return parts.count > 1 ? Int(parts[1]) : nil
        }

        var isOk: Bool { status == 200 }
    }

    private func exchange(ip: String, port: Int, requestLine: String, body: Data, headers: [String: String]) throws -> (HttpHead, Data) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "P2P", code: -1, userInfo: [NSLocalizedDescriptionKey: "Socket non disponibile"])
        }
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)

        let connResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connResult == 0 else {
            throw NSError(domain: "P2P", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Impossibile connettersi a \(ip):\(port)"])
        }

        var allHeaders = headers
        allHeaders[Self.headerDevice] = deviceId
        allHeaders[Self.headerPort] = String(localPort)

        var headerStr = "\(requestLine) HTTP/1.1\r\nContent-Length: \(body.count)\r\n"
        for (k, v) in allHeaders {
            headerStr += "\(k): \(v)\r\n"
        }
        headerStr += "\r\n"

        var outData = Data(headerStr.utf8)
        outData.append(body)
        try Self.writeAll(fd: fd, data: outData)

        guard let resp = Self.readHttpMessage(fd: fd) else {
            throw NSError(domain: "P2P", code: -2, userInfo: [NSLocalizedDescriptionKey: "Nessuna risposta dal dispositivo"])
        }
        return resp
    }

    private static func writeHttpResponse(fd: Int32, status: String, body: Data) {
        let header = "\(status)\r\nContent-Length: \(body.count)\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        try? writeAll(fd: fd, data: payload)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    throw NSError(domain: "P2P", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Invio interrotto"])
                }
                sent += n
            }
        }
    }

    private static func readHttpMessage(fd: Int32) -> (HttpHead, Data)? {
        guard let firstLine = readLine(fd: fd) else { return nil }
        var headers: [String: String] = [:]
        while let line = readLine(fd: fd), !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        var body = Data(count: length)
        if length > 0 {
            let ok = body.withUnsafeMutableBytes { ptr -> Bool in
                guard let base = ptr.baseAddress else { return false }
                var received = 0
                while received < length {
                    let n = Darwin.recv(fd, base.advanced(by: received), length - received, 0)
                    if n <= 0 { return false }
                    received += n
                }
                return true
            }
            if !ok { return nil }
        }
        return (HttpHead(firstLine: firstLine, contentLength: length, headers: headers), body)
    }

    private static func readLine(fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var ch: UInt8 = 0
        while true {
            let n = Darwin.recv(fd, &ch, 1, 0)
            if n <= 0 {
                return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
            }
            if ch == UInt8(ascii: "\n") {
                return String(bytes: bytes, encoding: .utf8)
            }
            if ch != UInt8(ascii: "\r") {
                bytes.append(ch)
            }
        }
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusMessage = text
        }
    }

    static func findLocalWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    )
                    let candidate = String(cString: hostname)
                    if !candidate.hasPrefix("127.") && !candidate.isEmpty {
                        address = candidate
                        if name == "en0" { break }
                    }
                }
            }
        }
        return address
    }
}
