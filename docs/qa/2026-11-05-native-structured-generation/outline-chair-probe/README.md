# 一次两阶段装配提纲实验：椅子质量仍不通过

同一 Qwen3.5 4B INT4、正式 `QwenEngine.generateJSON` 单轮 Direct 通道、每阶段 3072 token 上限。固定椅子请求与上一轮完全相同。只新增 ignored Swift runner；正式 App、Engine、Core、ScenePrompt.system 和权重均未改动，没有重试、手工坐标、预设替代或输出修复。

第一阶段由模型自行生成部件、用途和连接图；第二阶段从完整权威 ScenePlan schema 派生 exact-N prefixItems，固定第一阶段给出的 id、primitive、parent、face，再让同一模型补尺寸与几何。第一阶段没有结构化尺寸字段，但模型在 purpose 文本里回显了 Y=0/Y=0.45m；这些实际文本原样保留，未过滤或修复。原有 32 部件上限、8 种形状、64 轮廓点、1024 顶点和 2048 三角面合同均保留。只对本次单椅实验约束“首项一个根部件，其余连接”，不将它作为通用多对象产品的限制。

| 阶段 | 输入 token | 输出 token | 首 token | 总生成时间 |
| --- | ---: | ---: | ---: | ---: |
| 模型装配提纲 | 246 | 435 | 3.473s | 8.999s |
| 固定图完整 ScenePlan | 1556 | 843 | 1.439s | 12.268s |

总流程 22.426s；模型自主给出 7 部件、最大父级深度 1。上一轮单阶段结果为 32 部件、最大深度 7。真实模型输出经过原生解码、几何生成、GLB/USDZ 导出和 Apple 导入，得到 7 meshes、592 vertices、548 triangles。MLX 峰值 3,034,562,212 bytes；卸载后 active 4000 bytes / cache 0。均为 Mac 数据，不是 iPhone 性能证明。

实际查看[前视图](stage2-scene/front.png)和[三分之四视图](stage2-scene/three-quarter.png)后，结论仍是质量失败：四个腿节点两两完全重叠，只形成两个实际腿位置；靠背位于坐面深度中线而非后侧；坐面上表面约 0.534m，高于约 0.45m 要求；额外 base_frame 是完整的宽实心板。模型把前后位置写成 yOffset，省略 zOffset，违背原有坐标说明；本实验没有修改求解器掩盖这个错误。提纲结构抑制了本例的部件串接扩张，却没有解决空间语义问题。

[实际 GLB](stage2-scene/model.glb)、[实际 USDZ](stage2-scene/model.usdz)、[完整视觉检查](visual-review.json)、[每阶段结果](results.json)、[来源与权重校验](provenance.json)、[格式校验](format-validation.json)均已保存。GLB 零错误/警告与 USDZ 导入成功不等于椅子可用，更不等于通用自由建模已通过。
