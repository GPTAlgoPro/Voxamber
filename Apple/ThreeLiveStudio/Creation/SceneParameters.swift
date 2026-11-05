import SwiftUI
import CreationCore

struct SceneParameters: View {
    @Binding var scene: SceneSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(StudioCopy.text("作品名称", "Creation name"), text: $scene.name).textFieldStyle(.roundedBorder)
            HStack {
                Text(StudioCopy.text("\(scene.nodes.count) 个部件", "\(scene.nodes.count) \(scene.nodes.count == 1 ? "part" : "parts")")).foregroundStyle(.secondary)
                Spacer()
                Menu(StudioCopy.text("添加部件", "Add part"), systemImage: "plus.circle") {
                    ForEach(SceneNode.Primitive.allCases, id: \.self) { primitive in
                        Button(primitive.title) {
                            scene.nodes.append(SceneNode.defaultNode(primitive: primitive, id: "part_" + UUID().uuidString.prefix(8)))
                        }
                    }
                }.disabled(scene.nodes.count >= SceneSpec.maximumNodes)
            }
            ForEach($scene.nodes, id: \.id) { $node in
                DisclosureGroup {
                    NodeParameters(node: $node)
                    Button(StudioCopy.text("删除部件", "Delete part"), role: .destructive) {
                        scene.nodes.removeAll { $0.id == node.id }
                    }.disabled(scene.nodes.count == 1).padding(.top, 10)
                } label: {
                    HStack { Image(systemName: node.primitive.symbol); Text(node.id).lineLimit(1); Spacer(); Text(node.primitive.title).foregroundStyle(.secondary) }
                }.padding(12).background(.white.opacity(0.045), in: .rect(cornerRadius: 14))
            }
            if let message=validationMessage {
                Label(message,systemImage:"info.circle").font(.caption).foregroundStyle(.orange)
            }
            Text(StudioCopy.text("修改后点击“按参数生成”更新模型。尺寸和位置以米为单位。", "Choose Generate from edits to update the model. Dimensions and positions are in meters."))
                .font(.caption).foregroundStyle(.secondary)
        }.font(.subheadline)
    }

    private var validationMessage:String? {
        do { try scene.validate();return nil }
        catch { return StudioCopy.text(error.localizedDescription,"Review the part dimensions, geometry, and material values before generating.") }
    }
}

private struct NodeParameters: View {
    @Binding var node: SceneNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(StudioCopy.text("形状", "Shape"), selection: Binding(get:{node.primitive},set:changePrimitive)) {
                ForEach(SceneNode.Primitive.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            ColorPicker(StudioCopy.text("颜色", "Color"), selection: Binding(get: { Color(hex: node.color) }, set: { node.color = $0.hexRGB }), supportsOpacity: false)
            axisControls(StudioCopy.text("尺寸", "Dimensions"), values: $node.size, range: 0.02...2.5, step: 0.01)
            axisControls(StudioCopy.text("位置", "Position"), values: $node.position, range: -3...3, step: 0.01)
            axisControls(StudioCopy.text("旋转", "Rotation"), values: $node.rotation, range: -360...360, step: 5)
            if ["mesh","lathe","extrusion"].contains(node.primitive.rawValue) {
                NodeGeometryEditor(node:$node).id(node.primitive.rawValue)
            }
            Text(StudioCopy.text("材质", "Material")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            scalar(StudioCopy.text("金属度", "Metallic"), value: $node.metallic)
            scalar(StudioCopy.text("粗糙度", "Roughness"), value: $node.roughness)
        }.padding(.top, 12)
            .onChange(of:node.position) { _,_ in
                node.parentID=nil;node.attachment=nil;node.offset=nil
            }
    }

    private func changePrimitive(_ primitive:SceneNode.Primitive) {
        guard primitive != node.primitive else { return }
        var replacement=SceneNode.defaultNode(primitive:primitive,id:node.id,position:node.position)
        replacement.size=node.size;replacement.rotation=node.rotation;replacement.color=node.color
        replacement.metallic=node.metallic;replacement.roughness=node.roughness
        node=replacement
    }

    private func axisControls(_ title: String, values: Binding<[Float]>, range: ClosedRange<Float>, step: Float) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            axis("X", context:title, value: component(values, 0), range: range, step: step)
            axis("Y", context:title, value: component(values, 1), range: range, step: step)
            axis("Z", context:title, value: component(values, 2), range: range, step: step)
        }
    }

    private func component(_ values: Binding<[Float]>, _ axis: Int) -> Binding<Float> {
        Binding(get: { values.wrappedValue.indices.contains(axis) ? values.wrappedValue[axis] : 0 }, set: {
            guard values.wrappedValue.indices.contains(axis) else { return }
            values.wrappedValue[axis] = $0
        })
    }

    private func axis(_ label: String, context:String, value: Binding<Float>, range: ClosedRange<Float>, step: Float) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).frame(width: 15)
            Slider(value: value, in: range, step: step).accessibilityLabel(context + " " + label)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .font(.caption.monospacedDigit()).frame(minWidth: 42, alignment: .trailing)
        }
    }

    private func scalar(_ title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .percent.precision(.fractionLength(0))) }
            Slider(value: value, in: 0...1).accessibilityLabel(title)
        }
    }
}

