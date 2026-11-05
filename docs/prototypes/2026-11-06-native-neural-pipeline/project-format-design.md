# 神经网格作品格式与保存演进设计

状态：只读源审计后的设计建议，2026-11-06。尚未实现、迁移或操作手机。Root 负责随后生产实现；本文不修改 App、Core、SDK、现存作品或既有 QA。

## 必须保留的事实

Root 已确认设备当前有两件作品：一件 8 节点、约 32 秒的真实 AI 规划作品，以及一件 12 节点手动参数作品。本设计没有独立读取手机，不能声称已验证迁移成功。两件作品的目录、现行 revision、JSON、GLB/USDZ、哈希和历史版本必须在升级/list/open 后保持逐字不变。不得恢复先前删除的作品。

“参数场景”描述资产的表示和编辑方式，不等于“手动制作”。旧 AI 规划的 SceneSpec 仍是实际 AI 结果；新格式不能按节点数、名称或 content kind 重新推断创作方式。

神经形状的真实网格不能写成空白球、椅子、一个虚假 SceneSpec.mesh 或一个只指向旧模板的描述。当前观察目标约 153k 顶点、307k 三角面，约 921k 索引。这些是需要保留的真实结果规模，不是建议设置的新最大值。

## 现有硬依赖

| 路径 | 当前依赖 | 最小变更 |
| --- | --- | --- |
| `Apple/ThreeLiveStudio/Storage/ProjectStore.swift:5–16` | CreationProject 必须有 SceneSpec，名称从 specification.name 派生 | 公共名称独立存储，内容使用明确类型；仅参数内容提供 sceneSpec |
| 同文件 `46–60` | list 只接受 schemaVersion == 1 | 使用兼容解码器接受已知 V1/V2，不在读取时重写 |
| 同文件 `65–103` | publish 必须 spec.validate，接收两份 Data，最后原子替换 project.json | 保留唯一提交点，增加真实网格/文件输入入口，共用事务 |
| 同文件 `106–118` | load 先校验 specification；缩略图已经只依赖 id/revision/USDZ digest/URL | load 按 content 分派校验；缩略图身份保持不变 |
| 同文件 `130–143` | draft 必须有 SceneSpec | 增加有类型的草稿，神经草稿不补参数场景 |
| `Apple/ThreeLiveStudio/App/StudioModel.swift:14,71–79,119–190` | 工作状态、dirty/export、AI 上下文、几何生成和发布全部围绕 SceneSpec | 区分参数编辑、神经资产与新神经草稿；新流水线不经 SceneGenerator |
| 同文件 open/delete/persistDraft/enterBackground | 载入和草稿恢复默认拿 SceneSpec | 根据实际内容恢复；继续立即清除已删除当前作品的持久草稿 |
| `Apple/ThreeLiveStudio/Creation/CreationWorkspace.swift:82–84,197–200` | 编辑 Binding 仍有 `.chair` fallback；ensureGenericScene 会补空白球 | 只在参数 case 创建 SceneParameters，不对神经 case 调用此 fallback |
| `Apple/ThreeLiveStudio/Creation/SceneParameters.swift` | 逐节点 primitive/尺寸/profile/1024 顶点/2048 面编辑 | 继续用于旧参数表示；不作为大网格编辑器 |
| `Apple/ThreeLiveStudio/Library/ProjectLibrary.swift` | 名称来自 project.name，打开交给 Store，缩略图来自 USDZ | 公共名称接口保持；不把 content kind 当 AI/manual 标签 |
| `Apple/ThreeLiveStudio/Preview/ModelViewport.swift` | 已经通过实际 USDZ URL 加载；不读取 SceneSpec | 保留 task/requestID/cancellation 逻辑，单独验大网格载入和内存 |

另有独立导出门槛：`Apple/Packages/ThreeLiveNative/Sources/ThreeLiveNative/ThreeLiveNative.swift:18–19,149–161` 限制 100,000 顶点、300,000 **索引**。SceneSpec 单个自由网格限制 1024 顶点/2048 面，SceneGenerator 总预算 20k 顶点/80k 索引。不能仅绕过 SceneSpec 后继续用旧导出器，也不能自动减面到这些旧预算来假称神经结果已保存。

VoxamberShapeNative 应提供自有 ShapeMeshBuffers、真实 GLB/USDZ 及统计/验证信息；Root 已取得此 SDK 接口方向。独立 SDK 的实际安全预算必须明确并保留，不能从以上参数预算推导或按一个示例的计数临时设定。超出真实支持范围时应清楚失败，不静默替换或降质。

## 建议的最小 V2 类型

