import Darwin
import Foundation

/// Minimal USDZ container writer for Apple platforms that predate USDKit.
///
/// USDZ is a constrained ZIP archive: entries are stored without compression,
/// encryption or data descriptors, and every file payload begins on a 64-byte
/// boundary. Keeping this package-local avoids both a private framework link and
/// an app-target dependency from the reusable Hunyuan runtime.
public enum USDZArchiveWriter {
    public struct Entry: Equatable, Sendable {
        public let archivePath: String
        public let sourceURL: URL

        public init(archivePath: String, sourceURL: URL) {
            self.archivePath = archivePath
            self.sourceURL = sourceURL
        }
    }

    private struct PreparedEntry {
        let nameData: Data
        let sourceURL: URL
        let byteCount: UInt32
        let crc32: UInt32
        var localHeaderOffset: UInt32 = 0
        var alignmentExtra = Data()
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let usdAlignmentExtraFieldID: UInt16 = 0x1986
    private static let versionNeeded: UInt16 = 10
    private static let versionMadeByUnix: UInt16 = 0x031e
    private static let generalPurposeFlags: UInt16 = 0
    private static let storedMethod: UInt16 = 0
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021 // 1980-01-01
    private static let alignment: UInt64 = 64
    private static let streamBufferSize = 1 * 1_024 * 1_024

    public static func write(
        entries: [Entry],
        to destination: URL,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == "usdz",
              !entries.isEmpty,
              entries.count <= Int(UInt16.max),
              Set(entries.map(\.archivePath)).count == entries.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let streamBuffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: streamBufferSize,
            alignment: 64
        )
        defer { streamBuffer.deallocate() }
        var prepared = try entries.map {
            try prepare(
                $0,
                buffer: streamBuffer,
                isCancelled: isCancelled
            )
        }
        try checkCancellation(isCancelled)

        let descriptor = destination.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw CocoaError(
                errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown
            )
        }

