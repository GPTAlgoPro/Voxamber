# Build 2 正式路径造型质量复核

结论：本组固定请求**不能作为“通用自由建模已达标”的证据**。五个新建请求只有机器人和台灯得到可导出场景；椅子、弯尾鲸鱼、未来飞行器被正式完整 JSON 校验拒绝。台灯虽能导出，却违反圆柱底座和约 0.8 米整体高度要求。一次仅改颜色的编辑保真检查通过。

## 本轮身份与边界

- 使用 `QwenEngine.generateJSON(thinking:false,maxTokens:3072)`，正式单轮 Direct 路径、prefill 128、KV 8192、禁图编译、temperature 0；没有使用旧 ChatSession、独立 SampledModel 或 GuidedModel。
- 推理、当前 `ScenePrompt.system/userRequest`、解析、组装与导出等 15 个源码/包文件逐字节匹配 build 2 的代码提交 `3d66224`；模型 10 文件共 3,061,129,077 字节，全部 SHA-256 匹配正式素材清单。见 [provenance.json](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/provenance.json)。
- chair / robot / lamp 逐字采用 `DeviceAcceptanceProbe.cases`；另两题材与只改色请求是固定 QA 数据，不是用户内容。见 [fixed-prompts.json](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/fixed-prompts.json)。每项只尝试一次，没有修复重试、预设补位或历史图片替代。
- 临时 runner 仅位于 ignored `Apple/.build/production-quality-runner`。业务源码、模型和提示未由本轮修改；未安装、切换或重启手机 App。期间其他并行 App 工作产生的差异见 provenance，已验证的 15 个组件文件在运行后仍不变。
- 这是 Mac 的生产源码审阅，不是手机输出重放、iPhone UI/性能、飞行模式或所有题材验收。场景均为真实模型返回后，经正式 decode → native meshes → GLB/USDZ → Apple SceneKit 导入后渲染；PNG 只设固定灯光和相机，没有修改资产几何/材质，也没有图像后处理。

## 一次调用结果

| 固定请求 | 本次结果 | 首 token（Mac 秒） | 生成/拒绝（Mac 秒） |
| --- | --- | ---: | ---: |
| chair | 正式JSON门禁拒绝 | 3.087 | 32.57 |
| robot | 可导出，需看质量 | 0.936 | 11.67 |
| lamp | 可导出，需看质量 | 0.931 | 3.40 |
| whale | 正式JSON门禁拒绝 | 0.947 | 12.31 |
| aircraft | 正式JSON门禁拒绝 | 1.048 | 30.30 |
| color_only_edit | 改色及保真检查通过（本例） | 2.528 | 19.82 |

原始结果见 [results.json](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/results.json)，逐图审阅与数值证据见 [visual-review.json](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/visual-review.json)。三个拒绝请求均有首 token，且都不是本 runner 的 180 秒超时；**无法由正式 API 判定究竟是 token 截断、语法、非对象或响应长度门禁**，因为拒绝时不会返回缓冲与终止原因。本轮没有另调 Direct 重生成来冒充同一响应。

## 实际图像审阅

### 机器人：可辨识的基本组合，造型质量有限

立方头、躯干、双臂双腿与两只黄色球形眼睛可见，两眼分离并在同一前脸。双臂上端高于头顶，形体像两根长竖杆/天线，缺乏自然肩臂层次；整体仍是很简单的 box/cylinder/sphere 组合。这是“玩具机器人基本组成可生成”的证据，不是任意自由造型通过。

![机器人前视](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/robot/front.png)
![机器人斜视](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/robot/three-quarter.png)

### 台灯：可辨认，但不服从明确几何要求

用户要求圆柱底座，模型 response 已写成 `primitive=box`，图中也明显是方形底座；不是导出或预览把圆柱改成方块。模型真实高度为 **1.094 米**，比请求约 0.8 米高 **36.7%**。支杆和罩没有明显分离，但罩偏尖长、形体粗简。颜色声明为灰和红；离屏高光偏白，未据像素色差认定手机材质错误。

![台灯前视](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/lamp/front.png)
![台灯斜视](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/lamp/three-quarter.png)

### 仅改色：这一例保真通过

输入是本轮真实生成的 robot（chair 本轮未生成成功，没有改用预设）。全部 9 部件颜色均为 `#22B8A8`；位置、尺寸、旋转、名称、id、形状与其他属性完全相同，最大位置和尺寸变化均为 **0**。CPU 几何缓冲完全相同，实际导出 GLB 的 BIN chunk 也逐字节相同。

这只覆盖一件普通基元组合；本输入没有自由 profile/vertices/triangles，不能外推任意编辑或自由曲面保真。

![改色前视](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/color_only_edit/front.png)
![改色斜视](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/color_only_edit/three-quarter.png)

### 椅子、鲸鱼、飞行器

正式 API 未返回通过 JSON 校验的响应，因此没有可导出或可审阅图像。各目录只保留该次固定请求及拒绝记录；没有用可视化占位图、旧模型或预设补结果。当前“通用自由建模”目标尤其缺少两个非模板题材的有效资产证据。

## 格式检查

3 件实际导出的 GLB 均通过现有 Khronos glTF Validator 2.0.0-dev.3.10：**0 errors / 0 warnings**。USDZ 的 ZIP CRC、未压缩 entry、64 字节对齐均通过，且真实被 Apple SceneKit 导入并渲染两个视图。详细见 [format-validation.json](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/format-validation.json) 与各目录 `glb-validation.json`。

格式正确仅证明文件可用，不能消除上述结构/比例/服从问题。近邻 AABB 连通指标也不能替代实际图像审阅。

## 下一版修复优先级

1. **P0：正式生成的完整性与失败可诊断性。** 保留 JSON/几何安全门禁，解决常见椅子和自由题材无法产出可解析场景的问题，不能用不完整模型充数。终止原因/截断状态后续应有隐私安全诊断。
2. **P1：用户明确意图的几何约束。** 形状要求与整体尺寸需要真正被检查；台灯“圆柱底座”和“约 0.8 米”目前失守。
3. **P1：部件语义、比例与自由轮廓。** 机器人部件存在不等于结构成熟，简单基元可渲染不等于任意题材自由建模。
4. **P2：保留无损编辑回归并扩大覆盖。** 本次改色结果可保留为严格回归，后续还需自由曲面与更复杂编辑证据。

本报告不把取消/清理热修或 TestFlight 发布状态当作这些质量问题已经解决，也未因此改模型、提示或业务代码。


## 后续独立拒绝诊断（不改写上述验收）

后续按原固定请求另做一次Direct原始输出诊断：椅子与飞行器都达3072token并在JSON中途结束，而且结束前已经超过规划/几何预算；鲸鱼只有1217token但profile中出现额外引号，属于确定的数组语法错误。三项均低于16KB并正常走完producer结束阶段。原正式响应未保留，不能声称新诊断与原字节完全同一；原3个reject仍保留。详细见[诊断说明](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/rejection-diagnostics/README.md)。
