# 双材质大网格候选：原生文件/显示已证，完整外观未验收

这是 Root 授权的下一独立 CPU 条件，仍不修改生产、调用 NN 或操作手机。最小路线不做 atlas：能保守证明前可见、整面 alpha 覆盖的面绑定原始参考 PNG，其余面绑定恒定中性材质。未知面的材质不采图，避免把未知 UV 指向 atlas 灰区而发生插值假彩。

可见性不只检查三角形三个角：对投影重叠的其他三角形求凸多边形交集，在交集各顶点比较仿射逆相机深度；有更前区域就将整面保留中性。浮点数值容差有明确界限，不承诺任意数学精度。mask 条件更保守：整个投影包围矩形连 bilinear 采样 footprint 必须 alpha≥254；因此会拒绝一些实际可用的面，覆盖率必须实测报告。相机 +Z、主体 alpha-box 等比适配仍未标定，颜色仍含摄影光照，不声称 PBR 或背面恢复。

USDZ 保留全原始 points / faceVertexIndices，faceVarying UV 和两个 `GeomSubset` 绑定材质，family 为 partition。GLB 两个 primitive 共享原 POSITION/UV、没有顶点展开，活跃 index 按材质重分组；每个 primitive 的 `extras.sourceTriangleMap` 一一对应原面，必须逐角验证原世界坐标/次序/绕序。**不声称活跃 index 整段 bytes 不变。** 未来若有真正 UV 缝展开，须另加 sourceVertexMap 验证；本路线没有实现通用展开系统。

硬上限是 2000000 vertices、4000000 triangles、GLB 256000000 bytes、USDZ 512000000 bytes。额外有屏幕分桶引用/三角形配对预算，遇到超限拒绝；不放宽这些限制来迁就输出。

13 项纯 CPU 测试通过：近遮挡层、仅挡面内部的小遮挡、面内 alpha 洞、bilinear 边缘、共边、取消、坏坐标/拓扑、sourceTriangleMap 一一映射、篡改绕序拒绝、资源边界，以及真正的 Apple ModelIO CPU 解析（1 mesh、2 材质、原6角索引数）。保留的8项测试一并运行后共21/21通过，没有用合成结果当 AI 成功。

首个小双材质 `DualMaterialTiny01` 在新 USDA 的关闭括号格式处解析失败，尚未渲染或发 QuickLook 请求；实际失败保留。仅将末尾两个关闭括号分行的 CPU 诊断副本成功解析，因此修正并增加原生解析回归。等待 Root 实际取消 gate 终态后，小双材质 `DualMaterialTiny02` 已实际通过：原生两个材质各1面，世界坐标/角序/绕序精确，QL真实缩略图显示RGB/中性灰两区（9958彩色、10468非彩色不透明像素）。

随后按前置协议只运行一次 `VaseDualMaterial01`，没有 NN。200370 vertices / 400772 triangles 全部保留：101877面使用原PNG（25.42%面、25.87%表面积），298895面中性。GLB原POSITION bytes、sourceTriangleMap逐原面世界坐标/角序/绕序，以及USDZ原生逐原面验证均精确通过。活跃GLB index分组发生重排，不声称整段bytes不变。原PNG真实嵌入GLB/64字节对齐的USDZ，SHA与原图完全相同；GLB18976736 bytes、USDZ53486053 bytes，均低于上限。原不可变base及此前全部产物的SHA仍相同。

实际两角度和QL都已看图，正面有蓝金纹理、侧后明显灰区；QL为真实256²模型缩略图（9582彩色、8530非彩色不透明像素）。文件/原生显示能力通过，**完整外观/PBR不通过验收**：硬缝、白亮条带、相机投影错配与摄影光照烘入仍明显。Root也独立看过三图确认这个边界。没有验证正式App的RealityKit `Entity(contentsOf:)` 或iPhone。

Mac CPU投影/整面选择/面积统计38.19s，导出/原生逐面读回/两视图6.27s，QL2.21s，合计约46.66s；不含原先NN，不能外推手机。`dual-material-verification.json`封存精确数值/源/输入/包体/SHA。`evidence/05-large-dual-{front,threequarter,quicklook}.png`是实际PNG逐字复制；大GLB/USDZ/完整sourceTriangleMap留ignored `.build`。四个条件的成败均保留，详见README。

本轮源码已冻结，全部GPU/QL已终态。不再渲染、增加方案或接入生产。

材质分区语义依据 [OpenUSD MaterialBindingAPI](https://openusd.org/dev/api/class_usd_shade_material_binding_a_p_i.html)；写出 partition 不替代这里的一一映射验证，也不替代 Apple 原生显示检查。