        let output = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        var completed = false
        defer {
            if !completed {
                try? output.close()
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var offset: UInt64 = 0
        for index in prepared.indices {
            try checkCancellation(isCancelled)
            guard offset <= UInt64(UInt32.max) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            prepared[index].localHeaderOffset = UInt32(offset)
            prepared[index].alignmentExtra = alignmentExtra(
                currentOffset: offset,
                nameLength: prepared[index].nameData.count
            )
            var header = Data()
            append(localHeaderSignature, to: &header)
            append(versionNeeded, to: &header)
            append(generalPurposeFlags, to: &header)
            append(storedMethod, to: &header)
            append(dosTime, to: &header)
            append(dosDate, to: &header)
            append(prepared[index].crc32, to: &header)
            append(prepared[index].byteCount, to: &header)
            append(prepared[index].byteCount, to: &header)
            append(UInt16(prepared[index].nameData.count), to: &header)
            append(UInt16(prepared[index].alignmentExtra.count), to: &header)
            header.append(prepared[index].nameData)
            header.append(prepared[index].alignmentExtra)
            try write(header, to: output, offset: &offset)
            guard offset.isMultiple(of: alignment) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let copied = try copyStoredFile(
                prepared[index].sourceURL,
                to: output,
                offset: &offset,
                buffer: streamBuffer,
                isCancelled: isCancelled
            )
            guard copied.byteCount == prepared[index].byteCount,
                  copied.crc32 == prepared[index].crc32 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }

        try checkCancellation(isCancelled)
        guard offset <= UInt64(UInt32.max) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let centralOffset = UInt32(offset)
        for entry in prepared {
            var header = Data()
            append(centralHeaderSignature, to: &header)
            append(versionMadeByUnix, to: &header)
            append(versionNeeded, to: &header)
            append(generalPurposeFlags, to: &header)
            append(storedMethod, to: &header)
            append(dosTime, to: &header)
            append(dosDate, to: &header)
            append(entry.crc32, to: &header)
            append(entry.byteCount, to: &header)
            append(entry.byteCount, to: &header)
            append(UInt16(entry.nameData.count), to: &header)
            append(UInt16(entry.alignmentExtra.count), to: &header)
            append(UInt16(0), to: &header) // comment length
            append(UInt16(0), to: &header) // disk number
            append(UInt16(0), to: &header) // internal attributes
            append(UInt32(0), to: &header) // external attributes
            append(entry.localHeaderOffset, to: &header)
            header.append(entry.nameData)
            header.append(entry.alignmentExtra)
            try write(header, to: output, offset: &offset)
        }
        let centralSizeValue = offset - UInt64(centralOffset)
        guard centralSizeValue <= UInt64(UInt32.max) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }

        var footer = Data()
        append(endOfCentralDirectorySignature, to: &footer)
        append(UInt16(0), to: &footer)
        append(UInt16(0), to: &footer)
        append(UInt16(prepared.count), to: &footer)
        append(UInt16(prepared.count), to: &footer)
        append(UInt32(centralSizeValue), to: &footer)
        append(centralOffset, to: &footer)
        append(UInt16(0), to: &footer)
        try write(footer, to: output, offset: &offset)
        try output.synchronize()
        try output.close()
        completed = true
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            ~updateCRC32(0xffff_ffff, with: bytes)
        }
    }

    private static func prepare(
        _ entry: Entry,
        buffer: UnsafeMutableRawBufferPointer,
        isCancelled: () -> Bool
    ) throws -> PreparedEntry {
        guard isSafeArchivePath(entry.archivePath),
              entry.archivePath.unicodeScalars.allSatisfy({ $0.value < 128 }),
              let nameData = entry.archivePath.data(using: .utf8),
              !nameData.isEmpty,
              nameData.count <= Int(UInt16.max) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let digest = try streamDigest(
            entry.sourceURL,
            buffer: buffer,
            isCancelled: isCancelled
        )
        return PreparedEntry(
            nameData: nameData,
            sourceURL: entry.sourceURL,
            byteCount: digest.byteCount,
            crc32: digest.crc32
        )
    }

    private static func alignmentExtra(
        currentOffset: UInt64,
        nameLength: Int
    ) -> Data {
        let base = currentOffset + 30 + UInt64(nameLength) + 4
        let padding = (alignment - base % alignment) % alignment

        var extra = Data()
        append(usdAlignmentExtraFieldID, to: &extra)
        append(UInt16(padding), to: &extra)
        extra.append(Data(repeating: 0, count: Int(padding)))
        return extra
    }

    private static func copyStoredFile(
        _ source: URL,
        to output: FileHandle,
        offset: inout UInt64,
        buffer: UnsafeMutableRawBufferPointer,
        isCancelled: () -> Bool
    ) throws -> (byteCount: UInt32, crc32: UInt32) {
        try streamFile(
            source,
            buffer: buffer,
            isCancelled: isCancelled
        ) { bytes in
            try write(bytes, to: output, offset: &offset)
        }
    }

    private static func streamDigest(
        _ source: URL,
        buffer: UnsafeMutableRawBufferPointer,
        isCancelled: () -> Bool
    ) throws -> (byteCount: UInt32, crc32: UInt32) {
        try streamFile(
            source,
            buffer: buffer,
            isCancelled: isCancelled
        ) { _ in }
    }

    private static func streamFile(
        _ source: URL,
        buffer: UnsafeMutableRawBufferPointer,
        isCancelled: () -> Bool,
        consume: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> (byteCount: UInt32, crc32: UInt32) {
        guard source.isFileURL,
              let baseAddress = buffer.baseAddress,
              !buffer.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let descriptor = source.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard status.st_size > 0,
              UInt64(status.st_size) <= UInt64(UInt32.max) else {
            throw CocoaError(.fileReadTooLarge)
        }

        var crc: UInt32 = 0xffff_ffff
        var total: UInt64 = 0
        while true {
            try checkCancellation(isCancelled)
            let count = Darwin.read(descriptor, baseAddress, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            let bytes = UnsafeRawBufferPointer(
                start: baseAddress,
                count: count
            )
            let (nextTotal, overflow) = total.addingReportingOverflow(
                UInt64(count)
            )
            guard !overflow, nextTotal <= UInt64(UInt32.max) else {
                throw CocoaError(.fileReadTooLarge)
            }
            crc = updateCRC32(crc, with: bytes)
            try consume(bytes)
            total = nextTotal
        }
        guard total == UInt64(status.st_size) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (UInt32(total), ~crc)
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("/")
            && !path.contains("\\")
            && !path.contains("\0")
            && path != "."
            && path != ".."
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func write(
        _ data: Data,
        to output: FileHandle,
        offset: inout UInt64
    ) throws {
        try data.withUnsafeBytes { bytes in
            try write(bytes, to: output, offset: &offset)
        }
    }

    private static func write(
        _ bytes: UnsafeRawBufferPointer,
        to output: FileHandle,
        offset: inout UInt64
    ) throws {
        let (next, overflow) = offset.addingReportingOverflow(
            UInt64(bytes.count)
        )
        guard !overflow, next <= UInt64(UInt32.max) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try writeAll(bytes, to: output.fileDescriptor)
        offset = next
    }

    private static func writeAll(
        _ bytes: UnsafeRawBufferPointer,
        to descriptor: Int32
    ) throws {
        guard var pointer = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let count = Darwin.write(descriptor, pointer, remaining)
            if count > 0 {
                pointer = pointer.advanced(by: count)
                remaining -= count
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == ENOSPC || errno == EDQUOT {
                throw CocoaError(.fileWriteOutOfSpace)
            } else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func append<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func updateCRC32(
        _ crc: UInt32,
        with bytes: UnsafeRawBufferPointer
    ) -> UInt32 {
        var value = crc
        for byte in bytes {
            let index = Int((value ^ UInt32(byte)) & 0xff)
            value = crcTable[index] ^ (value >> 8)
        }
        return value
    }

    private static let crcTable: [UInt32] = (0..<256).map { item in
        var value = UInt32(item)
        for _ in 0..<8 {
            value = value & 1 == 1
                ? 0xedb8_8320 ^ (value >> 1)
                : value >> 1
        }
        return value
    }
}