private struct NodeGeometryEditor: View {
    @Binding var node:SceneNode
    @State private var pointPage=0
    @State private var trianglePage=0
    private let pageSize=8
    private var isMesh:Bool { node.primitive.rawValue == "mesh" }
    private var points:[[Float]] { isMesh ? node.vertices ?? [] : node.profile ?? [] }
    private var triangles:[[UInt32]] { node.triangles ?? [] }
    private var pointRange:Range<Int> {
        let start=min(pointPage*pageSize,max(0,points.count-1))
        return start..<min(start+pageSize,points.count)
    }
    private var triangleRange:Range<Int> {
        let start=min(trianglePage*pageSize,max(0,triangles.count-1))
        return start..<min(start+pageSize,triangles.count)
    }

    var body:some View {
        DisclosureGroup(StudioCopy.text(isMesh ? "网格顶点" : "造型轮廓",isMesh ? "Mesh vertices" : "Shape profile")) {
            VStack(alignment:.leading,spacing:10) {
                Text(StudioCopy.text("编辑部件的局部坐标。更换形状会载入新的基础轮廓。", "Edit coordinates in the part’s local space. Changing its shape loads a new base profile."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("#").frame(width:28,alignment:.leading)
                    ForEach(0..<(isMesh ? 3 : 2),id:\.self) { axis in
                        Text(axisTitle(axis)).frame(maxWidth:.infinity)
                    }
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(pointRange,id:\.self) { index in
                    HStack(spacing:8) {
                        Text("\(index)").font(.caption.monospacedDigit()).frame(width:28,alignment:.leading)
                        ForEach(0..<(isMesh ? 3 : 2),id:\.self) { axis in
                            TextField(axisTitle(axis),value:pointBinding(index,axis),format:.number.precision(.fractionLength(0...3)))
                                .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                                .accessibilityLabel(StudioCopy.text("点 \(index) \(axisTitle(axis))", "Point \(index) \(axisTitle(axis))"))
                        }
                    }
                }
                if points.count>pageSize { pageControls(page:$pointPage,count:points.count) }
                if isMesh {
                    DisclosureGroup(StudioCopy.text("三角形", "Triangles")) {
                        VStack(alignment:.leading,spacing:10) {
                            Text(StudioCopy.text("每个三角形使用三个顶点编号，编号从 0 开始。", "Each triangle uses three vertex numbers, starting at 0."))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(triangleRange,id:\.self) { index in
                                HStack(spacing:8) {
                                    Text("\(index)").font(.caption.monospacedDigit()).frame(width:28,alignment:.leading)
                                    ForEach(0..<3,id:\.self) { corner in
                                        TextField("",value:triangleBinding(index,corner),format:.number)
                                            .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                                            .accessibilityLabel(StudioCopy.text("三角形 \(index) 顶点 \(corner+1)", "Triangle \(index) vertex \(corner+1)"))
                                    }
                                }
                            }
                            if triangles.count>pageSize { pageControls(page:$trianglePage,count:triangles.count) }
                        }.padding(.top,10)
                    }
                }
            }.padding(.top,10)
        }
    }

    private func axisTitle(_ axis:Int)->String {
        if node.primitive.rawValue == "lathe" { return axis == 0 ? StudioCopy.text("半径", "Radius") : StudioCopy.text("高度", "Height") }
        return ["X","Y","Z"][axis]
    }

    private func pointBinding(_ index:Int,_ axis:Int)->Binding<Float> {
        Binding(get:{
            guard points.indices.contains(index),points[index].indices.contains(axis) else { return 0 }
            return points[index][axis]
        },set:{value in
            guard value.isFinite,points.indices.contains(index),points[index].indices.contains(axis) else { return }
            var updated=points;updated[index][axis]=value
            if isMesh { node.vertices=updated } else { node.profile=updated }
        })
    }

    private func triangleBinding(_ index:Int,_ corner:Int)->Binding<Int> {
        Binding(get:{
            guard triangles.indices.contains(index),triangles[index].indices.contains(corner) else { return 0 }
            return Int(triangles[index][corner])
        },set:{value in
            guard value>=0,value<points.count,triangles.indices.contains(index),triangles[index].indices.contains(corner) else { return }
            var updated=triangles;updated[index][corner]=UInt32(value);node.triangles=updated
        })
    }

    private func pageControls(page:Binding<Int>,count:Int)->some View {
        HStack {
            Button { page.wrappedValue=max(0,page.wrappedValue-1) } label: { Image(systemName:"chevron.left") }
                .disabled(page.wrappedValue==0).accessibilityLabel(StudioCopy.text("上一页", "Previous page"))
            Spacer()
            Text("\(page.wrappedValue+1) / \((count+pageSize-1)/pageSize)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button { page.wrappedValue += 1 } label: { Image(systemName:"chevron.right") }
                .disabled((page.wrappedValue+1)*pageSize>=count).accessibilityLabel(StudioCopy.text("下一页", "Next page"))
        }.buttonStyle(.glass).controlSize(.small)
    }
}

extension SceneSpec {
    var shortTitle: String {
        switch name { case SceneSpec.chair.name: StudioCopy.text("扶手椅", "Armchair"); case SceneSpec.robot.name: StudioCopy.text("机器人", "Robot"); case SceneSpec.lamp.name: StudioCopy.text("工作灯", "Desk lamp"); default: name }
    }
    var symbol: String {
        switch name { case SceneSpec.chair.name: "chair.lounge"; case SceneSpec.robot.name: "figure.wave"; case SceneSpec.lamp.name: "lamp.desk"; default: "cube" }
    }
}

extension SceneNode.Primitive {
    var title: String {
        switch rawValue {
        case "box": StudioCopy.text("方体", "Box")
        case "sphere": StudioCopy.text("球体", "Sphere")
        case "cylinder": StudioCopy.text("圆柱", "Cylinder")
        case "cone": StudioCopy.text("圆锥", "Cone")
        case "torus": StudioCopy.text("圆环", "Torus")
        case "mesh": StudioCopy.text("自由网格", "Free-form mesh")
        case "lathe": StudioCopy.text("旋转曲面", "Revolved surface")
        case "extrusion": StudioCopy.text("轮廓拉伸", "Extruded profile")
        default: rawValue
        }
    }
    var symbol: String {
        switch rawValue {
        case "box": "cube"
        case "sphere": "circle"
        case "cylinder": "cylinder"
        case "cone": "cone"
        case "torus": "circle.circle"
        case "mesh": "point.3.connected.trianglepath.dotted"
        case "lathe": "arrow.trianglehead.2.clockwise.rotate.90"
        case "extrusion": "square.3.layers.3d"
        default: "cube.transparent"
        }
    }
}

enum StudioCopy {
    static var isEnglish:Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true }
    static var appName:String { text("维珀","Voxamber") }
    static func text(_ chinese:String,_ english:String)->String { isEnglish ? english : chinese }
    static func status(_ value:String)->String {
        guard isEnglish else { return value }
        return [
            "尚未安装":"Not installed",
            "正在检查本机模型":"Checking the on-device model",
            "已就绪 · 可离线使用":"Ready · Available offline",
            "模型不完整，请重新安装":"Model files are incomplete. Please reinstall.",
            "正在下载，已完成的文件会保留":"Downloading · Completed files are kept",
            "正在导入并校验":"Importing and checking model files",
            "已就绪 · 新安装已取消":"Ready · New installation cancelled",
            "已取消，重试可复用已完成文件":"Cancelled · Retry to reuse completed files",
            "已就绪 · 新安装未完成":"Ready · New installation incomplete",
            "安装未完成":"Installation incomplete",
            "正在载入模型":"Loading the model",
            "已载入 · 离线运行":"Loaded · Running offline",
            "载入失败":"Could not load the model",
            "正在唤醒本机 AI":"Preparing on-device AI",
            "正在理解你的构想":"Understanding your idea",
            "正在构造三维几何":"Shaping your creation",
            "正在生成模型文件":"Creating model files",
            "正在安全保存作品":"Saving your creation",
            "已保存到作品库":"Saved to Creations",
            "已完成":"Complete",
            "已取消":"Cancelled",
            "正在停止":"Stopping",
            "未完成":"Not completed",
            "已取消，之前保存的作品仍在。":"Cancelled. Your saved creations are kept."
        ][value] ?? value
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x46CBB8
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var hexRGB: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X", Int(min(1,max(0,red)) * 255), Int(min(1,max(0,green)) * 255), Int(min(1,max(0,blue)) * 255))
    }
}
