# 维珀 Voxamber · 原生离线 3D 创作

正在开发的 iPhone / iPhone Duo 通用建模 App，应用类别为生产力。用户自由描述创作内容，不设建筑、家具等题材白名单；示例只作灵感起点。

- 中文描述 → 本地模型理解 → 原生几何生成 → RealityKit 预览 → 逐部件编辑 → 本地保存 / 恢复 → GLB、USDZ 导出和系统 AR 预览。
- 正式端侧模型上限 **8B**，目标设备 **12GB 及以上内存**。当前选型候选为 Qwen3.5 4B INT4 / Swift MLX / Metal；官方当前 Qwen3.8 最小公开模型为 27B，不能误称存在官方 3.8 4B。
- App 不包含 Python、JavaScript 解释器或外部脚本环境。原生 Swift 几何与导出包直接产出模型文件；Mac 开发工具不进入 App。
- 新品牌、通用几何玻璃图标和 App Store Connect 新记录已准备，bundle 为 `com.kaisun.voxamber`。尚未完成上传或宣告 TestFlight 可用。

工程：[Apple/ThreeLiveStudio.xcodeproj](Apple/ThreeLiveStudio.xcodeproj)。实施与当前边界：[实施记录](docs/plans/2026-11-05-native-minicpm-app.md)。核验回执与测试证据：[原生 App 验证目录](docs/qa/2026-11-05-native-app)。

原有 Three-Live Mac 几何实验保留在下方，属于研发历史和导出对照，不限定 App 的创作题材。

---

# 琉金重檐殿 · Three-Live Apple 实验

已在 Apple M3 Max / macOS 27.2 上，用 **Google Three-Live v1.2.3 官方原生编译器**从零生成可复现的中国宫殿风格模型。模型含双层曲面庑殿顶、168 条瓦垄、抽象脊兽、20 根柱、斗拱、格扇门、灯笼、三层石台基、栏杆及正面台阶。

这是太和殿风格的原创桌面模型，不是文物测绘复原。当前模型宽 1.008 米、高 0.42216 米、深 0.81936 米，Y 向上，底部为零。

![最终 USDZ 的实际模型渲染](artifacts/palace-usdz.png)

## 查看成品

- [GLB 模型](artifacts/palace.glb)：约 0.86 MiB。
- [Apple 兼容 USDZ 模型](artifacts/palace.usdz)：约 0.61 MiB。
- [完整 iOS / macOS 管线研究](docs/three-live-apple-pipeline.md)：固定版本源码、Swift API、执行限制和导出缺陷。
- [运行及哈希记录](artifacts/validation.json)、[GLB 校验](artifacts/glb-validation.json)、[RealityKit 原生回读](artifacts/realitykit-validation.json)。
- [Mac 原生 Preview 截图](artifacts/macos-preview.png)、[跨格式视觉与浏览器验证](artifacts/visual-verification.json)。

本地浏览器交互预览：运行 `python3 scripts/serve.py`，打开 <http://localhost:8765/>。可旋转、缩放、下载两个格式，以及在 Worker 沙箱中重新编译同一场景源码。

在同一 Wi-Fi 的 iPhone Safari 中，以这台 Mac 的局域网地址替换 `localhost`，点击页面的“Apple AR 预览”。**本轮已完成 Mac 生成、原生读取和实际显示；尚未完成 iPhone 真机 AR 放置验收。**

## 从零重跑

需要 Apple Silicon Mac、Python 3、Node.js、Swift/Xcode，以及 Apple USD Tools 中的 `usdcat`、`usdzip`、`usdchecker`。本机已经具备。初次下载需要联网；安装后几何生成、编译、校验和预览都使用本地资源。

```sh
cd /Users/kaisun/Three-Live
python3 scripts/setup.py
npm ci --ignore-scripts --no-audit --no-fund
python3 scripts/run_pipeline.py
python3 scripts/serve.py
```

`setup.py` 下载固定的官方 arm64 CLI 和 Web bundle，并与 GitHub Release 提供的 SHA-256 digest 核对；校验结果见 `tools/release-receipt.json`。`upstream/` 为固定 tag 的官方参考源码，生成器运行不依赖该 checkout。

实际路径为：**当前 AI 编码会话编写参数生成器 → Python 预计算复杂网格和法线 → 场景 JavaScript → 官方 Rust/Boa 沙箱 → GLB 与原始 USDZ → Apple 元数据修复 / USDC 打包 → 校验 / RealityKit / Preview**。没有下载输入模型、生成模型权重或贴图，也没有使用 Blender 或通用 Three.js 导出器代替 Three-Live 生成。几何预算集中在 17 个按材质合并的网格，共 26,150 顶点、22,040 三角形。

原版 v1.2.3 的 USDZ 缺少 `MaterialBindingAPI` 声明，Apple 严格校验会失败。`run_pipeline.py` 保留 `palace-raw.usdz` 与 `palace-from-glb-raw.usdz`，补齐材质绑定声明、明确 `subdivisionScheme = "none"`，再转成 USDC 后打包为 `palace.usdz`；最终文件通过严格检查。两种官方原始导出路径的字节完全相同。

## 编辑和验证

修改 [generate_palace.py](scripts/generate_palace.py) 中的建筑参数和材质，再执行完整管线。生成器会检查法线、退化面、重复面、面朝向、脚本大小与几何配额。原生脚本仅约 1 MiB，增加细节时必须继续检查限制。

`run_pipeline.py` 同时执行 Khronos glTF Validator 和 Apple 严格检查，并调用 [Swift RealityKit 检查器](scripts/check_realitykit.swift)，比较两个格式的网格数、三角形数和实际米制包围盒。首次需要时自动编译 Swift 检查器。

下面的 Blender 命令只用于独立导入和对照渲染，不参与模型生成：

```sh
/Applications/Blender.app/Contents/MacOS/Blender --factory-startup -b -t 8 --python-exit-code 1 --python scripts/render_models.py -- artifacts/palace.glb artifacts/palace-glb.png
/Applications/Blender.app/Contents/MacOS/Blender --factory-startup -b -t 8 --python-exit-code 1 --python scripts/render_models.py -- artifacts/palace.usdz artifacts/palace-usdz.png
```

输出 PNG、导入统计 JSON 及含相机 / 灯光的 `.blend` 检查文件。两种格式的对照图使用同一相机及灯光，导出模型中不包含这些工作室设施。

上游项目仍为 Developer Preview / Alpha。[官方仓库](https://github.com/google/three-live)、[本次固定版本](https://github.com/google/three-live/releases/tag/v1.2.3)。

## iOS 27.3 跟踪与 2026 年 12 月研发

已设定当前对话的每小时发布跟踪；首次确认 iOS 27.3 正式版后提醒更新，并准备本项目的 Xcode 工程。完整安排见 [发布跟踪计划](docs/tracking/ios-27.3-monitoring-plan.md) 和 [iPhone 离线 Xcode 工程设计](docs/plans/2026-12-iphone-offline-xcode-design.md)，实际里程碑保存在 [跟踪状态](docs/tracking/ios-27.3-watch.json)。

Apple 已公告首批中国区 Apple 智能功能计划随 12 月的 iOS 27.3 推出；第三方 Foundation Models 的中国区资格及具体 iPhone 本地模型可用性仍须独立验证。12 月先推进工程和确定性几何，模型集成以实际可用为门槛。本机跟踪需要 Mac 开机并保持桌面 App 运行。
