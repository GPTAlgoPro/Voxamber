import Foundation
import XCTest
@testable import AppleSDXL

/// Tokenizer only: no CoreML models, weights, neural inference or images.
final class CLIPCanonicalTokenizerTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Vector: Decodable {
            let name: String
            let input: String
            let unpaddedIDs: [Int]
            let paddedEOSIDs: [Int]
            let paddedZeroIDs: [Int]
        }
        let cases: [Vector]
        let selectedMergeRules: Int
        let subsetVocabEntries: Int
    }

    func testOfficialExactVectorsWithBothCLIPPads() throws {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "CLIPCanonical", withExtension: nil, subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appending(path: "vectors.json")))
        XCTAssertEqual(fixture.cases.count, 11)
        for pad in ["<|endoftext|>", "!"] {
            let tokenizer = try BPETokenizer(mergesAt: directory.appending(path: "merges.txt"),
                vocabularyAt: directory.appending(path: "vocab.json"), padToken: pad)
            XCTAssertEqual(tokenizer.merges.count, fixture.selectedMergeRules)
            XCTAssertEqual(tokenizer.vocabulary.count, fixture.subsetVocabEntries)
            for vector in fixture.cases {
                XCTAssertEqual(tokenizer.tokenize(input: vector.input).tokenIDs, vector.unpaddedIDs, vector.name)
                let padded = tokenizer.tokenize(input: vector.input, minCount: 77).tokenIDs
                XCTAssertEqual(padded, pad == "!" ? vector.paddedZeroIDs : vector.paddedEOSIDs, vector.name)
                XCTAssertEqual(padded.count, 77)
            }
        }
    }

    func testPunctuationTerminatesCoreWordsInsteadOfCreatingPrefixPieces() throws {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "CLIPCanonical", withExtension: nil, subdirectory: "Fixtures"))
        let tokenizer = try BPETokenizer(mergesAt: directory.appending(path:"merges.txt"),
            vocabularyAt: directory.appending(path:"vocab.json"))
        XCTAssertEqual(tokenizer.tokenize(input: "shade,").tokenIDs,[49406,10097,267,49407])
        XCTAssertEqual(tokenizer.tokenize(input: "base,").tokenIDs,[49406,4579,267,49407])
        XCTAssertEqual(tokenizer.tokenize(input: "stem,").tokenIDs,[49406,6761,267,49407])
        XCTAssertEqual(tokenizer.tokenize(input: "bulb,").tokenIDs,[49406,22373,267,49407])
    }

    func testHashMergeRulesAndFinalLineAreNotDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let merges = directory.appending(path: "merges.txt"), vocab = directory.appending(path: "vocab.json")
        // No trailing LF on the final valid rule. Both rules begin with '#'.
        try Data("#version: 0.2\n# #\n## #</w>".utf8).write(to: merges)
        let vocabulary = ["#": 2,"#</w>": 3,"##": 4,"###</w>": 5,
                          "<|startoftext|>":49406,"<|endoftext|>":49407,"!":0]
        try JSONEncoder().encode(vocabulary).write(to: vocab)
        let tokenizer = try BPETokenizer(mergesAt: merges, vocabularyAt: vocab)
        XCTAssertEqual(tokenizer.merges.count, 2)
        XCTAssertEqual(tokenizer.tokenize(input: "###").tokenIDs,[49406,5,49407])
    }

    func testEmptyAndEmbeddedSpecialTokensHaveCanonicalBoundaries() {
        let vocab = ["<|startoftext|>":49406,"<|endoftext|>":49407,"!":0]
        let tokenizer = BPETokenizer(merges: [:], vocabulary: vocab)
        XCTAssertEqual(tokenizer.tokenize(input: "").tokenIDs,[49406,49407])
        XCTAssertEqual(tokenizer.tokenize(input:"<|startoftext|><|endoftext|>").tokenIDs,[49406,49406,49407,49407])
        let zeroPad = BPETokenizer(merges: [:], vocabulary: vocab, padToken: "!")
        XCTAssertEqual(zeroPad.tokenize(input:"",minCount:5).tokenIDs,[49406,49407,0,0,0])
    }
}