保留公共 `id/revision/createdAt/updatedAt/prompt/glbSHA256/usdzSHA256`。将 `name` 提升为公共字段，将表示方式与来源分开。

```swift
enum ProjectContent {
    case proceduralScene(SceneSpec)
    case neuralMesh(NeuralMeshDescriptor)
}

// 仅说明边界，不是已编译的 SDK/API。
struct NeuralMeshDescriptor {
    let baseGeometry: ArtifactReference
    let statistics: MeshStatistics
    let coordinateConvention: CoordinateConvention
    let editRecipe: MeshEditRecipe
    let provenance: NeuralPipelineProvenance
}
```

磁盘 V2 用明确的 `content.kind` 和相应 payload，避免依赖 Swift 自动合成枚举的隐式磁盘结构。建议 kind 为 `proceduralScene`、`neuralMesh`。公共 schemaVersion 与 SDK/网格容器/生成器版本是不同字段，不能用 build 号替代。

内存只提供 `sceneSpec: SceneSpec?` 的真实投影。神经内容返回 nil，调用者必须显式分支；不得提供一个总能返回空白 SceneSpec 的“兼容”属性。神经统计只有实际 mesh/vertex/triangle/bounds，不填假节点数，也不把 307k triangles 误记成 307k indices。

ArtifactReference 使用 Store 控制的相对路径、实际 byteCount、SHA256、格式/角色。不接受外部 URL、任意磁盘路径、目录穿越或符号链接。大型数组不嵌入 project.json；元数据保持小且可独立读取。

## V1 兼容与版本策略

1. 定制解码器先读 schemaVersion。V1 按原字段解码，将 specification 映射为内存中的 proceduralScene，名称取原 spec.name；保留原 version 和数据，不自动 encode 回磁盘。
2. list/open/thumbnail/export 读取旧文件，不产生“迁移后的 revision”。仅用户明确编辑/再生成并成功发布时创建新 revision，可写 V2 proceduralScene，并记录父 revision。
3. 未记录的旧来源标为 legacy/unrecorded，不能自动写 manual、neuralMesh 或捏造 seed/model。若有真实测量记录，必须按 project+revision 精确关联；不可按标题/节点数猜。
4. 未知版本/未知 kind 保留原文件并报告不支持，不转换成默认场景。坏项目也不能导致其它有效项目被覆盖或恢复已删除目录。
5. V2 不要求修改旧 GLB/USDZ 文件名或当前指针布局；现有 reader 的 `schemaVersion == 1` 必须在新 writer 启用前替换，否则新作品会从库中消失。

## 神经 revision 的最小文件集

继续使用 `<projectID>/<revision>/model.glb`、`model.usdz` 和 `revision.json`；`project.json` 仍是唯一现行提交指针。神经 revision 另外包含完整生成链中实际使用的源 PNG，及不可变的基础几何资产。

- 首个神经 revision 可将未经编辑的完整 GLB 同时作为 baseGeometry 和当前 model.glb 的引用，不必为了两个角色复制相同字节。
- 后续 transform/material revision 保留原始神经基础几何。可以复制/去重到本 revision，或实现有明确引用计数的同项目 immutable base；MVP 优先独立 revision 文件，避免隐式跨 revision 依赖和删除风险。
- 若 Shape SDK 暂无从 GLB 重建可编辑 ShapeMeshBuffers 的原生 API，应保存 SDK 定义的、可校验且有格式版本的 mesh payload。不能丢弃唯一 buffer 后又声称重开仍支持几何重导出。
- 不把高密度网格转成 SceneSpec.mesh 作为重开格式。也不把 RealityKit 的视图归一化缩放写回基础几何。
- 当前 shape-only SDK 若仅提供统一材质，就明确记录该能力；不要伪造 texture/bake 阶段。源图片有纹理不等于三维结果具有同样纹理。

元数据中的统计必须从真实输出计算，并与导出后读回相符：顶点数、三角面数、mesh 数、实际 bounds、可用属性/材质/纹理。至少验证 finite 数据、索引范围、实际几何约束和真实文件可导入；“文件有 glTF/ZIP 头”不足以代表神经产物完整。不同预算可拒绝输出，不能静默降低几何规模后继续记作同一结果。

## 最小可审计来源

NeuralPipelineProvenance 记录实际完成的阶段，不能只写一个 `usingAI = true`。

