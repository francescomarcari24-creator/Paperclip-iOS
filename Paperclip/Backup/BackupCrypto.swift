import Foundation
import CryptoKit
import CommonCrypto
import Security

enum BackupCryptoError: LocalizedError {
    case notEncryptedBackup
    case unsupportedVersion(UInt8)
    case corruptedHeader
    case wrongPassword
    case corruptedOrTruncatedChunk
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .notEncryptedBackup:
            return "Non è un backup cifrato"
        case .unsupportedVersion(let v):
            return "Versione del backup cifrato non supportata (\(v))"
        case .corruptedHeader:
            return "Backup cifrato danneggiato"
        case .wrongPassword:
            return "Password errata"
        case .corruptedOrTruncatedChunk:
            return "Backup cifrato incompleto o danneggiato"
        case .keyDerivationFailed:
            return "Impossibile derivare la chiave crittografica"
        }
    }
}

enum BackupCrypto {
    static let magic: [UInt8] = Array("PCLIPENC".utf8)
    static let headerSize: Int = magic.count
    private static let version: UInt8 = 1
    private static let defaultIterations: Int32 = 200_000
    private static let maxIterations: Int32 = 10_000_000
    private static let saltSize: Int = 16
    private static let noncePrefixSize: Int = 8
    private static let keyBytesCount: Int = 32
    private static let tagBytesCount: Int = 16
    private static let chunkSize: Int = 64 * 1024

    static func isEncrypted(_ data: Data) -> Bool {
        guard data.count >= magic.count else { return false }
        return data.prefix(magic.count).elementsEqual(magic)
    }

