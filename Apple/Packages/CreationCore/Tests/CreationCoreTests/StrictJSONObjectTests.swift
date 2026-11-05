import Foundation
import Testing
@testable import CreationCore

@Test func duplicateKeysAreRejectedBeforeFoundationCollapsesThem() {
    for text in [
        #"{"width":1,"width":2}"#,
        #"{"color":"red","\u0063olor":"blue"}"#,
        #"{"nodes":[{"id":"a","id":"b"}]}"#,
        #"{"a":{"b":1,"b":2}}"#,
    ] {
        #expect(throws: CreationError.self) { try StrictJSONObject.decode(text) }
    }
}

@Test func independentObjectsAndEscapedStringContentsRemainValid() throws {
    let value = try StrictJSONObject.decode(#"{"nodes":[{"id":"a"},{"id":"b"}],"name":"quote: \"a\", braces { } and backslash \\"}"#)
    #expect((value["nodes"] as? [[String: String]])?.count == 2)
    #expect(value["name"] is String)
}

@Test func topLevelFragmentsAndExtraObjectsAreRejected() {
    for text in ["[]", "null", #"{"a":1} {"b":2}"#] {
        #expect(throws: CreationError.self) { try StrictJSONObject.decode(text) }
    }
    #expect(throws: CreationError.self) { try StrictJSONObject.decode(#"{"a":123}"#, maximumBytes: 3) }
}
