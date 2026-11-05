# 生成前声明：冻结模型语义计划后的几何组合实验

这是一种新声明的三阶段分解：复用历史 Stage1 模型部件图，以及历史短语义模型实际选择的六项锚点，只新运行一次几何 Stage3。两份输入都逐字节冻结，不重跑、不人工分配锚点，也不修补旧输出。本次不能称为最新模型完整新跑了三阶段，更不能把缓存历史耗时当作完整端到端成本。

新 schema 来自上一轮完整锚点合同，仅把每个 child.anchor 由 enum 改为实际语义模型结果的 const，并把对象名称固定为旧模型名称。原模型的七部件、类型、parent/face、root 两种 placement、全部 geometry 定义和 profile64/mesh1024v2048t、材料、旋转等字段保持完整。system 与上一轮 anchor probe 完全相同；user 在上一轮相同基底后追加实际语义结果表及遵守固定 placement 的指令，不增加人工尺寸、坐标或部件模板。

通用 AnchorProtocol.swift 与 AnchorProbe.swift 的 SHA 必须匹配前一轮，求值过程完全不变：显式锚点→真实旋转/freeform AABB 的切向 offsets→现有 Core 全部校验/法向贴合/落地→真实导出和双视图。所有新 raw、center legacy、evaluated legacy、canonical 数据分别保存。

独立检查四腿分离/连接、靠背位置、约0.45m座高、额外 base_frame、整体比例和材质外观。即使固定放置后四腿分开，其他问题仍可导致质量失败。只进行一次正式 Direct3072调用；失败即停止，不重试、改提示词或修复结果。正式 App/Core/Engine/ScenePrompt/权重不变，无手机或发布操作。