- 入口是文字、用户图片还是再生成；实际图片的相对路径、哈希、像素大小。文字→图片时保留实际生成 PNG，而非只有 prompt。
- Image SDK 与 shape SDK 的 pipeline ID/版本、模型 ID/固定 revision、素材 manifest/配置 SHA、实际 seed 和推理设置。没有使用的阶段不填完成状态。
- 实际预处理约定：尺寸、裁切、背景处理、坐标系和单位。若形状模型输出归一化坐标，就如实记录；不能把视觉推测尺寸写成真实物理尺寸。
- 父项目/revision（若为明确的再生成或编辑），以及生成、全局 transform、全局材质覆盖等不同 creation method。
- 不保存下载授权 URL、token、密钥、账户联系人、模型绝对路径或模型权重本体。哈希/seed 能追溯一次运行，不自动承诺跨硬件逐字重现。

已有 8 节点 AI 规划作品仍属于 proceduralScene 表示，新神经作品属于 neuralMesh；两者都可由 AI 创建，不能把表示类型当作真实性高低的伪标签。统计/格式验证也不等于用户造型质量验收。

## 不破坏事务与取消

Store 应增加一个神经资产发布入口，内部与原参数发布共享 staging/校验/提交逻辑；不要另造一个直接写 project.json 的快捷路径。建议接收 operation 私有临时目录中的文件引用，流式 copy/hash；避免同时持有巨型 buffers、GLB Data、USDZ Data 和二次 Data(contentsOf:) 全量回读。

提交顺序保持：生成完整文件 → 同项目 `.pending-<revision>` → 文件及来源校验 → 写 revision.json → 检查发布许可/预期父 revision → 原子移入 immutable revision → 原子替换 project.json。校验失败、模型失败、取消和超时都不得切换指针。

若 staging 已移动而指针尚未提交时失败，只能清理本 operation 明确创建的未提交新 UUID 目录；不能把其它非 current 历史 revision 当垃圾一并删除。

两个现有实现边界需要在新异步流水线里明确处理：

1. 当前 list 会删除所有 `.pending-*`。原 publish 为 actor 内同步事务，没有中途 await；若新发布为了大文件改成异步 copy，actor 重入时 list 可能删掉正在写的 staging。要么保留受限的同步流式文件事务，要么记录 active staging，并只清理已确认非活动的遗留目录。
2. `replacing old` 必须检查磁盘 current revision 仍为 old.revision。目录/指针已删除或版本已前进时拒绝 stale publish，不得重新建旧 projectID 恢复已删作品。新作品只能分配新 ID。

Root 的 operation UUID、取消 token 和 SDK worker 必须统一归属。取消先撤销该 operation 的发布许可，再 cancel 并 await image/shape/export 子任务与设备工作收束；旧进度/旧 completion 不能操作新任务。Store 的许可检查与小指针提交需要一个明确的串行化/锁定线性化点，而不只是调用方几秒前查过 Task.isCancelled。

取消发生在提交点前就不得发布。提交已完成后才处理到取消时，应如实返回已保存的 commit 结果，不能说“已取消且没保存”或删除已提交 revision。测试应精确控制这个边界；不承诺能够撤销已经完成的原子提交。

文字生成图片但 shape/export 失败只算未完成流水线。可以保留为明确的未发布草稿或清理操作临时目录，不把图片/假网格加入作品库。PNG、base mesh、导出文件的生命周期与许可均属于同一 operation，不在停止后悄悄继续发布。

## 工作状态与真实编辑能力

最小需要区分新神经草稿、已保存参数作品、已保存神经作品三种状态。当前 `sceneSpec?` 的 nil 同时被视为“补椅子/球”的信号，不能直接沿用为神经模型模式。

- SceneParameters 仅在 proceduralScene 分支显示，原参数作品仍可逐部件编辑。神经作品的 SceneSpec? 为 nil 时不能进入现有 Binding fallback。
- 神经作品仅提供已实际实现的整体 transform、材质覆盖和再生成。不能显示 primitive picker/profile editor 并暗示是在编辑原来 153k 顶点模型的语义部件。
- MeshEditRecipe 保存相对于不可变 base 的 transform/material。保存编辑必须由原生真实 mesh/exporter 将变更写入新 GLB/USDZ 并重新测量/hash；只改 RealityView 实体外观不算完成可导出的编辑。
- 再生成明确产生新神经结果/revision，不承诺保留未提及的扶手、拓扑或像素细节。不能将旧 SceneSpec 的参数快照作为真实神经网格的完整编辑描述。
- dirty/canExport 按实际内容计算：参数比 SceneSpec，神经比已保存 editRecipe。修改下次生成的 prompt 不应伪造网格已变化；导出始终对应明确已保存 revision。
- 草稿 V2 也需要 discriminator。载入神经草稿只恢复输入/基础资产引用/未保存编辑，不用空白 SceneSpec 填充；删除当前项目后立即持久化清除其 draft 引用，不能等 debounce 再清。
- Preview 与 thumbnail 继续走实际 USDZ URL。预览显示可归一化为 0.65 最长边，但不得因此改变资产单位。验证大模型重进页面、取消、重载，保留现有 requestID 隔离。
- 作品库名称、日期、排序、删除与 revision+digest 缩略图路径可保持；生成类型不改变缩略图缓存身份。不同神经 revision 即使名称相同也不能共用旧图。
- 创作入口的 readiness 以后应检查 image+shape 所需素材与 SDK。旧 Qwen 的 `models.installed` 不能代表新流水线已就绪。

