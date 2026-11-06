import Foundation
import Testing
@testable import CreationCore

@Test func invalidParametersAreRejected() {
    for badValue in [Double.nan,.infinity,-.infinity,0,-1,3.01] {
        var spec=BuildingSpec.palace; spec.width=badValue
        #expect(throws:CreationError.self) { try spec.validate() }
    }
    var spec=BuildingSpec.palace; spec.floors=3; spec.roofTiers=3
    #expect(throws:CreationError.self) { try BuildingGenerator.generate(for:spec) }
    spec = .palace; spec.eaveLift=0.15
    #expect(throws:CreationError.self) { try spec.validate() }
    spec = .palace; spec.name="\n"
    #expect(throws:CreationError.self) { try spec.validate() }
    spec = .palace; spec.depth=0.3
    #expect(throws:CreationError.self) { try spec.validate() }
}

@Test func modelResponseIsAnExactWhitelistedObject() throws {
    let encoder=JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data=try encoder.encode(BuildingSpec.pavilion)
    let text=String(decoding:data,as:UTF8.self)
    #expect(try BuildingSpec.decodeModelResponse(text) == .pavilion)
    #expect(try BuildingSpec.decodeModelResponse("```json\n"+text+"\n```") == .pavilion)
    var object=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
    object["script"]="fetch('https://example.com')"
    let extra=String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
    #expect(throws:CreationError.self) { try BuildingSpec.decodeModelResponse(extra) }
    object.removeValue(forKey:"script"); object["roofColor"]="unlisted"
    let unlisted=String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
    #expect(throws:CreationError.self) { try BuildingSpec.decodeModelResponse(unlisted) }
    #expect(throws:CreationError.self) { try BuildingSpec.decodeModelResponse("Here is the JSON: "+text) }
    #expect(throws:CreationError.self) { try BuildingSpec.decodeModelResponse(String(repeating:" ",count:16_385)) }
}

@Test func promptsPreserveCurrentParametersAndBoundInput() throws {
    let text=try BuildingPrompt.userRequest("改为青瓦，保留其余设计",currentSpec:.palace)
    #expect(text.contains("\"roofTiers\":2"))
    #expect(text.contains("改为青瓦"))
    #expect(BuildingPrompt.system.contains("slate"))
    #expect(throws:CreationError.self) { try BuildingPrompt.userRequest("") }
    #expect(throws:CreationError.self) { try BuildingPrompt.userRequest(String(repeating:"a",count:2_001)) }
}

@Test func presetsAreDeterministicAndDistinct() throws {
    let palace=try BuildingGenerator.generate(for:.palace)
    #expect(palace == (try BuildingGenerator.generate(for:.palace)))
    let pavilion=try BuildingGenerator.generate(for:.pavilion)
    let tower=try BuildingGenerator.generate(for:.tower)
    #expect(palace.statistics.roofCount == 2)
    #expect(pavilion.statistics.roofCount == 1)
    #expect(tower.statistics.roofCount == 3)
    #expect(palace.statistics.columns == 16)
    #expect(pavilion.statistics.columns == 8)
    #expect(tower.statistics.columns == 36)
    #expect(palace.statistics.tileRibs >= 100)
    #expect(!pavilion.meshes.contains(where:{$0.name == "joinery"}))
    #expect(palace.meshes.contains(where:{$0.name == "curved_roof"}))
    #expect(palace.meshes.contains(where:{$0.name == "brackets_jade"}))
}

