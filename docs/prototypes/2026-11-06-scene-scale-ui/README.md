# 原生尺度编辑原型（未接入 App）

这是供代码审阅的隔离草案。正式 App、正式 CreationCore、模型、版本和 TestFlight 均未因本原型改变；当前正式 Core 仍采用原来的数值范围。

原型现在包含轻量的 `SceneScaleCoreCandidate/` Swift Package，UI 的全部依赖都在本目录内，不再需要 `Apple/.build`。只复制了冻结候选的 `Package.swift`、`Sources/`、`Tests/` 共 20 个文件（约 163 KB），与原候选逐字一致。[来源指纹](provenance/core-snapshot.json) 保留正式 Core 的原始 17 项和候选的 21 项 SHA256；第 21 项是未复制的候选说明文档，其指纹仍保留。此快照仍未推广为正式 Core。

`NumericAxisControl` 绑定现有 `Float` 数值，支持直接输入 `m`、`cm`、`mm`、负位置和科学计数法。输入无效时显示原因并保留上次有效值；出现视图、切换显示单位不会夹值或写回舍入值。微调滑杆使用当前数值或对象跨度附近的范围，拖动开始后固定端点。`SceneParameters.swift` 是正式文件的隔离副本，只接入尺寸/位置控件和未提交输入的有效性回报；自由几何编辑器主体逐字保持一致，材质、旋转及更换形状逻辑保留。

依赖路径修复后，按 Git 可保存文件导出独立目录，以全新构建目录重新验证：

| 证据 | 本次结果 | 实际覆盖 |
| --- | --- | --- |
| 隔离 Scale Core | 57 通过，0 失败 | 数值域、所有 8 类几何的世界坐标检查及原有合同回归 |
| 数值/滑杆数学 | 6 通过，0 失败 | 单位与 Float 往返、负值、无效输入、局部范围及拖动稳定性 |
| 原生 iOS 控件 | 3 通过，0 失败，0 跳过 | 独立宿主、iOS 26.0 模拟器；真实 TextField 出现后零隐式写入；`101` 不覆盖 `3.5`；`2 mm` 仅提交一次；390×844 与大字体布局 |

本次新截图为 `en_US`，分别使用 `.large` 和 `.accessibility3`。顶部与滚动到底部的画面保留 `1 mm`、`3.5 m`、`100 m`、`1000 m` 的实际输入值：

- [标准字号](proof/2026-11-06-local-package/standard.png)、[标准字号位置区](proof/2026-11-06-local-package/standard-position.png)
- [辅助功能大字体](proof/2026-11-06-local-package/accessibility.png)、[大字体位置区](proof/2026-11-06-local-package/accessibility-position.png)

以下历史截图及原有回执保持不覆盖：

- [标准字号](proof/standard.png)、[标准字号位置区](proof/standard-position.png)
- [辅助功能大字体](proof/accessibility.png)、[大字体位置区](proof/accessibility-position.png)

**这些英文截图不能作为中文验收。** 当时 iOS 26.0 模拟器缺少 `PingFangUI.ttc`，中文回退为 LastResort 方框；未复制或下载系统字体，中文实际排版仍待验证。

隔离 Core 的候选合同为尺寸 `0.001…100 m`、位置/连接偏移 `±1000 m`，仍保留 32 部件、64 轮廓点、1024 自由网格顶点、2048 面及总计 20k 顶点/80k 索引预算。世界坐标烘焙成 Float 后，远处极小细节可能退化：原 1 mm 球在 1 km 处有 64/720 个三角面塌缩，候选明确拒绝；同球靠近原点可通过，可表示的远处小方体也可通过。此判断只看数值与拓扑，不按题材、名称或部件角色筛选；不缩放、补面、修复或替换输出。未塌面也不等于工程测量精度承诺。

[本次验证回执](verification-local-package.json) 保存实际受测源码的 SHA256、干净导出与依赖图、三组测试结果、独立 xcresult 回读、新旧 PNG 指纹和操作边界。隔离 Core 的冻结指纹及正式 Core 的 17 项原始指纹均无差异。UI 数值和编辑器实现没有为本次依赖修复改变。

[历史回执](verification.json) 保留旧依赖状态与历史证据；其中“新克隆缺少忽略依赖”的缺口已由本次快照解决。历史 UI 没有逐文件冻结清单，不能把旧时间戳当作密码学冻结证明；本次受测源码已按实际导出指纹核对。

在新克隆中复现（macOS 26+、Swift 6.2+、Xcode/iOS 26+ SDK；本次使用 Xcode 27.2、Swift 6.4.2、XcodeGen 2.45.4）：

```sh
prototype="$PWD/docs/prototypes/2026-11-06-scene-scale-ui"
swift test --package-path "$prototype/SceneScaleCoreCandidate"
swift test --package-path "$prototype"
xcodegen generate --spec "$prototype/project.yml" --project "$prototype"
xcodebuild test \
  -project "$prototype/SceneScaleUIPrototype.xcodeproj" \
  -scheme SceneScaleUIPrototype \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
  -derivedDataPath "$prototype/.build/ios-derived" \
  -only-testing:SceneScaleUIRenderingTests \
  -parallel-testing-enabled NO
```

模拟器名称/系统版本应选本机已安装的组合。生成工程必须与 `project.yml` 同级，让 Xcode 正确解析两个相对本地包；不要把生成工程单独移到另一个目录。生成工程和构建输出已忽略。测试只启动独立原型宿主，不生成模型、不接触手机或正式 App。

接入 `dev` 前还需要：

1. 单独审阅并推广本目录的轻量 Core、中央 `SceneLimits`、世界网格校验及边界测试。自包含原型可复现，不等于正式 Core 已完成集成。
2. 接入两个数值组件及尺寸/位置行；把 `onNumericValidityChanged` 接到 `CreationWorkspace` 的两个生成按钮门禁。默认空回调仅为兼容旧调用，不能代替正式门禁。
3. 验证旧作品/仅改色位姿不变、保存重开、GLB/USDZ 米制、预览与 AR。大模型证据渲染器的固定 `zFar=100` 需按范围调整，不能为适配镜头改变保存尺度。
4. 完成中文与辅助功能排版，以及集成后的真机性能、停止和工程精度边界验证。模型内容质量、下载/离线、发布验收另计。

`project.yml` 是独立示例宿主的 XcodeGen 输入，`App/` 和 `RenderingTests/` 只属于该宿主。原型此前约 **146 MB `.build/`**、本次独立验证构建目录及生成工程都已忽略；不要强制加入 Git。可保存的是源码、测试、说明、回执、来源指纹和八张 PNG。
