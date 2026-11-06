import Foundation
import CryptoKit

public enum SceneImportInboxError: Error, Equatable, Sendable {
    case unavailable, unsafePath, invalidEntry, invalidUTF8, emptyInput, tooLarge, notFound
}

public struct SceneImportInboxItem: Codable, Sendable, Equatable, Identifiable {
    public let formatVersion: Int
    public let id: UUID
    public let receivedAt: Date
    public let byteCount: Int
    public let sha256: String
    /// Display metadata only. Never used as a filesystem path.
    public let originalFilename: String?
}

public struct SceneImportInboxPayload: Sendable {
    public let item: SceneImportInboxItem
    public let bytes: Data
}

public struct SceneImportInboxListing: Sendable {
    public let pending: [SceneImportInboxItem]
    /// Unknown/corrupt entries are preserved, not deleted or silently imported.
    public let unreadableEntryCount: Int
}

/// Shared by the App and Share Extension. No compiler, network or project-store
/// dependency. Published entries are immutable and acknowledged entries remain.
public actor SceneImportInbox {
    public static let appGroupID = "group.com.kaisun.voxamber.background-assets"
    public static let maximumBytes = 4 * 1_024 * 1_024
    private let root: URL
    private let entries: URL
    private let processed: URL

    public static func openShared() throws -> SceneImportInbox {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw SceneImportInboxError.unavailable
        }
        return try SceneImportInbox(rootURL: group.appendingPathComponent("SceneImports", isDirectory: true))
    }

    /// An explicit root is also useful for isolated filesystem validation.
    public init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw SceneImportInboxError.unsafePath }
        root = rootURL.standardizedFileURL
        entries = root.appendingPathComponent("Entries", isDirectory: true)
        processed = root.appendingPathComponent("Processed", isDirectory: true)
        try Self.ensureDirectory(root)
        try Self.ensureDirectory(entries)
        try Self.ensureDirectory(processed)
    }

    public func store(bytes: Data, originalFilename: String? = nil) throws -> SceneImportInboxItem {
        try Task.checkCancellation()
        try Self.validatePayload(bytes)
        let id = UUID()
        let item = SceneImportInboxItem(formatVersion: 1, id: id, receivedAt: Date(), byteCount: bytes.count,
            sha256: Self.digest(bytes), originalFilename: Self.displayFilename(originalFilename))
        let staging = root.appendingPathComponent(".staging-" + id.uuidString, isDirectory: true)
        let destination = entries.appendingPathComponent(id.uuidString, isDirectory: true)
        try Self.ensureDirectory(staging)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }
        try Self.write(bytes, to: staging.appendingPathComponent("payload"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.write(encoder.encode(item), to: staging.appendingPathComponent("entry.json"))
        _ = try read(in: staging, expectedID: id)
        try Task.checkCancellation()
        try Self.checkDirectory(entries)
        // Same-container directory rename is the publication point. Once it
        // wins, late cancellation must not relabel a saved item as unsaved.
        try FileManager.default.moveItem(at: staging, to: destination)
        committed = true
        return item
    }

    public func list() throws -> SceneImportInboxListing {
        try Task.checkCancellation(); try Self.checkDirectory(entries)
        let candidates = try FileManager.default.contentsOfDirectory(at: entries,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var pending: [SceneImportInboxItem] = [], unreadable = 0
        for directory in candidates {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: directory.lastPathComponent) else { unreadable += 1; continue }
            do { pending.append(try metadata(in: directory, expectedID: id)) }
            catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
        }
        pending.sort { $0.receivedAt == $1.receivedAt ? $0.id.uuidString < $1.id.uuidString : $0.receivedAt > $1.receivedAt }
        return SceneImportInboxListing(pending: pending, unreadableEntryCount: unreadable)
    }

    public func inspect(entryID: UUID) throws -> SceneImportInboxItem { try read(entryID: entryID).item }

    public func read(entryID: UUID) throws -> SceneImportInboxPayload {
        let pending = entries.appendingPathComponent(entryID.uuidString, isDirectory: true)
        let acknowledged = processed.appendingPathComponent(entryID.uuidString, isDirectory: true)
        do { return try read(in: pending, expectedID: entryID) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // An App/extension in another process may have acknowledged the
            // immutable entry between lookup and open. No entry is recreated.
            guard FileManager.default.fileExists(atPath: acknowledged.path) else { throw error }
            return try read(in: acknowledged, expectedID: entryID)
        }
    }

    public func acknowledge(entryID: UUID) throws {
        try Task.checkCancellation(); try Self.checkDirectory(entries); try Self.checkDirectory(processed)
        let source = entries.appendingPathComponent(entryID.uuidString, isDirectory: true)
        let destination = processed.appendingPathComponent(entryID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard !FileManager.default.fileExists(atPath: source.path) else { throw SceneImportInboxError.invalidEntry }
            _ = try read(in: destination, expectedID: entryID)
            return
        }
        do {
            _ = try read(in: source, expectedID: entryID)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: source, to: destination)
        }
        catch {
            // Another App process may win the same acknowledgement. It is
            // idempotent only if the original is gone and the saved entry verifies.
            guard !FileManager.default.fileExists(atPath: source.path),
                  FileManager.default.fileExists(atPath: destination.path) else { throw error }
            _ = try read(in: destination, expectedID: entryID)
        }
    }

    private func metadata(in directory: URL, expectedID: UUID) throws -> SceneImportInboxItem {
        try Self.checkDirectory(directory)
        let data = try Self.readBounded(directory.appendingPathComponent("entry.json"), limit: 64 * 1_024)
        let item = try JSONDecoder().decode(SceneImportInboxItem.self, from: data)
        guard item.formatVersion == 1, item.id == expectedID, item.receivedAt.timeIntervalSince1970.isFinite,
              (1...Self.maximumBytes).contains(item.byteCount), item.sha256.utf8.count == 64,
              item.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              item.originalFilename == Self.displayFilename(item.originalFilename) else { throw SceneImportInboxError.invalidEntry }
        return item
    }

    private func read(in directory: URL, expectedID: UUID) throws -> SceneImportInboxPayload {
        try Task.checkCancellation()
        let item = try metadata(in: directory, expectedID: expectedID)
        let bytes = try Self.readBounded(directory.appendingPathComponent("payload"), limit: Self.maximumBytes)
        try Self.validatePayload(bytes)
        guard bytes.count == item.byteCount, Self.digest(bytes) == item.sha256 else { throw SceneImportInboxError.invalidEntry }
        return SceneImportInboxPayload(item: item, bytes: bytes)
    }

    private static func validatePayload(_ bytes: Data) throws {
        guard !bytes.isEmpty else { throw SceneImportInboxError.emptyInput }
        guard bytes.count <= maximumBytes else { throw SceneImportInboxError.tooLarge }
        guard String(data: bytes, encoding: .utf8) != nil else { throw SceneImportInboxError.invalidUTF8 }
    }

    private static func displayFilename(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 255, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func ensureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
        }
        try checkDirectory(url)
    }

    private static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw SceneImportInboxError.unsafePath }
    }

    private static func write(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    private static func readBounded(_ url: URL, limit: Int) throws -> Data {
        try Task.checkCancellation()
        let before = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard before.isRegularFile == true, before.isSymbolicLink != true, let size = before.fileSize,
              size > 0, size <= limit else { throw SceneImportInboxError.invalidEntry }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var data = Data(); data.reserveCapacity(size)
        while true {
            try Task.checkCancellation()
            guard let part = try file.read(upToCount: min(65_536, limit + 1 - data.count)), !part.isEmpty else { break }
            data.append(part)
            guard data.count <= limit else { throw SceneImportInboxError.tooLarge }
        }
        let after = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard data.count == size, after.isRegularFile == true, after.isSymbolicLink != true,
              after.fileSize == size, after.contentModificationDate == before.contentModificationDate else { throw SceneImportInboxError.invalidEntry }
        return data
    }
}
