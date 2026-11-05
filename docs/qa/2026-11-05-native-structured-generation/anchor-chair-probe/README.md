# 一次新锚点协议实验：实际椅子仍失败

[生成前协议声明](protocol-before-generation.md)和[独立审阅](independent-review-before-generation.json)均先于本次模型调用保存。上一轮 Stage1 的七部件提纲逐字节复用，**没有重跑 Stage1、修补旧 response 或按部件名称猜位置**。正式 App/Core/Engine/ScenePrompt.system/权重没有改变；实验只在 ignored Swift runner 内执行一个新 CAD 空间协议。

本次新 Stage2 由模型明确选择贴面的 anchor 标签，原生 helper 仅按真实旋转/自由几何 AABB 的切向跨度换算偏移。root 原有两种 placement、模型给出的 ID/primitive/parent/face、全部几何/材质/旋转合同都保留。helper 的 13 条正向纯 Swift/Core 自检以及非法字段、zero-spread 检查先通过，再运行唯一一次 Stage2。

| 输入 token | 输出 token | 首 token | 生成耗时 | 全流程 |
| ---: | ---: | ---: | ---: | ---: |
| 1813 | 789 | 2.063s | 12.296s | 13.359s |

实际[前视图](front.png)和[三分之四视图](three-quarter.png)均已逐张查看。模型给 seat、backrest 和四条腿的全部 6 条连接都选择了 `center`。四条腿最终只有 **1 个实际中心**，比前一次提纲实验的 2 个位置更差；靠背仍在 Z=0 中线；座面上表面约 0.534m，高于约 0.45m 目标；宽实心 base_frame 仍额外存在。

腿可用的切向 spread 为 X≈0.22m、Z≈0.17m，均不为零。此次现象是新模型输出没有选择区分方位的锚点；原生 helper 正确按显式 `center` 输出零偏移，没有暗中分腿或后移靠背。一次失败不能推出模型普遍能力或内部 logits 的具体原因，但足以否定把本次新协议称为质量已验证。

[新原始输出](anchor-response.json)、[center legacy Plan](center-legacy-plan.json)、[协议求值后的 legacy Plan](evaluated-legacy-plan.json)、[最终 canonical scene](scene.json)、[实际 GLB](model.glb)、[实际 USDZ](model.usdz)、[完整视觉检查](visual-review.json)分别保存。GLB 零错误/警告、USDZ 格式与导入通过只是格式证据。MLX 峰值 3,034,562,212 bytes，卸载后 active 4000 bytes/cache 0；这些是 Mac 结果，不是 iPhone 或通用建模验收。

没有第二次生成、输出修复、预设替换、自动缩放或 nudge。新协议的世界轴、inside-center 范围、zero-spread、AABB 真实接触及 center-pass 深图门禁限制均保留在生成前声明中。
