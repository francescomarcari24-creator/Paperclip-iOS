import Foundation
import zlib

enum ZipArchiveError: LocalizedError {
    case invalidArchive
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "Archivio ZIP non valido"
        case .decompressionFailed: return "Impossibile decomprimere l'archivio ZIP"
        }
    }
}

struct ZipEntryData {
    let name: String
    let data: Data
}

enum ZipArchive {

    /// Creates a standard ZIP archive with DEFLATE compression and known sizes in local headers,
    /// 100% readable by Android's `ZipInputStream` as well as macOS/Windows/iOS unzip tools.
    static func createZip(entries: [ZipEntryData]) -> Data {
        var out = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for entry in entries {
            guard let nameBytes = entry.name.data(using: .utf8) else { continue }
            let localHeaderOffset = UInt32(out.count)
            let uncompressedSize = UInt32(entry.data.count)
            let crc = computeCRC32(entry.data)

            let compressed = deflateRaw(entry.data) ?? entry.data
            let useDeflate = compressed.count < entry.data.count
            let payload = useDeflate ? compressed : entry.data
            let method: UInt16 = useDeflate ? 8 : 0
            let compressedSize = UInt32(payload.count)

            // Local file header (signature 0x04034b50)
            out.appendUInt32LE(0x04034b50)
            out.appendUInt16LE(20) // version needed
            out.appendUInt16LE(0x0800) // UTF-8 filename flag
            out.appendUInt16LE(method)
            out.appendUInt16LE(0) // mod time
            out.appendUInt16LE(0) // mod date
            out.appendUInt32LE(crc)
            out.appendUInt32LE(compressedSize)
            out.appendUInt32LE(uncompressedSize)
            out.appendUInt16LE(UInt16(nameBytes.count))
            out.appendUInt16LE(0) // extra length
            out.append(nameBytes)
            out.append(payload)

            // Central directory file header (signature 0x02014b50)
            centralDirectory.appendUInt32LE(0x02014b50)
            centralDirectory.appendUInt16LE(20) // version made by
            centralDirectory.appendUInt16LE(20) // version needed
            centralDirectory.appendUInt16LE(0x0800) // UTF-8 flag
            centralDirectory.appendUInt16LE(method)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(compressedSize)
            centralDirectory.appendUInt32LE(uncompressedSize)
            centralDirectory.appendUInt16LE(UInt16(nameBytes.count))
            centralDirectory.appendUInt16LE(0) // extra
            centralDirectory.appendUInt16LE(0) // comment
            centralDirectory.appendUInt16LE(0) // disk start
            centralDirectory.appendUInt16LE(0) // internal attr
            centralDirectory.appendUInt32LE(0) // external attr
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(nameBytes)

            entryCount &+= 1
        }

        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(centralDirectory.count)
        out.append(centralDirectory)

        // End of Central Directory Record (signature 0x06054b50)
        out.appendUInt32LE(0x06054b50)
        out.appendUInt16LE(0)
        out.appendUInt16LE(0)
        out.appendUInt16LE(entryCount)
        out.appendUInt16LE(entryCount)
        out.appendUInt32LE(cdSize)
        out.appendUInt32LE(cdOffset)
        out.appendUInt16LE(0)

        return out
    }

    /// Reads all entries from a ZIP archive via its Central Directory (supporting streaming data descriptors
    /// produced by Android's `java.util.zip.ZipOutputStream`).
    static func readZip(_ archive: Data) throws -> [ZipEntryData] {
        guard archive.count >= 22 else { throw ZipArchiveError.invalidArchive }

        // Locate End of Central Directory (0x06054b50) scanning backwards from the end
        let minSearch = max(0, archive.count - 65557)
        var eocdOffset: Int?
        var pos = archive.count - 22
        while pos >= minSearch {
            if archive.readUInt32LE(at: pos) == 0x06054b50 {
                eocdOffset = pos
                break
            }
            pos -= 1
        }

        guard let eocd = eocdOffset else {
            throw ZipArchiveError.invalidArchive
        }

        let totalEntries = Int(archive.readUInt16LE(at: eocd + 10))
        let cdOffset = Int(archive.readUInt32LE(at: eocd + 16))
        guard cdOffset >= 0 && cdOffset <= archive.count else {
            throw ZipArchiveError.invalidArchive
        }

        var results: [ZipEntryData] = []
        var cursor = cdOffset

        for _ in 0..<totalEntries {
            guard cursor + 46 <= archive.count,
                  archive.readUInt32LE(at: cursor) == 0x02014b50 else {
                break
            }
            let method = archive.readUInt16LE(at: cursor + 10)
            let compSize = Int(archive.readUInt32LE(at: cursor + 20))
            let uncompSize = Int(archive.readUInt32LE(at: cursor + 24))
            let nameLen = Int(archive.readUInt16LE(at: cursor + 28))
            let extraLen = Int(archive.readUInt16LE(at: cursor + 30))
            let commentLen = Int(archive.readUInt16LE(at: cursor + 32))
            let localOffset = Int(archive.readUInt32LE(at: cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLen <= archive.count else { break }
            let nameData = archive.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""

            cursor = nameStart + nameLen + extraLen + commentLen

            // Read local file header to find where compressed data begins
            guard localOffset + 30 <= archive.count,
                  archive.readUInt32LE(at: localOffset) == 0x04034b50 else {
                continue
            }
            let localNameLen = Int(archive.readUInt16LE(at: localOffset + 26))
            let localExtraLen = Int(archive.readUInt16LE(at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            guard dataStart + compSize <= archive.count else { continue }

            let compressedSlice = archive.subdata(in: dataStart..<(dataStart + compSize))
            let entryData: Data
            if method == 0 {
                entryData = compressedSlice
            } else if method == 8 {
                guard let inflated = inflateRaw(compressedSlice, expectedSize: uncompSize) else {
                    throw ZipArchiveError.decompressionFailed
                }
                entryData = inflated
            } else {
                continue
            }
            results.append(ZipEntryData(name: name, data: entryData))
        }

        return results
    }

    private static func computeCRC32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { ptr in
            let crc = zlib.crc32(0, ptr.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))
            return UInt32(crc & 0xFFFFFFFF)
        }
    }

    private static func deflateRaw(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        let bound = Int(deflateBound(&stream, uLong(data.count))) + 64
        var out = Data(count: bound)

        let rc: Int32 = data.withUnsafeBytes { inPtr in
            out.withUnsafeMutableBytes { outPtr in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inPtr.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = outPtr.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(bound)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard rc == Z_STREAM_END else { return nil }
        out.count = Int(stream.total_out)
        return out
    }

    private static func inflateRaw(_ data: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 && data.isEmpty { return Data() }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var capacity = max(expectedSize, data.count * 2, 4096)
        var out = Data(count: capacity)

        return data.withUnsafeBytes { inPtr -> Data? in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inPtr.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            while true {
                if Int(stream.total_out) >= out.count {
                    capacity *= 2
                    out.count = capacity
                }
                let currentCapacity = out.count
                let status = out.withUnsafeMutableBytes { outPtr -> Int32 in
                    let base = outPtr.bindMemory(to: Bytef.self).baseAddress!
                    stream.next_out = base.advanced(by: Int(stream.total_out))
                    stream.avail_out = uInt(currentCapacity - Int(stream.total_out))
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                if status == Z_STREAM_END {
                    out.count = Int(stream.total_out)
                    return out
                } else if status != Z_OK {
                    return nil
                }
            }
        }
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1]) << 8
        return b0 | b1
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
