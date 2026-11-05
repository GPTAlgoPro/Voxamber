import CryptoKit
import Foundation

/// Host-only Foundation check of the App's exact Codable pin projection. No
/// model, MLX/Core ML/Metal framework or app target is imported or initialized.
private struct FilePin: Codable {
    let path: String
    let byteCount: Int64
    let sha256: String
    let sourceURL: URL?
}
private struct Contract: Decodable {
    struct Apple: Decodable { let assetPackID: String; let modelRootRelativePath: String }
    let formatVersion: Int
    let group: String
    let id: String
    let files: [FilePin]
    let apple: Apple

    var pinIdentity: String {
        get throws {
            struct Pins: Encodable {
                let formatVersion: Int; let group: String; let id: String; let files: [FilePin]
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Pins(formatVersion: formatVersion, group: group, id: id,
                files: files.sorted { $0.path < $1.path }))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

@main private enum VerifyNeuralContracts {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 6 else { throw CocoaError(.fileReadInvalidFileName) }
        var rows: [[String: Any]] = []
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let source = try JSONDecoder().decode(Contract.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[index])))
            let payloadData = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            let payload = try JSONDecoder().decode(Contract.self, from: payloadData)
            let object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            let packaging = object?["packaging"] as? [String: Any]
            let sourceIdentity = try source.pinIdentity
            guard try payload.pinIdentity == sourceIdentity,
                  source.apple.assetPackID == payload.apple.assetPackID,
                  source.apple.modelRootRelativePath == payload.apple.modelRootRelativePath,
                  packaging?["modelPinIdentitySHA256"] as? String == sourceIdentity else {
                throw CocoaError(.fileReadCorruptFile)
            }
            rows.append(["group": source.group, "modelID": source.id,
                "nativeCodablePinIdentitySHA256": sourceIdentity, "sourceAndPayloadContractMatch": true])
        }
        let record: [String: Any] = ["schemaVersion": 1, "nativeFoundationCheck": true,
            "modelRuntimeInitialized": false, "packs": rows]
        let output = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data([10]))
    }
}
