import Foundation
import Observation
import Dispatch
import Darwin

/// Local directory events only. Call start on activation and stop on background.
/// A revision means "refresh inbox candidates", never "reload a draft/project".
@MainActor @Observable
final class SceneImportMonitor {
    private(set) var revision = 0
    private(set) var errorMessage: String?
    @ObservationIgnored private var watch: SceneImportDirectoryWatch?
    @ObservationIgnored private var wantsMonitoring = false

    func start() throws {
        wantsMonitoring = true
        guard watch == nil else { return }
        do {
            try installWatch()
            errorMessage = nil
            // Cover an entry committed between the caller's initial list and
            // attaching this watch. This is one refresh, not a polling timer.
            revision &+= 1
        } catch {
            errorMessage = "系统分享收件箱暂不可用，仍可粘贴代码或导入文件。"
            throw error
        }
    }

    func stop() {
        wantsMonitoring = false
        let previous = watch
        watch = nil // Reject old queued callbacks before requesting cancellation.
        previous?.source.cancel()
    }

    private func installWatch() throws {
        // Production Inbox establishes and validates its own fixed directories.
        _ = try SceneImportInbox.openShared()
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SceneImportInbox.appGroupID) else {
            throw SceneImportInboxError.unavailable
        }
        let directory = group.appendingPathComponent("SceneImports/Entries", isDirectory: true)
        let descriptor = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SceneImportInboxError.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw SceneImportInboxError.unsafePath
        }
        let id = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            // This source is explicitly delivered by DispatchQueue.main. Avoid
            // unowned Tasks and retain the event's source identity on this hop.
            MainActor.assumeIsolated { self?.directoryChanged(id: id) }
        }
        watch = SceneImportDirectoryWatch(id: id, source: source)
        source.resume()
    }

    private func directoryChanged(id: UUID) {
        guard wantsMonitoring, let current = watch, current.id == id else { return }
        let events = current.source.data
        if !events.intersection([.rename, .delete]).isEmpty {
            watch = nil
            current.source.cancel()
            // An invalidated directory watch cannot observe a replacement.
            // Re-establish it only while the App still requests monitoring.
            do { try installWatch(); errorMessage = nil }
            catch { errorMessage = "系统分享收件箱暂不可用，仍可粘贴代码或导入文件。" }
        }
        revision &+= 1
    }
}

/// Cancellation is safe from deinit as well; Dispatch owns the cancel handler
/// until pending callbacks settle, and only that handler closes this descriptor.
private final class SceneImportDirectoryWatch: @unchecked Sendable {
    let id: UUID
    let source: DispatchSourceFileSystemObject
    init(id: UUID, source: DispatchSourceFileSystemObject) { self.id = id; self.source = source }
    deinit { source.cancel() }
}