## 可分批实施

1. **读格式先行**：新建类型/兼容 codec，修改 ProjectStore reader 与公共 name/sceneSpec 投影。现有 writer 暂不切换，先让 V1 回归和混合 V1/V2 合成 reader 测试通过。
2. **真实文件发布**：增加独立 neural validator、provenance、文件型发布入口、发布许可与 stale-revision 防护。用合成高密度网格做 CPU/原生格式测试，不需要运行模型，不改现有真实作品。
3. **协调器接入**：Root 连接 VoxamberImageNative → 释放图像推理资源 → VoxamberShapeNative → 释放形状推理资源/导出 → 单一 publish。结果是实际 PNG/buffers/files，不经过 ScenePlan/SceneGenerator。继续复用现有 busy/cleanup/idle lease 归属。
4. **工作区分派**：Root 修改 StudioModel/CreationWorkspace 的工作内容和 draft，再按能力显示参数或神经编辑。ProjectLibrary/ModelViewport 保持公共文件接口，只做必要名称与状态适配。
5. **旧数据与真机验收**：Root 在授权窗口对当前两件作品做升级前后 hash/current revision 对照；新神经作品另做真实生成、保存重开、预览、缩略图、导出、取消/重试与内存测量。不得将格式测试代替神经质量或手机通过。

文件改动集中在新 `ProjectContent/ProjectCodec`、原 `ProjectStore.swift`、`StudioModel.swift` 和 `CreationWorkspace.swift`；SceneParameters 继续原有表示，新增独立 neural edit view/recipe。Core/旧 exporter 不需要为了容纳神经网格而提高或降低全局预算。Image/Shape SDK 的事务外输出可先固定成 operation 目录+artifact descriptors，避免协调器与 Store 双方同时持有不可控大 Data。

## 必要回归与迁移测试

| 测试 | 应证明的行为 |
| --- | --- |
| V1 真实布局的 8/12 节点合成 fixtures；当前真作品另在 ignored 保护副本核对 | list/open/restart 不改变旧 JSON、GLB/USDZ、revision 和创建时间，不恢复已删目录；不把 AI 表示误标 manual |
| V1/V2 混合库、未知版本、坏 kind | 已知作品可见，未知/坏文件保留且明确不可打开；无 SceneSpec 默认替代 |
| 153k 顶点/307k 面及 SDK 实际支持边界的合成真实 buffers/files | 绕过旧 100k/300k exporter；导出/读回保持实际计数与哈希，无自动减面、模板、伪 stats |
| staging copy、校验后、提交前、提交后的可控取消 gate | 提交前取消不切换 current 指针；提交后如实报告已保存；不遗留活动 staging 被 list 删除 |
| 慢旧任务 + 删除/新 revision | 预期父 revision/CAS 与 operation 许可拒绝 stale publish，不复活旧项目，不清新操作 |
| 缺源图/坏 hash/非有限网格/坏索引/越界资源/不安全路径 | 失败保留之前作品，神经数据不能绕过实际 SDK 文件/几何校验 |
| transform/material 新 revision + 重开/双格式读回 | base 几何不变，实际导出的变换/材质正确，未声明字段和拓扑不被改写；不把预览变更当文件成功 |
| V2 draft/delete/restart 与 nil SceneSpec 工作区 | 神经草稿不变椅子/球，删除后无旧 draft 复活，编辑控件按真实能力分派 |
| 同名神经不同 revision 的缩略图；删除时迟到 QL 返回 | 使用对应 USDZ digest，不能拿旧参数图/旧 revision 顶替，也不能因缩略图失败损坏提交 |
| 大网格真实 USDZ 载入、退出/重返、取消与资源释放 | 保留 ModelViewport 所属 task 与 stale guards；仅格式或无错误覆盖不等于实际图像正确 |

这些测试验证保存与表示边界。神经生成质量、12GB 实机峰值/速度、图像模型的许可与 Apple 素材下载状态均需各自真实证据，不能从 V2 格式设计推出。
