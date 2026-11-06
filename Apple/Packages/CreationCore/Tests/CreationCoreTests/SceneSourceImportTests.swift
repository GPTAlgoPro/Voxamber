import Foundation
import Testing
@testable import CreationCore

@Suite struct SceneSourceImportTests {
    @Test func rawJavaScriptAndInvalidSyntaxArePreservedWithoutAWhitelistOrRepair() throws {
        for source in [
            "  const 曲面 = (u, v) => Math.sin(u * v);\nfor (let i=0;i<12;i++) { /* any subject */ }\n",
            "const shape = new THREE.CSG.union(left, right);\n",
            "scene.add(new THREE.Mesh(",
        ] {
            let value = try SceneSourceImport.parse(source)
            #expect(value.source == source && value.original == source)
            #expect(value.originalData == Data(source.utf8))
            #expect(value.format == .rawJavaScript && value.provenance.containers.isEmpty)
            #expect(value.provenance.sourceUTF8Offset == 0 && value.provenance.sourceUTF8Length == source.utf8.count)
        }
    }

    @Test func explicitJavaScriptHintDoesNotInterpretHTMLOrFencesInsideCode() throws {
        let source = "/*\n```javascript\nnot a wrapper\n```\n*/\nconst html = '<script type=\"text/three\">literal</script>';\n"
        let value = try SceneSourceImport.parse(source, hint: .rawJavaScript)
        #expect(value.source == source && value.format == .rawJavaScript)
        let string = "const text = '<script src=\"external.js\"></script>';"
        #expect(try SceneSourceImport.parse(string).source == string)
    }

    @Test func oneFenceInAChatRetainsOriginalAndExactCRLFBodyAndByteOffset() throws {
        let prefix = "下面是代码，原文应保留。\r\n```javascript\r\n"
        let body = "  const 名称 = '模型';\r\nscene.add(thing);\r\n"
        let original = prefix + body + "```\r\n以上代码可导入。"
        let value = try SceneSourceImport.parse(Data(original.utf8))
        #expect(value.original == original && value.originalData == Data(original.utf8))
        #expect(value.source == body && value.format == .codeFence)
        #expect(value.provenance.sourceUTF8Offset == prefix.utf8.count)
        #expect(value.provenance.sourceUTF8Length == body.utf8.count)
        #expect(value.provenance.codeFenceInfo == "javascript")
        let range = value.provenance.sourceUTF8Offset..<(value.provenance.sourceUTF8Offset + value.provenance.sourceUTF8Length)
        #expect(value.originalData.subdata(in: range) == Data(value.source.utf8))
    }

    @Test func longBacktickAndTildeFencesAreFormattingOnly() throws {
        let body = "/*\n```\nliteral shorter delimiter\n```\n*/\nscene.add(mesh);\n"
        #expect(try SceneSourceImport.parse("````javascript\n" + body + "````").source == body)
        #expect(try SceneSourceImport.parse("~~~js\nscene.add(mesh);\n~~~").source == "scene.add(mesh);\n")
        // A label is provenance, not a parser for a subset of JavaScript.
        #expect(try SceneSourceImport.parse("```custom-label\nsource();\n```").provenance.codeFenceInfo == "custom-label")
    }

    @Test func multipleCodeBlocksNeverSilentlyChooseTheFirstOrConcatenate() {
        error(.ambiguousSources(2), "```js\na();\n```\nnotes\n```js\nb();\n```")
        error(.ambiguousSources(2), "```json\n{}\n```\n```javascript\nscene.add(mesh);\n```")
        error(.unterminatedCodeFence, "```javascript\nscene.add(mesh);")
    }

    @Test func explicitTextThreeWithQuotedAttributesAndHTMLCasePreservesBody() throws {
        let body = "\r\nconst 名称 = '<not-a-tag>';\r\nscene.add(mesh);\r\n"
        let original = "<SCRIPT data-label=\"a>b\" TYPE = 'TEXT/THREE'>" + body + "</ScRiPt >"
        let value = try SceneSourceImport.parse(original)
        #expect(value.source == body && value.format == .textThreeScript)
        #expect(value.provenance.containers == [.textThreeScript])
        #expect(value.originalData.subdata(in: value.provenance.sourceUTF8Offset..<(value.provenance.sourceUTF8Offset + value.provenance.sourceUTF8Length)) == Data(body.utf8))
        #expect(try SceneSourceImport.parse("<script type=text/three>mesh();</script>").source == "mesh();")
    }

    @Test func HTMLCommentsAttributesAndInnerMarkdownAreNotExtraExecutableContainers() throws {
        let body = "/*\n```js\nnot a Markdown import\n```\n*/\nscene.add(mesh);"
        let html = "<!-- <script>not code</script> -->\n<html><body title='<script>literal'>\n<script type=\"text/three\">" + body + "</script></body></html>"
        let value = try SceneSourceImport.parse(html)
        #expect(value.source == body && value.provenance.containers == [.textThreeScript])
        #expect(try SceneSourceImport.parse("<script type='text/three'>const s='</script-not>'; mesh();</script>").source == "const s='</script-not>'; mesh();")
    }

