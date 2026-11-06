import Foundation

/// A bounded-memory ZIP writer. Audio is already compressed, so entries use ZIP's
/// STORE method. ZIP32 limits are sufficient for the recorder's 1 GiB retention.
enum CalibrationAudioArchive {
    static func write(files: [URL], to destination: URL) throws {
        guard files.count < Int(UInt16.max) else { throw CocoaError(.fileWriteOutOfSpace) }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at: destination) } }
        var central = Data()
        for url in files {
            try Task.checkCancellation()
            let name = Data(url.lastPathComponent.utf8)
            let offset = try output.offset()
            guard name.count < Int(UInt16.max), offset < UInt64(UInt32.max) else { throw CocoaError(.fileWriteOutOfSpace) }
            var header = Data()
            header.le32(0x04034b50); header.le16(20); header.le16(0x0808) // UTF-8 + data descriptor
            header.le16(0); header.le16(0); header.le16(0x0021) // STORE; 1980-01-01
            header.le32(0); header.le32(0); header.le32(0); header.le16(UInt16(name.count)); header.le16(0)
            header.append(name); try output.write(contentsOf: header)
            let input = try FileHandle(forReadingFrom: url)
            var crc: UInt32 = 0xffffffff
            var size: UInt64 = 0
            do {
                while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    size += UInt64(data.count)
                    guard size < UInt64(UInt32.max) else { throw CocoaError(.fileWriteOutOfSpace) }
                    for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
                    try output.write(contentsOf: data)
                }
                try input.close()
            } catch { try? input.close(); throw error }
            crc ^= 0xffffffff
            var descriptor = Data(); descriptor.le32(0x08074b50); descriptor.le32(crc)
            descriptor.le32(UInt32(size)); descriptor.le32(UInt32(size)); try output.write(contentsOf: descriptor)
            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0808)
            central.le16(0); central.le16(0); central.le16(0x0021); central.le32(crc)
            central.le32(UInt32(size)); central.le32(UInt32(size)); central.le16(UInt16(name.count))
            central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0)
            central.le32(UInt32(offset)); central.append(name)
        }
        let centralOffset = try output.offset()
        guard centralOffset + UInt64(central.count) < UInt64(UInt32.max) else { throw CocoaError(.fileWriteOutOfSpace) }
        try output.write(contentsOf: central)
        var end = Data(); end.le32(0x06054b50); end.le16(0); end.le16(0)
        end.le16(UInt16(files.count)); end.le16(UInt16(files.count)); end.le32(UInt32(central.count))
        end.le32(UInt32(centralOffset)); end.le16(0); try output.write(contentsOf: end)
        try output.synchronize(); complete = true
    }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        return value
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 65535)); le16(UInt16(value >> 16)) }
}