    static func encrypt(_ plainData: Data, password: String) throws -> Data {
        var salt = Data(count: saltSize)
        var noncePrefix = Data(count: noncePrefixSize)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltSize, $0.baseAddress!) }
        _ = noncePrefix.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, noncePrefixSize, $0.baseAddress!) }

        let key = try deriveKey(password: password, salt: salt, iterations: Int(defaultIterations))

        var out = Data()
        out.append(contentsOf: magic)
        out.append(version)
        var iterBE = defaultIterations.bigEndian
        out.append(Data(bytes: &iterBE, count: 4))
        out.append(salt)
        out.append(noncePrefix)

        var offset = 0
        var chunkIndex: Int32 = 0

        // Matches BackupCrypto.kt EncryptingStream: writes full 64 KB chunks with last=false,
        // and on close() always writes one final chunk with last=true (even if 0 bytes remain).
        while offset < plainData.count {
            let remaining = plainData.count - offset
            if remaining > chunkSize {
                let slice = plainData.subdata(in: offset..<(offset + chunkSize))
                let sealed = try sealChunk(slice, key: key, noncePrefix: noncePrefix, index: chunkIndex, last: false)
                appendChunk(sealed, to: &out)
                chunkIndex += 1
                offset += chunkSize
            } else {
                break
            }
        }

        let finalSlice = offset < plainData.count ? plainData.subdata(in: offset..<plainData.count) : Data()
        let finalSealed = try sealChunk(finalSlice, key: key, noncePrefix: noncePrefix, index: chunkIndex, last: true)
        appendChunk(finalSealed, to: &out)

        return out
    }

    static func decrypt(_ encryptedData: Data, password: String) throws -> Data {
        let minHeader = magic.count + 1 + 4 + saltSize + noncePrefixSize
        guard encryptedData.count >= minHeader else {
            throw BackupCryptoError.corruptedHeader
        }
        guard isEncrypted(encryptedData) else {
            throw BackupCryptoError.notEncryptedBackup
        }

        var cursor = magic.count
        let ver = encryptedData[cursor]
        cursor += 1
        guard ver == version else {
            throw BackupCryptoError.unsupportedVersion(ver)
        }

        let iterations = Int32(bigEndian: encryptedData.subdata(in: cursor..<(cursor + 4)).withUnsafeBytes { $0.load(as: Int32.self) })
        cursor += 4
        guard iterations >= 1 && iterations <= maxIterations else {
            throw BackupCryptoError.corruptedHeader
        }

        let salt = encryptedData.subdata(in: cursor..<(cursor + saltSize))
        cursor += saltSize
        let noncePrefix = encryptedData.subdata(in: cursor..<(cursor + noncePrefixSize))
        cursor += noncePrefixSize

        let key = try deriveKey(password: password, salt: salt, iterations: Int(iterations))

        var out = Data()
        var chunkIndex: Int32 = 0
        var finished = false

        while !finished {
            guard cursor + 4 <= encryptedData.count else {
                throw BackupCryptoError.corruptedOrTruncatedChunk
            }
            let length = Int(Int32(bigEndian: encryptedData.subdata(in: cursor..<(cursor + 4)).withUnsafeBytes { $0.load(as: Int32.self) }))
            cursor += 4

            guard length >= tagBytesCount && length <= (chunkSize + tagBytesCount),
                  cursor + length <= encryptedData.count else {
                throw BackupCryptoError.corruptedOrTruncatedChunk
            }

            let sealed = encryptedData.subdata(in: cursor..<(cursor + length))
            cursor += length

            if let middlePlain = openChunk(sealed, key: key, noncePrefix: noncePrefix, index: chunkIndex, last: false) {
                out.append(middlePlain)
            } else if let lastPlain = openChunk(sealed, key: key, noncePrefix: noncePrefix, index: chunkIndex, last: true) {
                out.append(lastPlain)
                finished = true
            } else {
                if chunkIndex == 0 {
                    throw BackupCryptoError.wrongPassword
                } else {
                    throw BackupCryptoError.corruptedOrTruncatedChunk
                }
            }
            chunkIndex += 1
        }

        return out
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedBytes = [UInt8](repeating: 0, count: keyBytesCount)

        let status = passwordData.withUnsafeBytes { pwdPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwdPtr.bindMemory(to: Int8.self).baseAddress,
                    passwordData.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derivedBytes,
                    keyBytesCount
                )
            }
        }
        guard status == kCCSuccess else {
            throw BackupCryptoError.keyDerivationFailed
        }
        return SymmetricKey(data: Data(derivedBytes))
    }

    private static func makeNonce(prefix: Data, index: Int32) throws -> AES.GCM.Nonce {
        var nonceData = Data(prefix)
        var idxBE = index.bigEndian
        nonceData.append(Data(bytes: &idxBE, count: 4))
        return try AES.GCM.Nonce(data: nonceData)
    }

    private static func sealChunk(_ plain: Data, key: SymmetricKey, noncePrefix: Data, index: Int32, last: Bool) throws -> Data {
        let nonce = try makeNonce(prefix: noncePrefix, index: index)
        let aad = Data([last ? 1 : 0])
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad)
        var combined = Data(box.ciphertext)
        combined.append(box.tag)
        return combined
    }

    private static func openChunk(_ sealed: Data, key: SymmetricKey, noncePrefix: Data, index: Int32, last: Bool) -> Data? {
        guard sealed.count >= tagBytesCount,
              let nonce = try? makeNonce(prefix: noncePrefix, index: index) else {
            return nil
        }
        let ciphertext = sealed.prefix(sealed.count - tagBytesCount)
        let tag = sealed.suffix(tagBytesCount)
        let aad = Data([last ? 1 : 0])
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key, authenticating: aad)
    }

    private static func appendChunk(_ sealed: Data, to out: inout Data) {
        var lenBE = Int32(sealed.count).bigEndian
        out.append(Data(bytes: &lenBE, count: 4))
        out.append(sealed)
    }
}

// MARK: - Keychain BackupPassword

enum BackupPassword {
    private static let service = "com.project.paperclip.backup"
    private static let account = "backup_password"

    static var isSet: Bool {
        Self.get() != nil
    }

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ password: String?) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let password = password, !password.isEmpty, let data = password.data(using: .utf8) else {
            return
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
