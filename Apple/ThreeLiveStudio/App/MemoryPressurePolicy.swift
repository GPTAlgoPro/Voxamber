import Foundation
import Darwin
import os
import QwenNative

enum MemoryPressureSeverity: String, Codable, Sendable { case warning, critical }
enum MemoryPressureAction: String, Codable, Sendable { case reclaimAndContinue, unloadIdleModel, cancelAndUnload }

struct AppMemorySnapshot: Codable, Sendable, Equatable {
    let availableProcessBytes: UInt64
    let physicalFootprintBytes: UInt64
    let physicalMemoryBytes: UInt64
    let thermalState: Int
    let mlxActiveBytes: Int?
    let mlxCacheBytes: Int?

    static func current() -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Self(availableProcessBytes: UInt64(os_proc_available_memory()),
            physicalFootprintBytes: result == KERN_SUCCESS ? info.phys_footprint : 0,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            mlxActiveBytes: nil, mlxCacheBytes: nil)
    }
}

enum MemoryPressurePolicy {
    // This is process headroom reported by iOS, not total device RAM.
    static let minimumRemainingBytes: UInt64 = 128 * 1_024 * 1_024

    static func action(severity: MemoryPressureSeverity, snapshot: AppMemorySnapshot,
                       hasOwnedOperation: Bool) -> MemoryPressureAction {
        guard hasOwnedOperation else { return .unloadIdleModel }
        if severity == .critical || snapshot.availableProcessBytes <= minimumRemainingBytes {
            return .cancelAndUnload
        }
        return .reclaimAndContinue
    }
}

@MainActor
struct MemoryPressureClient {
    var snapshot: () -> AppMemorySnapshot
    var reclaimUnusedCache: () async -> QwenMemorySnapshot?

    static func system(engine: QwenEngine) -> Self {
        Self(snapshot: { AppMemorySnapshot.current() },
             reclaimUnusedCache: { await engine.reclaimUnusedCache() })
    }
}

@MainActor
final class CriticalMemoryPressureMonitor {
    private let source: any DispatchSourceMemoryPressure

    init(handler: @escaping @MainActor @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.activate()
    }

    deinit { source.cancel() }
}

struct MemoryPressureRecord: Codable {
    let time: Date
    let appBuild: String
    let severity: MemoryPressureSeverity
    let action: MemoryPressureAction
    let stage: String
    let elapsedSeconds: Double
    let hasOwnedOperation: Bool
    let before: AppMemorySnapshot
    let afterReclaim: AppMemorySnapshot
    let reclaimCompleted: Bool
    let allocatorAfterReclaim: QwenMemorySnapshot?
    let relatedOperationAlreadyEnded: Bool
}

struct MemoryBudgetRecord: Codable {
    let time: Date
    let phase: String
    let appBuild: String
    let snapshot: AppMemorySnapshot
}
