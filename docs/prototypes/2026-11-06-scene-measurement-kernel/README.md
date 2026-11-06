# 显式尺寸变量测量内核（未接入 App / 神经网络）

纯 Swift 原型，用实际生成几何求一个显式尺寸未知数。先固定的[设计合同](design.md)说明支持范围；[验证回执](verification.json)记录受测源码指纹和实际测试。

每个宽/高/深只能是 `.literal(Float)` 或同一个 `.variable(String)`。调用方必须声明测量对象、XYZ 轴、目标米数和标量区间；节点 ID 只用于精确引用，不用于猜测部件用途。一个变量可同时引用于多个尺寸，保留显式等值关系。其它位置、旋转、材质、自由几何、连接与多根结构都保留。

每次候选都调用正式 Core 连接解析与网格生成，测量实际 Float 顶点的 AABB；不会拿声明 height 代替旋转后的高度。当前正式 Core 的尺寸 `0.02…2.5 m`、位置/偏移 `±3 m`、32 部件与 20k 顶点/80k 索引等限制继续生效。任何 Core 拒绝均原样终止，不裁剪区间或调整其它尺寸。

```swift
import CreationCore
import SceneMeasurementKernel

let input = MeasurementDraft(
    name: "Explicit synthetic example",
    nodes: [MeasurementNodeDraft(
        id: "p", primitive: .box,
        dimensions: DraftDimensions(width: .literal(0.4),
                                    height: .variable("v"),
                                    depth: .literal(0.3)),
        position: [0,0,0], rotation: [0,0,0], color: "#3487AB",
        metallic: 0.23, roughness: 0.61
    )],
    constraint: MeasurementConstraint(
        variable: "v", target: .sceneExtent(axis: .y), targetMetres: 1.2,
        interval: ScalarInterval(lower: 0.2, upper: 1.8)
    )
)
let result = try SceneMeasurementSolver.solve(input)
// Only variable dimensions are substituted in result.evaluation.declaredScene.
// canonicalScene separately contains the standard Core attachment/ground result.
```

支持 `.nodeMaximum(id:axis:)` 世界坐标表面最大值和 `.sceneExtent(axis:)` 场景跨度。单个约束的类型结构不提供多变量或表达式执行入口；`evaluate(_:at:)` 可只对指定标量进行完整实际几何评估。

求解只要求端点夹逼，默认最多 32 次二分，可配置最多 64 次。最终另外生成并测量同一个候选，实际绝对误差须 `≤0.001 m`。不会声称函数全局单调、解唯一或已找出所有解。无夹逼时即使区间内部可能存在根也拒绝；两端都在容差内时按欠约束拒绝。不能再分、迭代耗尽、任何几何评估失败或取消均抛错。原输入不会被修改，没有全局缩放、raw 修复、默认物体或命名启发式。

独立返回两份场景，避免混淆参数改动与连接语义：`declaredScene` 仅代入变量；`canonicalScene` 按原 Core 解析连接并统一落地。有连接时，Core 会对整个森林施加同一落地平移；所有绝对根没有连接/落地标记时，Core 保留其绝对位置。本原型不增加另一套定位规则。

本次 `swift test` 通过 **17 个测试、0 失败**，其中 X/Z 参数化测试有两个 case，共 18 个 case。覆盖总高和重叠、指定节点、四处共享未知、真实非轴向旋转/自由形状、多绝对根及有连接多根、非单调夹逼根/无夹逼拒绝、恒定/无解、坏区间/变量冲突/ID/拓扑、资源预算、字面值不变与预取消。取消测试验证任务已取消时不返回场景；没有真机停止延迟证据。首次冷构建 6.27 秒；补充测试后的构建 1.56 秒、测试 0.054 秒，仅代表本机合成测试。

仓库新克隆可直接运行，不需要忽略的构建目录或模型：

```sh
swift test --package-path docs/prototypes/2026-11-06-scene-measurement-kernel
```

需要 Swift 6.0+；包支持 macOS 14 / iOS 18，当前实际验证为 Apple Silicon Mac 上的纯 Swift 包测试。依赖仓库相对路径 `../../../Apple/Packages/CreationCore`，[正式 Core 指纹](production-core-provenance.json)标识这次使用的源码版本。没有构建 App、运行模拟器/手机、加载模型或做 GPU 推理。合成测量通过不等于 AI 尺寸理解、通用造型质量或产品验收通过。
