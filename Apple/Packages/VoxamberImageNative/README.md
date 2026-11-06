# VoxamberImageNative

独立原生 SDXL 图像 SDK，尚未接入正式 App。真实推理实现来自 Apple `ml-stable-diffusion` 固定提交 `ea2805dc1945be20561c77e5f6d1d9a5a637cda2`；没有 Python、JavaScript、MLX 或外部 Tokenizers 依赖。

```swift
let engine = ImageEngine()
let task = Task {
    try await engine.generate(
        positivePrompt: englishPrompt,
        negativePrompt: englishNegativePrompt,
        seed: 93,
        resourcesURL: extractedAndChecksumVerifiedResourceDirectory
    )
}
let pngData: Data = try await task.value
// Cancel with task.cancel(); still await task.value before starting another model stage.
```

返回一个实际 **768×768 PNG Data**，不会替换为占位图，也不会在 SDK 内缩成 512。中文意图翻译、前景分割/白底 512 处理和形体生成由上层串行协调器负责。提示词超过原生 77 token（含开始/结束标记）时明确拒绝，不截掉尾部意图。

默认 20 步、DPM-Solver++、guidance 7.5、`cpuAndNeuralEngine`、`reduceMemory=true`、SDXL VAE scale 0.13025。可调整步数、guidance、调度器和计算单元（PNDM 至少 2 步）；静态模型和输出尺寸仍为 768。每个 actor 实例串行执行请求，上层还必须保证各模型阶段及多个实例之间不并发。

计算单元选项用于文本编码器与 UNet；保留上游 VAE decoder 的 `cpuAndGPU` 配置，不宣称整个管线仅在 Neural Engine 运行。

资源须先由上层下载、解压并核验摘要。`SDXLResources.validateLayout` 只检查目录/文件结构；分词检查只证明可读及 token 范围，不能证明权重身份或模型兼容性。该 SDK 没有下载、签名校验或模型托管功能。

- 官方包：`apple/coreml-stable-diffusion-xl-base-ios`
- 固定修订：`ef92c54fe816c826f5328709b545338518d08db7`
- [精确下载 URL](https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios/resolve/ef92c54fe816c826f5328709b545338518d08db7/coreml-stable-diffusion-xl-base-ios_split_einsum_compiled.zip)
- 压缩包：**3,052,964,832 bytes**
- 远端 LFS 声明 SHA256：`0e6b8d0ae7a1990f0cd31b5bbc8de600c096e54369add395ef21042832424faa`

权重没有随包提供或在本次验证中下载；远端摘要不是已完成本地文件核验的声明。解压资源目录应直接包含 `TextEncoder.mlmodelc`、`TextEncoder2.mlmodelc`、`UnetChunk1.mlmodelc`、`UnetChunk2.mlmodelc`、`VAEDecoder.mlmodelc`、`vocab.json`、`merges.txt`。可接受一个完整 `Unet.mlmodelc` 替代双 chunk，但部署资产身份仍须由上层核验。Refiner、VAEEncoder 和 SafetyChecker 资源明确拒绝；不加载 PBR/额外分割模型。

调用 Task 的取消状态传递到加载阶段检查、每一步 denoising 和官方 Bool 回调；所有成功、失败、取消路径均在返回前卸载资源。同步 Core ML 模型加载/预测不能被强杀，取消须等当前调用结束；没有承诺真机停止时间或卸载后的立即内存回落。

已完成 Mac 编译、**11 项无权重测试**和 arm64 / iOS 26.0 generic 编译。测试涉及 BPE、token 限额、结构资源准入、失败/取消清理及独立 ImageIO 格式转换；测试驱动不返回假生成图。尚未验证真实 SDXL 推理、图像质量、≤6 GiB 峰值、热稳定性、离线资产流程或端到端形体结果。旧 Apple CBLAS `cblas_saxpy` 弃用警告保留，不影响本次编译。

本包源码使用 [Apple MIT 许可](LICENSE.md)，保留 [上游致谢](ACKNOWLEDGEMENTS-APPLE)。模型权重受独立的 [SDXL OpenRAIL++ 许可](MODEL-LICENSE-SDXL.md)约束；FP16-fix VAE 的来源与说明见仓库 `docs/prototypes/2026-11-06-native-neural-pipeline/image-backend/`。Swift 源码许可不代替权重许可。

## Canonical CLIP tokenizer adaptation

The native BPE now uses the official CLIP regex boundaries and reversible UTF-8 byte alphabet, preserving Apple copyright and documenting the OpenAI fixed3bee281 MIT reference in canonical-tokenizer-provenance.json and LICENSE-OPENAI-CLIP. The old Apple whitespace-only segmentation is not exposed as a product option. No model, prompts, seeds, image options, driver, CFG, scheduler, prewarm or resource lifetime behavior changed in this condition.

Pure CPU golden vectors cover the exact returned lamp/vase English strings, numbers, punctuation, hyphens, contractions, abbreviations, empty negatives, special tokens, whitespace and valid NFC Unicode; both SDXL pad conventions must match complete reference IDs. Small test resources are a declared selected merge closure, not a model tokenizer substitute. A separate CPU check uses the actual full49408-vocab/48894-merges files. Production intent is normalized printable ASCII English. Full ftfy repair of malformed Unicode or HTML entities is not implemented or claimed. Neural image improvement remains unverified until the separate one-image controlled gate.