@Test func meshTopologyIsFiniteAndFitsRequestedDimensions() throws {
    for preset in BuildingSpec.presets {
        let model=try BuildingGenerator.generate(for:preset)
        let stats=model.statistics
        #expect(abs(stats.bounds.width-preset.width)<0.00002)
        #expect(abs(stats.bounds.depth-preset.depth)<0.00002)
        #expect(abs(stats.bounds.height-preset.height)<0.00002)
        #expect(stats.bounds.minimum[1] == 0)
        #expect(stats.meshes <= 11)
        #expect(stats.vertices < BuildingGenerator.maximumVertices)
        #expect(stats.bufferBytes < BuildingGenerator.maximumBufferBytes)
        #expect(stats.triangles>5_000)
        #expect(stats.vertices == model.meshes.reduce(0){$0+$1.positions.count/3})
        for mesh in model.meshes {
            #expect(mesh.positions.count == mesh.normals.count)
            #expect(mesh.positions.count%3 == 0)
            #expect(mesh.indices.count%3 == 0)
            #expect(mesh.positions.allSatisfy{$0.isFinite})
            #expect(mesh.normals.allSatisfy{$0.isFinite})
            #expect(mesh.indices.allSatisfy{Int($0)<mesh.positions.count/3})
            #expect(mesh.color.count == 3 && mesh.color.allSatisfy{(0...1).contains($0)})
            for index in stride(from:0,to:mesh.normals.count,by:3) {
                let length=sqrt(mesh.normals[index...index+2].reduce(0){$0+$1*$1})
                #expect(abs(length-1)<0.00003)
            }
            func position(_ index: UInt32) -> SIMD3<Double> {
                let i=Int(index)*3
                return .init(Double(mesh.positions[i]),Double(mesh.positions[i+1]),Double(mesh.positions[i+2]))
            }
            func normal(_ index: UInt32) -> SIMD3<Double> {
                let i=Int(index)*3
                return .init(Double(mesh.normals[i]),Double(mesh.normals[i+1]),Double(mesh.normals[i+2]))
            }
            for index in stride(from:0,to:mesh.indices.count,by:3) {
                let a=mesh.indices[index],b=mesh.indices[index+1],c=mesh.indices[index+2]
                let u=position(b)-position(a),v=position(c)-position(a)
                let cross=SIMD3<Double>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
                #expect(cross.x*cross.x+cross.y*cross.y+cross.z*cross.z > 1e-20)
                let mean=normal(a)+normal(b)+normal(c)
                #expect(cross.x*mean.x+cross.y*mean.y+cross.z*mean.z >= -1e-12)
            }
        }
    }
}

@Test func detailAndColorActuallyChangeGeometryAndMaterials() throws {
    var spec=BuildingSpec.palace
    let standard=try BuildingGenerator.generate(for:spec)
    spec.detail = .fine; spec.roofColor = .jade; spec.columnColor = .ivory
    let fine=try BuildingGenerator.generate(for:spec)
    #expect(fine.statistics.vertices>standard.statistics.vertices)
    #expect(fine.statistics.tileRibs>standard.statistics.tileRibs)
    #expect(fine.meshes.first(where:{$0.name == "curved_roof"})?.color != standard.meshes.first(where:{$0.name == "curved_roof"})?.color)
    #expect(fine.meshes.first(where:{$0.name == "columns"})?.color != standard.meshes.first(where:{$0.name == "columns"})?.color)
}

@Test func largestRoofCombinationFitsNativeBudget() throws {
    var spec=BuildingSpec.palace
    spec.floors=2; spec.roofTiers=2; spec.height=1.8; spec.detail = .fine
    let result=try BuildingGenerator.generate(for:spec)
    #expect(result.statistics.roofCount == 4)
    #expect(result.statistics.bufferBytes<=BuildingGenerator.maximumBufferBytes)
    #expect(result.statistics.vertices<=BuildingGenerator.maximumVertices)
    #expect(result.statistics.triangles*3<=BuildingGenerator.maximumIndices)
}

@Test func generationHonorsCancellation() async {
    let task=Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try BuildingGenerator.generate(for:.palace)
    }
    do { _ = try await task.value; Issue.record("Cancelled geometry generation completed") }
    catch is CancellationError { }
    catch { Issue.record("Unexpected error: \(error)") }
}