    @Test func HTMLInsideOneFenceRecordsBothWrapperLayers() throws {
        let raw = "LLM explanation\n```html\n<script type=\"text/three\">\nscene.add(mesh);\n</script>\n```\nend"
        let value = try SceneSourceImport.parse(raw)
        #expect(value.original == raw && value.source == "\nscene.add(mesh);\n")
        #expect(value.format == .textThreeScript)
        #expect(value.provenance.containers == [.codeFence, .textThreeScript])
        #expect(value.provenance.codeFenceInfo == "html")
    }

    @Test func literalScriptInTextareaOrStyleIsNotSelectedAndTaggedChatCanStillContainOneFence() throws {
        let html = "<html><textarea><script type='text/three'>notSelected();</script></textarea><style>p::after { content: '<script>'; }</style><script type='text/three'>selected();</script></html>"
        #expect(try SceneSourceImport.parse(html).source == "selected();")
        error(.unsupportedHTMLScript, "<textarea><script type='text/three'>notSelected();</script></textarea>")
        #expect(try SceneSourceImport.parse("<think>reasoning prose</think>\n```js\nmesh();\n```").source == "mesh();\n")
    }

    @Test func HTMLClassicModuleExternalAndDuplicateTypeAreRejected() {
        for html in ["<script>scene.add(mesh);</script>", "<script type='module'>scene.add(mesh);</script>",
                     "<script type='text/three' src='external.js'>scene.add(mesh);</script>",
                     "<script type='text/three' src>scene.add(mesh);</script>", "<div>No scene script</div>"] {
            error(.unsupportedHTMLScript, html)
        }
        error(.malformedHTML, "<script type='text/three' TYPE='module'>scene.add(mesh);</script>")
        error(.malformedHTML, "<script type='text/three'>scene.add(mesh);")
        error(.malformedHTML, "<script type='text/three' />")
        error(.malformedHTML, "<!-- unterminated")
    }

    @Test func multipleHTMLScriptsAreAmbiguousEvenIfOneHasTheRightType() {
        error(.ambiguousSources(2), "<script type='text/three'>a();</script><script type='text/three'>b();</script>")
        error(.ambiguousSources(2), "<html><script src='other.js'></script><script type='text/three'>a();</script></html>")
    }

    @Test func invalidUTF8AndNULAnywhereInRawInputAreRejected() {
        for data in [Data([255]), Data([192,175]), Data([226,130])] { error(.invalidUTF8, data) }
        error(.containsNUL, "const x='\0';", hint: .rawJavaScript)
        error(.containsNUL, "text\0\n```js\nmesh();\n```")
    }

    @Test func emptyContainersNeverCreateDefaultGeometry() {
        for raw in ["", " \r\n\t", "```js\n \n```", "<script type='text/three'>\n\t</script>"] { error(.emptySource, raw) }
    }

    @Test func sourceLimitUsesActualUTF8BytesAndIncludesPreservedWhitespace() throws {
        let exact = String(repeating: "x", count: SceneSourceImport.maximumSourceBytes)
        #expect(try SceneSourceImport.parse(exact, hint: .rawJavaScript).source.utf8.count == 1_048_576)
        error(.sourceTooLarge, exact + " ", hint: .rawJavaScript)
        let multibyte = String(repeating: "猫", count: SceneSourceImport.maximumSourceBytes / 3 + 1)
        #expect(multibyte.count < SceneSourceImport.maximumSourceBytes)
        error(.sourceTooLarge, multibyte)
    }

    @Test func rawCapIsSeparateFromTheSmallExtractedSource() throws {
        let suffix = "\n```js\nx\n```"
        let exact = String(repeating: "p", count: SceneSourceImport.maximumRawBytes - suffix.utf8.count) + suffix
        let value = try SceneSourceImport.parse(exact)
        #expect(value.originalData.count == 4_194_304 && value.source == "x\n")
        error(.rawInputTooLarge, exact + "p")
    }

    @Test func UTF8BOMOriginalBytesStayExactAndWrapperOffsetsStillReferToOriginal() throws {
        let bom = Data([239,187,191]), raw = bom + Data("scene.add(mesh);".utf8)
        let direct = try SceneSourceImport.parse(raw, hint: .rawJavaScript)
        #expect(direct.originalData == raw && Data(direct.source.utf8) == raw)
        let wrapped = bom + Data("```js\nmesh();\n```".utf8)
        let value = try SceneSourceImport.parse(wrapped)
        #expect(value.originalData == wrapped && value.source == "mesh();\n" && value.format == .codeFence)
        #expect(value.provenance.sourceUTF8Offset == 9)
    }

    private func error(_ expected: SceneSourceImportError, _ text: String, hint: SceneSourceImportHint = .automatic) {
        error(expected, Data(text.utf8), hint: hint)
    }
    private func error(_ expected: SceneSourceImportError, _ data: Data, hint: SceneSourceImportHint = .automatic) {
        do { _ = try SceneSourceImport.parse(data, hint: hint); Issue.record("Expected source-import rejection: \(expected)") }
        catch { #expect(error as? SceneSourceImportError == expected) }
    }
}
