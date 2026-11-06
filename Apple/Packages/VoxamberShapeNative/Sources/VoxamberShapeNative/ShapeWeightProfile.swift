import Foundation
import VoxamberHy3D

/// Explicit container identities. The rebuilt candidate was verified against
/// the fixed FP16 sources/MLX0.31.4 recipe; it is not claimed equal to legacy69.
public enum HunyuanShape21WeightProfile: String, Codable, Sendable, CaseIterable {
    case legacySnapQ4 = "snap-q4-69cd908e"
    case rebuiltQ4Candidate = "native-rebuild-20261106-q4-30b93ce8"

    public var modelPackBytes: Int64 {
        switch self {
        case .legacySnapQ4: HunyuanShape21Configuration.modelPackBytes
        case .rebuiltQ4Candidate: 2_490_378_518
        }
    }
    public var modelPackSHA256: String {
        switch self {
        case .legacySnapQ4: HunyuanShape21Configuration.modelPackSHA256
        case .rebuiltQ4Candidate: "30b93ce8a801551b905c35d1203d71d947a6b35b3d271aa5820b11d40faf45c7"
        }
    }
    /// Local pack recipe/container revision, never an upstream HF commit.
    public var packRevision: String {
        switch self {
        case .legacySnapQ4: "snap-pack-20260830-q4-69cd908e"
        case .rebuiltQ4Candidate: "voxamber-rebuild-20261106-q4-30b93ce8"
        }
    }
    public var sourceTensorRevision: String? {
        switch self {
        case .legacySnapQ4: nil // Old header/payload is unavailable; do not retrofit new proof.
        case .rebuiltQ4Candidate: "6bb9063eda419c4024a63f72507122339f69c2a1"
        }
    }
    public var sourceRecipeTensorParityVerified: Bool { self == .rebuiltQ4Candidate }
    /// No profile has completed the current SDK's 12GB iPhone acceptance gate.
    public var deviceProfileValidated: Bool { false }
    var geometryCleanupPolicy: MeshCleanupPolicy {
        self == .rebuiltQ4Candidate ? .finitePositiveAreaFloat64 : .legacyThreshold
    }
    public var geometryPostprocessID: String { geometryCleanupPolicy.rawValue }

    func validateFingerprint(byteCount: Int64, sha256: String) throws {
        guard byteCount == modelPackBytes, sha256 == modelPackSHA256 else { throw ShapeError.modelMismatch }
    }
}
