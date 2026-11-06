import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import simd

struct ReferenceRaster {
    let width: Int, height: Int
    /// Premultiplied encoded sRGB RGBA8; rows begin at the image top.
    let rgba: [UInt8]
    init(png: Data) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width <= 4096, image.height <= 4096 else { throw ProjectionError.invalidImage }
        width = image.width; height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(CIImage(cgImage: image),
            toBitmap: &bytes, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        rgba = bytes
    }
    init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width; self.height = height; self.rgba = rgba
    }
    var foregroundBounds: CGRect? {
        var x0 = width, x1 = -1, row0 = height, row1 = -1
        for row in 0..<height {
            for x in 0..<width where rgba[(row * width + x) * 4 + 3] >= 128 {
                x0 = min(x0,x); x1 = max(x1,x); row0 = min(row0,row); row1 = max(row1,row)
            }
        }
        guard x1 >= x0, row1 >= row0 else { return nil }
        return CGRect(x: x0, y: height - row1 - 1, width: x1 - x0 + 1, height: row1 - row0 + 1)
    }
    func linearColor(x: Double, y: Double) -> SIMD4<Float>? {
        let sx = x - 0.5, sy = Double(height) - y - 0.5
        guard sx >= 0, sy >= 0, sx < Double(width-1), sy < Double(height-1) else { return nil }
        let ix = Int(floor(sx)), iy = Int(floor(sy)), tx = sx - floor(sx), ty = sy - floor(sy)
        var color = SIMD4<Double>(repeating: 0)
        for (dx,dy,weight) in [(0,0,(1-tx)*(1-ty)),(1,0,tx*(1-ty)),(0,1,(1-tx)*ty),(1,1,tx*ty)] {
            let index = ((iy+dy)*width+ix+dx)*4
            for c in 0..<4 { color[c] += Double(rgba[index+c]) / 255 * weight }
        }
        guard color.w >= 0.7 else { return nil }
        let rgb = (0..<3).map { Self.sRGBToLinear(min(1,max(0,color[$0] / color.w))) }
        return SIMD4(Float(rgb[0]),Float(rgb[1]),Float(rgb[2]),1)
    }
    static func sRGBToLinear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
}

struct ProjectionResult {
    let screenVertices: [SIMD3<Double>]
    let colors: [SIMD4<Float>]
    let coloredVertices: Int
    let frontVisibleVertices: Int
    let occupiedDepthPixels: Int
    let referenceBounds: CGRect
    let cameraCenter: SIMD3<Double>
    let cameraDistance: Double
    let projectionScale: Double
}

