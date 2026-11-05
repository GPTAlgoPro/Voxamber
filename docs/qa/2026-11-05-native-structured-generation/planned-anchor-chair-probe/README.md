# 冻结语义计划后的单次几何组合：放置改善，完整请求未通过

本实验[预先声明](architecture-before-generation.md)新的三阶段分解，但只新运行几何 Stage3：Stage1 图和六个语义锚点都来自已冻结的真实模型输出，原样复用。没有人工指定锚点、重跑上游、修改旧响应或修复新几何。**这不是完整新跑的三阶段验收，也没有测量完整三阶段端到端耗时。**

[纯 native preflight](preflight.json)验证语义 ID 集与贴面标签兼容。[schema 差异](schema-diff-before-generation.json)仅为六项 anchor 的 enum→实际模型 const，以及旧模型名称 const；root 两种 placement、模型图、全部几何/材质/旋转字段保持不变。通用 evaluator 源码 SHA 与前一轮相同。system 与旧 anchor probe 完全相同；user 基底后只追加真实语义表和固定 placement 指令。

| 本次新几何输入/输出 token | 首 token | 几何生成 | 本次载入+几何流程 |
| --- | ---: | ---: | ---: |
| 1938 / 795 | 2.121s | 12.314s | 13.436s |

逐张查看实际[前视图](front.png)和[三分之四视图](three-quarter.png)：这次四腿分开落地（中心 X≈±0.27m、Z≈±0.22m），靠背后置（Z≈−0.175m），外形可识别为椅子。它改善了前一轮四腿全部中心重叠的问题。

完整请求仍未通过：座面上表面约 0.534m，比约0.45m目标高 8.4cm（+18.7%）；0.60×0.50×0.05m 的实心 base_frame 仍与单独坐面叠成两层；靠背厚约0.15m、整体块状；材质仍是纯色几何。原始模型仍给腿高0.45m，并没有把支撑板和座面厚度计入座高目标，求值器未替模型改尺寸。

[新模型 JSON](stage3-model-response.json)、[center legacy](center-legacy-plan.json)、[evaluated legacy](evaluated-legacy-plan.json)、[canonical scene](scene.json)、[实际 GLB](model.glb)、[实际 USDZ](model.usdz)和[视觉检查](visual-review.json)已分别保存。GLB 零错误/警告、USDZ CRC/存储/对齐/实际 Apple 导入通过只是格式证据。MLX 峰值 3,034,562,212 bytes，卸载后 active4000 bytes/cache0，均为 Mac 数据。

正式源码、通用 helper 和旧 QA artifact 前后保持一致；十个权重文件的大小/mtime/ctime/inode/device 身份不变，按授权复用紧邻上一轮完整 SHA256 校验，没有重复读取3GB权重。仅这一次几何调用，没有重试、自动缩放、手动改尺寸、模型下载、手机操作或发布。
