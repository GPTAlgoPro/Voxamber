# 用专用形体模型重建通用建模主路径

状态：原生 SDK 移植中，尚未接入正式 App，尚未完成新的整链手机验收。用户已授权自行选择合适模型；维持任意题材、12GB iPhone、Apple 原生实现、自带基础模型不超过 8B 的范围，不增加题材白名单。

## 为什么改变路线

正常手机 App 6 的台灯请求在完整输出 1161 token 后进入 ScenePlan 形状类型校验失败，见 [实机记录](../qa/2026-11-06-phone6-lamp-failure/verification.json)。这不是前一次长度上限事件；也没有证据证明权重损坏或 INT4 是此次根因。当前诊断未保存模型正文，不能臆造非法形状词。

同一当前单轮协议在 Mac 上从零生成五题材，[贪心基线](../qa/2026-11-06-app6-fresh-fivecase/ROOT-REVIEW.md)只完整满足本批 1/5；[采样候选](../qa/2026-11-06-sampling-comparison/ROOT-REVIEW.md)虽然五份 JSON 都完整，却没有完整造型通过；再加完整结构约束可增加可导出文件，仍未解决部件堆叠、形体和指令遵从。原生参数化几何仍可用于明确的形状编辑，但不再作为任意题材生成的主引擎。

## 选定的验证路线

1. 小型 Qwen3.5-0.8B 仅处理中文意图和图像提示词，不负责逐顶点/逐部件设计。
2. Apple Swift/Core ML SDXL 在本机生成完整主体参考图，保留真实 768² PNG。前景处理和 512² 形体输入使用 Apple 原生图像 API；生成结果不是静态预设图片。
3. 复用摹界的原生 Hunyuan 2.1 单图形体路径，输出真实自由网格，保存独立 GLB/USDZ。形体 API、进度、取消和释放权重纳入同一有归属的任务。
4. 每一模型阶段完成并卸载后才能进入下一阶段。按进程实际可用内存判断，不能把 12GB 物理内存或 INT4 字样当作峰值保证。
5. 现有参数编辑和独立原生尺寸约束求值只做辅助。神经网格编辑首先明确提供对象变换、材质和重新生成，不冒称能用旧 primitive 节点精确编辑每个语义部件。

图像前段使用 [Apple Core ML Stable Diffusion Swift 实现](https://github.com/apple-aiml-research/ml-stable-diffusion)及 [iOS SDXL 资源](https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios)。形体模型依据 [Hunyuan3D-2.1](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1)，运行实现复用本机摹界已有的 Swift/MLX 移植。官方原始 Python 转换代码不进入 App。

## 参数预算

| 自行分发的基础模型组件 | 参数上界/实际部署参数 |
| --- | ---: |
| Qwen3.5-0.8B 原模型统计 | 873,438,784 |
| SDXL：UNet、两套 CLIP 与完整 VAE 保守上界 | 3,468,837,867 |
| Hunyuan 实际 mobile shape：全部 DiT 专家、DINO-L 与 VAE decoder | 3,569,340,225 |
| 三组自带权重合计 | **7,911,616,876** |

Shape 不部署未使用的 VAE encoder 113,533,312 参数；不能把量化后 U32 打包数或 MoE 活跃专家数当成总参数。SDXL 的 VAE 上界保守包含源 encoder；额外 refiner、Paint/PBR 神经网络和安全检查权重不在本候选中。Apple Vision 系统模型的私有参数未知，不包含在这份可审计的自带权重统计中，因此不声称所有系统神经处理精确相加也等于此数。

## 已有证据和实际缺口

- Apple 公布过 iPhone 15 Pro Max 上 SDXL 768²、20 步约 31 秒的历史图像基准；不是当前 App 或整链 3D 耗时。
- 摹界记录过 iPhone 17 Pro Max 原生单图 Shape 4096 latent、10 步、192 分辨率共 281.93 秒，输出 153,894 顶点、307,320 三角面与 GLB/USDZ；这不证明本项目的新集成或取消延迟，也不能许诺秒级生成。
- 当前实际手机的进程预算约 6GiB。各阶段峰值、阶段交接是否真正释放、热状态和连续生成仍须测量；Mac 的形体峰值不能替代手机数据。
- Apple 原包依赖的 swift-transformers 0.1.8 与当前 1.3.0 冲突；SDK 将限于 SDXL 自带 BPE 闭包并保留许可。Shape 原移植 MLX 0.31.4 将与本项目统一为 0.32.3，编译通过仍不等于权重数值 parity。
- 当前 SceneSpec 的 mesh 和旧 exporter 资源上限不足以装载真实神经网格。必须新增显式项目资产类型及来源记录，保持已有作品和事务；不能伪造 SceneSpec、恢复旧删作品或为绕过门槛静默删面。

## 接入与发版准入

先完成新 SDK 的 Mac/iOS 编译、资源校验与实际模型推理，再以正常 Release 在 12GB 手机完成中文描述→图像→真实网格→预览/编辑/保存/缩略图/导出/AR。固定自由题材应看真实导出渲染；格式或文件成功不替代造型验收。取消须在各模型实际工作阶段验证，而不是只观察按钮恢复。

Apple 素材包、离线验收、真机质量、内存与取消、TestFlight 处理分别记录。新路线未通过这些检查前不替换手机上的 App 6，也不进行新的 main 发版合并。开发和受限原型继续在 dev，保持既有用户作品原始字节。