enum SingleViewProjector {
    static let neutral = SIMD4<Float>(0.18,0.18,0.18,1)
    static func project(positions: [Float], indices: [UInt32], reference: ReferenceRaster) throws -> ProjectionResult {
        guard positions.count.isMultiple(of: 3), positions.count >= 9, positions.allSatisfy(\.isFinite),
              indices.count.isMultiple(of: 3), indices.allSatisfy({ Int($0) < positions.count/3 }),
              let imageBounds = reference.foregroundBounds else { throw ProjectionError.invalidGeometry }
        var low = SIMD3<Double>(repeating: .infinity), high = SIMD3<Double>(repeating: -.infinity)
        let points = stride(from: 0, to: positions.count, by: 3).map {
            SIMD3(Double(positions[$0]),Double(positions[$0+1]),Double(positions[$0+2]))
        }
        for p in points { low = simd_min(low,p); high = simd_max(high,p) }
        let center = (low + high) / 2, size = high-low
        let largest = max(size.x,max(size.y,size.z)), distance = largest * 2.1
        guard largest.isFinite, largest > 0 else { throw ProjectionError.invalidGeometry }
        let focal = 1 / tan(42 * Double.pi / 360)
        var qLow = SIMD2<Double>(repeating: .infinity), qHigh = SIMD2<Double>(repeating: -.infinity)
        let projected = try points.map { p -> SIMD3<Double> in
            let delta = p-center, depth = distance-delta.z
            guard depth > 0, depth.isFinite else { throw ProjectionError.invalidGeometry }
            let q = SIMD2(delta.x*focal/depth, delta.y*focal/depth)
            qLow = simd_min(qLow,q); qHigh = simd_max(qHigh,q)
            return SIMD3(q.x,q.y,depth)
        }
        let qSize = qHigh-qLow, qCenter = (qHigh+qLow)/2
        let fitBounds=imageBounds.insetBy(dx:1,dy:1)
        guard qSize.x > 0, qSize.y > 0, fitBounds.width > 0, fitBounds.height > 0 else { throw ProjectionError.invalidGeometry }
        let scale = min(Double(fitBounds.width)/qSize.x, Double(fitBounds.height)/qSize.y)
        let screen = projected.map { p in
            SIMD3((p.x-qCenter.x)*scale+Double(imageBounds.midX),
                  (p.y-qCenter.y)*scale+Double(imageBounds.midY),p.z)
        }
        let width = reference.width, height = reference.height
        var depth = [Double](repeating: .infinity, count: width*height)
        // Bin projected triangles only to accelerate an exact continuous ray
        // query at each vertex. Raster-neighbor depth with a physical tolerance
        // can incorrectly paint a closely occluded surface.
        let binsX=min(width,128), binsY=min(height,128)
        let binScaleX=Double(binsX)/Double(width),binScaleY=Double(binsY)/Double(height)
        var bins=[[Int]](repeating:[],count:binsX*binsY),binReferences=0
        func edge(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ x: Double, _ y: Double) -> Double {
            (b.x-a.x)*(y-a.y)-(b.y-a.y)*(x-a.x)
        }
        for f in stride(from: 0, to: indices.count, by: 3) {
            if f.isMultiple(of: 12_288) { try Task.checkCancellation() }
            let a=screen[Int(indices[f])],b=screen[Int(indices[f+1])],c=screen[Int(indices[f+2])]
            let area=edge(a,b,c.x,c.y)
            if abs(area)<1e-12 { continue }
            let bx0=max(0,min(binsX-1,Int(floor(min(a.x,min(b.x,c.x))*binScaleX))))
            let bx1=max(0,min(binsX-1,Int(floor(max(a.x,max(b.x,c.x))*binScaleX))))
            let by0=max(0,min(binsY-1,Int(floor(min(a.y,min(b.y,c.y))*binScaleY))))
            let by1=max(0,min(binsY-1,Int(floor(max(a.y,max(b.y,c.y))*binScaleY))))
            for y in by0...by1 {
                for x in bx0...bx1 { bins[y*binsX+x].append(f);binReferences+=1 }
            }
            guard binReferences<=8_000_000 else { throw ProjectionError.invalidGeometry }
            let x0=max(0,Int(floor(min(a.x,min(b.x,c.x))))),x1=min(width-1,Int(ceil(max(a.x,max(b.x,c.x)))))
            let y0=max(0,Int(floor(min(a.y,min(b.y,c.y))))),y1=min(height-1,Int(ceil(max(a.y,max(b.y,c.y)))))
            if x0>x1 || y0>y1 { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let px=Double(x)+0.5,py=Double(y)+0.5
                    let u=edge(b,c,px,py)/area,v=edge(c,a,px,py)/area,w=1-u-v
                    if u < -1e-8 || v < -1e-8 || w < -1e-8 { continue }
                    let reciprocal=u/a.z+v/b.z+w/c.z
                    if reciprocal>0 { depth[y*width+x]=min(depth[y*width+x],1/reciprocal) }
                }
            }
        }
        let numericalDepthTolerance=max(distance*Double.ulpOfOne*128,largest*1e-12)
        var colors=[SIMD4<Float>](repeating:neutral,count:points.count),visible=0,painted=0
        for (index,p) in screen.enumerated() {
            if index.isMultiple(of:4096) { try Task.checkCancellation() }
            let ix=Int(floor(p.x)),iy=Int(floor(p.y))
            guard ix>=0,ix<width,iy>=0,iy<height else { continue }
            let bx=min(binsX-1,Int(floor(p.x*binScaleX))),by=min(binsY-1,Int(floor(p.y*binScaleY)))
            var nearest=Double.infinity
            for f in bins[by*binsX+bx] {
                let a=screen[Int(indices[f])],b=screen[Int(indices[f+1])],c=screen[Int(indices[f+2])]
                let area=edge(a,b,c.x,c.y)
                let u=edge(b,c,p.x,p.y)/area,v=edge(c,a,p.x,p.y)/area,w=1-u-v
                if u < -1e-9 || v < -1e-9 || w < -1e-9 { continue }
                let reciprocal=u/a.z+v/b.z+w/c.z
                if reciprocal>0 { nearest=min(nearest,1/reciprocal) }
            }
            guard nearest.isFinite,p.z<=nearest+numericalDepthTolerance else { continue }
            visible+=1
            if let c=reference.linearColor(x:p.x,y:p.y) { colors[index]=c;painted+=1 }
        }
        return .init(screenVertices:screen,colors:colors,coloredVertices:painted,frontVisibleVertices:visible,
                     occupiedDepthPixels:depth.filter(\.isFinite).count,referenceBounds:imageBounds,
                     cameraCenter:center,cameraDistance:distance,projectionScale:scale)
    }
}
