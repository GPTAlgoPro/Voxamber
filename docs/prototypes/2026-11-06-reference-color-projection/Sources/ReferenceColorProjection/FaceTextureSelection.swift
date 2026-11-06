import Foundation
import simd

struct FaceTextureSelection {
    let imageFaces:[Int]
    let neutralFaces:[Int]
    let maskRejected:Int
    let occluded:Int
    let projectedDegenerate:Int
    let pairTests:Int
}

/// Conservative whole-face selection. Material assignment separates unknown
/// faces from the image, rather than pointing unknown UVs into a gray atlas.
enum FaceTextureSelector {
    static func select(screen:[SIMD3<Double>],indices:[UInt32],reference:ReferenceRaster) throws -> FaceTextureSelection {
        try Task.checkCancellation()
        guard screen.count<=2_000_000,indices.count<=12_000_000,indices.count.isMultiple(of:3),
              screen.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.z>0 && (1/$0.z).isFinite &&
                  $0.x>=0 && $0.x<=Double(reference.width) && $0.y>=0 && $0.y<=Double(reference.height)}),
              indices.allSatisfy({Int($0)<screen.count}),reference.width>0,reference.height>0,
              reference.rgba.count==reference.width*reference.height*4 else {throw ProjectionError.invalidGeometry}
        let nx=min(reference.width,128),ny=min(reference.height,128)
        let sx=Double(nx)/Double(reference.width),sy=Double(ny)/Double(reference.height)
        let triangles=stride(from:0,to:indices.count,by:3).map {offset in
            Triangle(screen[Int(indices[offset])],screen[Int(indices[offset+1])],screen[Int(indices[offset+2])])
        }
        var bins=[[Int]](repeating:[],count:nx*ny),references=0
        func binBounds(_ triangle:Triangle)->(Int,Int,Int,Int) {
            (max(0,min(nx-1,Int(floor(triangle.low.x*sx)))),max(0,min(nx-1,Int(floor(triangle.high.x*sx)))),
             max(0,min(ny-1,Int(floor(triangle.low.y*sy)))),max(0,min(ny-1,Int(floor(triangle.high.y*sy)))))
        }
        for (index,triangle) in triangles.enumerated() where abs(triangle.area)>1e-12 {
            if index.isMultiple(of:1024) {try Task.checkCancellation()}
            let (x0,x1,y0,y1)=binBounds(triangle)
            for y in y0...y1 {for x in x0...x1 {bins[y*nx+x].append(index);references+=1}}
            guard references<=8_000_000 else {throw ProjectionError.invalidGeometry}
        }
        var image:[Int]=[],neutral:[Int]=[],maskRejected=0,occluded=0,degenerate=0,pairs=0
        for (face,triangle) in triangles.enumerated() {
            if face.isMultiple(of:256) {try Task.checkCancellation()}
            guard abs(triangle.area)>1e-12 else {neutral.append(face);degenerate+=1;continue}
            guard coversBilinearFootprint(triangle,reference:reference) else {neutral.append(face);maskRejected+=1;continue}
            let (x0,x1,y0,y1)=binBounds(triangle)
            var candidates=Set<Int>()
            for y in y0...y1 {for x in x0...x1 {candidates.formUnion(bins[y*nx+x])}}
            var hidden=false
            for other in candidates where other != face {
                pairs+=1
                if pairs.isMultiple(of:4096) {try Task.checkCancellation()}
                guard pairs<=200_000_000 else {throw ProjectionError.invalidGeometry}
                let blocker=triangles[other]
                guard triangle.low.x<=blocker.high.x,triangle.high.x>=blocker.low.x,
                      triangle.low.y<=blocker.high.y,triangle.high.y>=blocker.low.y else {continue}
                let intersection=clip(triangle.xy,against:blocker.xy)
                let overlapArea=abs(polygonArea(intersection))
                guard overlapArea>max(1e-10,abs(triangle.area)*1e-12) else {continue}
                // Inverse camera depth is affine over a projected planar
                // triangle. A positive difference at any intersection vertex
                // means that an interior region is hidden; reject the full face.
                if intersection.contains(where:{point in
                    let target=triangle.inverseDepth(point),front=blocker.inverseDepth(point)
                    return front-target>max(1e-12,abs(target)*Double.ulpOfOne*128)
                }) {hidden=true;break}
            }
            if hidden {neutral.append(face);occluded+=1}else{image.append(face)}
        }
        return .init(imageFaces:image,neutralFaces:neutral,maskRejected:maskRejected,occluded:occluded,
                     projectedDegenerate:degenerate,pairTests:pairs)
    }

    /// A bounding rectangle plus one texel for bilinear filtering is deliberately
    /// stricter than checking only triangle corners. It can reject a valid face;
    /// it cannot classify an alpha hole inside that rectangle as covered.
    private static func coversBilinearFootprint(_ triangle:Triangle,reference:ReferenceRaster)->Bool {
        let x0=Int(floor(triangle.low.x-0.5)),x1=Int(floor(triangle.high.x-0.5))+1
        let y0=Int(floor(triangle.low.y-0.5)),y1=Int(floor(triangle.high.y-0.5))+1
        guard x0>=0,y0>=0,x1<reference.width,y1<reference.height else {return false}
        for y in y0...y1 {for x in x0...x1 {
            let row=reference.height-y-1
            if reference.rgba[(row*reference.width+x)*4+3]<254{return false}
        }}
        return true
    }

    private struct Triangle {
        let p:[SIMD3<Double>]
        let xy:[SIMD2<Double>]
        let area:Double
        let low:SIMD2<Double>,high:SIMD2<Double>
        init(_ a:SIMD3<Double>,_ b:SIMD3<Double>,_ c:SIMD3<Double>) {
            p=[a,b,c];xy=[SIMD2(a.x,a.y),SIMD2(b.x,b.y),SIMD2(c.x,c.y)]
            area=FaceTextureSelector.edge(xy[0],xy[1],xy[2])
            low=simd_min(xy[0],simd_min(xy[1],xy[2]));high=simd_max(xy[0],simd_max(xy[1],xy[2]))
        }
        func inverseDepth(_ point:SIMD2<Double>)->Double {
            let a=FaceTextureSelector.edge(xy[1],xy[2],point)/area
            let b=FaceTextureSelector.edge(xy[2],xy[0],point)/area
            return a/p[0].z+b/p[1].z+(1-a-b)/p[2].z
        }
    }

    private static func edge(_ a:SIMD2<Double>,_ b:SIMD2<Double>,_ p:SIMD2<Double>)->Double {
        (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
    }
    private static func polygonArea(_ polygon:[SIMD2<Double>])->Double {
        guard polygon.count>=3 else{return 0}
        return polygon.indices.reduce(0){sum,index in
            let a=polygon[index],b=polygon[(index+1)%polygon.count];return sum+a.x*b.y-a.y*b.x
        }/2
    }
    private static func clip(_ polygon:[SIMD2<Double>],against triangle:[SIMD2<Double>])->[SIMD2<Double>] {
        let orientation=edge(triangle[0],triangle[1],triangle[2])>=0 ? 1.0 : -1.0
        var result=polygon
        for i in 0..<3 {
            let input=result;result=[]
            guard !input.isEmpty else {return []}
            let a=triangle[i],b=triangle[(i+1)%3]
            for j in input.indices {
                let previous=input[(j+input.count-1)%input.count],current=input[j]
                let d0=edge(a,b,previous)*orientation,d1=edge(a,b,current)*orientation
                let inside0=d0 >= -1e-10,inside1=d1 >= -1e-10
                if inside0 != inside1 {
                    let denominator=d0-d1
                    if abs(denominator)>Double.leastNormalMagnitude {
                        result.append(previous+(current-previous)*(d0/denominator))
                    }
                }
                if inside1 {result.append(current)}
            }
        }
        return result
    }
}
