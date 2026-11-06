# 原生 SDXL 前段：构建记录

实现位于 `Apple/Packages/VoxamberImageNative`，公开 `ImageEngine.generate(positivePrompt:negativePrompt:seed:resourcesURL:options:onProgress:) async throws -> Data`。仅以已经表达意图的英文正/负提示词生成真实 768² PNG；不做自然语言意图推断、分割、尺寸修复或形体生成。

从 Apple 固定提交 `ea2805dc1945be20561c77e5f6d1d9a5a637cda2` 获取 27 个小 Swift 文件（163,058 bytes），每个都验证 Git blob SHA1；剔除 SD3/T5 的 4 文件后，再删除 SD1、ControlNet、安全检查和未使用 CLI/SD3 实现的 7 文件，保留 20 文件的 SDXL 依赖闭包。SDK 不依赖外部 `swift-transformers`，解决其 0.1.8 与现有 Qwen 1.3.0 的版本冲突。上游小量修改：从 SD1 文件提取公共类型；移除 SD1 aliases；BPE 错误由 `try!` 改为抛错；SDXL 必需的第一个编码器加载错误不再被吞掉；加载间、每步和 VAE 前增加取消检查。完整上游/本地指纹和削减清单位于包内 `upstream-provenance.json`。

保留真实 Apple BPE、双文本编码器、UNet、VAE、调度器、RNG 和资源管理。没有伪模型或占位输出。包装 actor 的测试注入入口只在模块内部，用于产生明确失败/空返回来验证取消和卸载；不返回合成图冒充模型图。唯一 2×2 合成图测试单独验证 ImageIO 编码格式，不经过推理成功路径。

保留上游 VAE 的 `cpuAndGPU` 计算配置；调用方设置的计算单元用于编码器与 UNet。文案不会把整个管线称为只用 ANE。

官方 SDXL iOS 包修订 `ef92c54fe816c826f5328709b545338518d08db7`：UNet 为平均 4.04-bit MBP，编码器和 FP16-fix VAE 为 FP16。压缩包 **3,052,964,832 B**，发布的 LFS SHA256 为 `0e6b8d0ae7a1990f0cd31b5bbc8de600c096e54369add395ef21042832424faa`。本次只查公开元数据，没有下载压缩包或任何权重。资源清单见 `resources.json`，下载后仍须实际核验。

[Apple 历史基准](https://github.com/apple-aiml-research/ml-stable-diffusion/blob/ea2805dc1945be20561c77e5f6d1d9a5a637cda2/README.md#performance-benchmarks)为 iPhone 15 Pro Max、iOS 17.0.2、20 步、768²、约 31 秒，采集于 2023 年 9 月。它不证明当前 App、当前设备、≤6 GiB 峰值或整条 3D 完成时间。取消只能在同步模型调用之间合作执行，实际停止延迟未验。

模型参数按组件盘点：UNet 2,567,463,684；两 CLIP 由公开配置计算为 123,060,480 / 694,659,840；完整 FP16-fix VAE 83,653,863。完整源模型保守上界 **3,468,837,867**，包含运行时不用的 VAE encoder；没有把编译资源字节除以位宽冒称精确参数。三组自行分发基础权重合计约 7.912B 的链路预算由整体方案记录；这不包含参数数不可知的 Apple Vision 系统前景模型，也不证明运行内存 ≤6 GiB。

源码 MIT 与原始致谢均完整保留；SDXL 权重保留独立 OpenRAIL++ 文本。官方包采用的 [FP16-fix VAE](https://huggingface.co/madebyollin/sdxl-vae-fp16-fix)标注 MIT，但整个 SDXL 包仍需遵守其模型许可。本包不提供 Refiner、SafetyChecker、PBR 或系统多语言模型的额外权重入口。

复现无权重验证：

```sh
swift test --package-path Apple/Packages/VoxamberImageNative
cd Apple/Packages/VoxamberImageNative
xcodebuild -scheme VoxamberImageNative -destination 'generic/platform=iOS' \
  -derivedDataPath ../../.build/VoxamberImageNative-iOSBuild \
  IPHONEOS_DEPLOYMENT_TARGET=26.0 CODE_SIGNING_ALLOWED=NO build
```

只验证独立包；正式 App、旧 Qwen/Core、手机、App Store Connect 和发布流程均未改变。后续须核验资产/真实推理/质量与热状态，并在切换到 Shape 前等待当前 Task 完成及资源卸载。PNG 768→Vision→白底主体 512 的处理由上层负责。
