# 小 UV 纹理格式门禁：已通过，尚非大网格实现

Root 在原 vertex-color 条件的 QuickLook 灰色结果后，明确授权仅增加一个合成三顶点、非对称 RGB 纹理条件。没有再处理 200370 顶点花瓶，没有 NN、手机操作或正式 SDK/App 修改。

小资产把同一 64×64 sRGB PNG 真实放入 GLB BIN（`images.bufferView` + `baseColorTexture`）及 USDZ ZIP 根目录（`UsdUVTexture` → `UsdPreviewSurface.diffuseColor`）。USDZ 使用 faceVarying UV；没有 renderer 材质覆盖、图像贴屏或顶点重涂。原生 SCN 直接按 USDZ URL 打开，有真实包内 PNG URL、UV 和三角网格。世界坐标、三角形次序/绕序严格验证；本单三角没有 UV 缝，`sourceVertexMap=[0,1,2]`，因此这一个小例子的 GLB POSITION/index bytes 保持。

**唯一一次实际 QuickLook 请求已返回有色模型缩略图。** 真实 `.thumbnail`（非图标）为 256×256，其中 8893 个彩色像素；实际看图明确有红、绿、蓝三块。原生 SceneKit 视图也有色。USDZ SHA 为 `58c0bde271f5496a26e334d7013c9451bf8005e133f66b57b25acd2fc580fc64`，QuickLook PNG SHA 为 `96a1a3b9fe5d139513455a64b287e862b2d3c7052c7cfc7f14122fe396ff53d9`。此结果仅证明 Mac 小文件的 UV/PNG 格式路径；没有验证产品 RealityKit `Entity(contentsOf:)`、iPhone、任意模型 UV 或神经生成外观。

在这次请求之前，有两次保留的准备失败：`TexturedTiny01` 被原归档器禁止带斜线文件名的规则拒绝；保持规则、把包内 PNG 放根目录后，`TexturedTiny02` 资产已正确，但检测器误把 faceVarying 产生的多索引通道当单通道。按 SDK 公开的 `geometrySourceChannels/indicesChannelCount/hasInterleavedIndicesChannels` 修正位置通道读取后，`TexturedTiny03` 与 `02` 的 GLB、USDZ、USDA、PNG **全部逐字相同**，并通过世界几何门禁。前两次 QuickLook 请求数都是 0；没有换图、换几何或重试选色。

原生 SCN 的 UV 读回值采用 V 翻转的表示；原始值完整保留在回执。未经 `MDLAsset.loadTextures` 的 ModelIO textureSampler 对象没有加载纹理，这条观察仍记录 false；不把直接 SCN 的纹理 URL/QuickLook 实际有色结果混同为该未加载属性通过。

三个条件分开保存：

1. 原 vertex color 大花瓶：真实颜色数据通过，两张实际原生视图灰色，显示失败。
2. 小 vertex color + 白 diffuse：SceneKit 桥接 RGB 通过，QuickLook 灰白，颜色失败。
3. 当前小 UV + 内嵌 PNG：原生几何/纹理和实际 Mac QuickLook 颜色通过。

产物在 ignored `Apple/.build/ReferenceColorProjection/TexturedTiny03/`，包含自包含 GLB/USDZ、原生两个角度 PNG、QuickLook PNG 和原生读取 JSON。`texture-verification.json` 封存所有 SHA、早期失败和实际请求数。8 项原型测试仍通过。保留了此前两条件的全部字节。

执行这个小门禁的入口（输出目录必须不存在）：

```sh
swift run --package-path docs/prototypes/2026-11-06-reference-color-projection \
  --scratch-path Apple/.build/ReferenceColorProjectionBuild \
  reference-color-projection --texture-smoke Apple/.build/ReferenceColorProjection/新目录
```

尚未实现通用 atlas、展开或接缝处理。以后 GLB 可能需要按 UV 缝展开顶点，不能延续 POSITION/index bytes 完全不变的声称；应通过 `sourceVertexMap` 逐原始三角形验证世界坐标/次序/绕序，原 base 必须不改。USDZ 可用 faceVarying UV 保留文件原点/面索引。投影相机误配、未知背面中性色、光照烘入 RGB、非 PBR 限制也仍然存在。

纹理图节点/色彩编码依据 [OpenUSD UsdPreviewSurface 规范](https://openusd.org/dev/spec_usdpreviewsurface.html)，GLB 图像内嵌和左上角 UV 约定依据 [Khronos glTF 2.0 图像规范](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#images)。规范允许并不等于兼容验收；本轮以这里记录的真实原生缩略图作为小文件显示证据。
