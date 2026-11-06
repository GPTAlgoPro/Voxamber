import Foundation
import XCTest
@testable import VoxamberShapeNative

final class ShapeWeightProfileTests: XCTestCase {
    func testExplicitProfilesKeepLegacyIdentityAndSeparateCandidateRevision() throws {
        let legacy = HunyuanShape21WeightProfile.legacySnapQ4
        let candidate = HunyuanShape21WeightProfile.rebuiltQ4Candidate
        XCTAssertEqual(ShapeEngine().weightProfile, legacy)
        XCTAssertEqual(ShapeEngine(weightProfile: candidate).weightProfile, candidate)
        XCTAssertEqual(legacy.modelPackBytes, 2_490_378_616)
        XCTAssertEqual(legacy.modelPackSHA256, "69cd908e83bbf51200c63a2a163e2dfd34d2be0571c33b92f4a922489c564842")
        XCTAssertEqual(candidate.modelPackBytes, 2_490_378_518)
        XCTAssertEqual(candidate.modelPackSHA256, "30b93ce8a801551b905c35d1203d71d947a6b35b3d271aa5820b11d40faf45c7")
        XCTAssertEqual(candidate.sourceTensorRevision, "6bb9063eda419c4024a63f72507122339f69c2a1")
        XCTAssertNotEqual(candidate.packRevision, candidate.sourceTensorRevision)
        XCTAssertNotEqual(candidate.packRevision, HunyuanShape21Configuration.modelSourceRevision)
        XCTAssertNil(legacy.sourceTensorRevision)
        XCTAssertFalse(legacy.sourceRecipeTensorParityVerified)
        XCTAssertTrue(candidate.sourceRecipeTensorParityVerified)
        XCTAssertTrue(HunyuanShape21WeightProfile.allCases.allSatisfy { !$0.deviceProfileValidated })
        XCTAssertEqual(legacy.geometryPostprocessID,"legacy-eps1e-16-v1")
        XCTAssertEqual(candidate.geometryPostprocessID,"finite-positive-f64-v1")
        XCTAssertEqual(HunyuanShape21Configuration.minimumAvailableProcessBytes, 11 * 1_073_741_824 / 2)
    }

    func testCrossProfileAndMixedFingerprintsReject() throws {
        let legacy = HunyuanShape21WeightProfile.legacySnapQ4
        let candidate = HunyuanShape21WeightProfile.rebuiltQ4Candidate
        for profile in HunyuanShape21WeightProfile.allCases {
            try profile.validateFingerprint(byteCount: profile.modelPackBytes, sha256: profile.modelPackSHA256)
            let other: HunyuanShape21WeightProfile = profile == legacy ? candidate : legacy
            XCTAssertThrowsError(try profile.validateFingerprint(byteCount: other.modelPackBytes, sha256: other.modelPackSHA256))
            XCTAssertThrowsError(try profile.validateFingerprint(byteCount: profile.modelPackBytes, sha256: other.modelPackSHA256))
            XCTAssertThrowsError(try profile.validateFingerprint(byteCount: other.modelPackBytes, sha256: profile.modelPackSHA256))
        }
    }

    func testCandidateFingerprintMismatchDoesNotNeedModelOrGPU() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "not-a-model.safetensors")
        try Data(repeating: 1, count: 16).write(to: file)
        for profile in HunyuanShape21WeightProfile.allCases {
            XCTAssertThrowsError(try ShapePackVerifier.preflight(file, profile: profile))
            XCTAssertThrowsError(try ShapePackVerifier.verify(file, profile: profile, cancellation: .init()))
        }
    }

    func testPostprocessProvenanceIsSeparateFromYAMLAndOlderJSONStillDecodes() throws {
        let profile=HunyuanShape21WeightProfile.rebuiltQ4Candidate
        let value=ShapeProvenance(modelID:HunyuanShape21Configuration.modelID,
            modelSourceRevision:HunyuanShape21Configuration.modelSourceRevision,
            modelPackSHA256:profile.modelPackSHA256,configurationSHA256:HunyuanShape21Configuration.configurationSHA256,
            inputPNG_SHA256:String(repeating:"0",count:64),seed:24301,steps:10,octreeResolution:192,latentCount:4096,
            runtimeMLXVersion:"0.32.3",physicalScaleKnown:false,weightParityWithOriginalRuntimeVerified:false,
            modelPackProfileID:profile.rawValue,modelPackRevision:profile.packRevision,
            sourceTensorRevision:profile.sourceTensorRevision,sourceRecipeTensorParityVerified:true,deviceProfileValidated:false,
            geometryPostprocessID:profile.geometryPostprocessID)
        let data=try JSONEncoder().encode(value)
        let restored=try JSONDecoder().decode(ShapeProvenance.self,from:data)
        XCTAssertEqual(restored.geometryPostprocessID,"finite-positive-f64-v1")
        XCTAssertEqual(restored.configurationSHA256,"a9e9b66f0163a9b827d730633ac88f47fcc8e3071dcbb9ee12d88ef7537c5c6e")
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);old.removeValue(forKey:"geometryPostprocessID")
        let legacyJSON=try JSONSerialization.data(withJSONObject:old)
        XCTAssertNil(try JSONDecoder().decode(ShapeProvenance.self,from:legacyJSON).geometryPostprocessID)
    }
}
