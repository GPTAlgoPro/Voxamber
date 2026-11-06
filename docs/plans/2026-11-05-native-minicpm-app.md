# 最新用户纠正（2026-11-06）

用户明确要求的是 Google Three-Live 开源系统的本机原生建模流程。此前转向“图像模型 → 混元网格”的实施是代理的架构偏离，不能作为目标交付；相应上传已安全中断，实验大资源已清理。Three-Live 的程序化建模表达能力、原生手机执行和通用题材是后续工作的依据。太和殿只作复杂几何回归样例，不限定创作题材。

下方“Rust/Boa 编译器已经被这些要求替代”是此前代理的解释，并非用户授权放弃 Google Three-Live。官方编译器本身含 Boa 场景脚本沙箱；继续集成时须明确其与用户“不要内嵌 Python 之类脚本”的边界，不能把自写 Swift 导出器称为 Google 编译器移植，也不能不说明内部执行方式。

原宫殿 PoC 是编码代理编写的宿主参数化几何，经官方编译器输出；它没有证明手机上 ≤8B 模型已经能自主生成同等场景。后续须分别验证场景创作、编译器和手机端到端能力。

清理回执：`docs/qa/2026-11-06-experiment-cleanup/verification.json`。保留最新作品恢复备份与一份千问权重，禁止自动重建已废弃路线的百 GB 实验资源。

---

# 历史执行修正（2026-11-05，以上方最新用户纠正为准）

用户明确确认：通用 3D 建模、任意题材、非建筑专用；中英文名维珀 / Voxamber；Productivity；原生 Liquid Glass 与 Duo；设备准入 12GB+；端侧模型不超过 8B，面壁或千问由工程实测决定。下方早期方案中的建筑限定、1B默认模型、Rust/Boa 编译器已经被这些要求替代。

最终 App 走纯 Swift SceneSpec + 自由网格/轮廓 + 原生几何/GLB/USDZ；Swift MLX / Metal 本地语言模型；不含 Python 或 JavaScript 运行时。ScenePrompt 不含题材白名单。古建代码仅保留独立历史几何回归，不作为 App 工作流。

当下重点：通用造型的空间关系与曲面表达质量、真实 12GB iPhone 内存/响应、Duo 实际折叠姿态、Release 全流程与 TestFlight 可安装状态。每项必须独立取得证据，不把已有格式/模拟器测试作为全部完成。

---

# ThreeLiveStudio Implementation Plan

**Goal:** 在 Apple 中国系统模型可用之前，交付可离线完成中文建筑创作、原生预览、编辑、保存、GLB/USDZ 导出、AR 的 iPhone App，并通过 TestFlight 提供实机测试。

**Architecture:** SwiftUI owns navigation and persistent editing state. A pinned MiniCPM-V 4.7 1B native llama.cpp engine interprets Chinese into validated BuildingSpec JSON; pure Swift deterministic geometry feeds the patched native Three-Live compiler. Projects publish complete immutable revisions atomically; inference, compilation and downloads run outside the UI thread.

**Tech Stack:** iOS 26+, SwiftUI, RealityKit, Quick Look, CryptoKit, Swift Concurrency, native C++/Metal llama.cpp, Rust/Boa Three-Live v1.2.3.

## Scope and decisions

- Current Three-Live context is Chinese description → 3D creation. A clarification is pending about the product direction; current implementation follows that context. The user has explicitly confirmed foldable iPhone/Duo UI requirements.
- Reference only Snap3D's visual language; preserve its current working tree and product identity.
- Default model is 4.7 1B Q4_K_M, 672,003,584-byte language file, with pinned upstream revision and SHA-256. Text-driven generation does not download an unused vision tower.
- Model-generated parameters pass strict decoding and semantic constraints before compilation. No model-generated arbitrary executable source or network tools.
- Creation must be visibly identified as supported procedural palace/pavilion/tower creation. Do not advertise general photo-to-3D or unlimited arbitrary object generation.
- 8GB nominal RAM is the minimum inference eligibility; separately measure actual peak memory and timing. Connected 12GB iPhone evidence cannot alone establish 8GB iPhone smoothness.
- Duo uses proposed size/system adaptive containers; editor state is above layout changes. Verify closed/open/partially folded poses if available, and record unavailable evidence honestly.

## Implementation tasks

1. `Apple/Packages/CreationCore`: specification, prompt contract, curved roofs and architectural geometry, budget validation, deterministic output tests.
2. `Apple/Packages/MiniCPMNative`: fixed native engine, cancellable serial inference, grammar-constrained JSON and pinned model catalog; preserve licenses and source receipts.
3. `Apple/Packages/ThreeLiveNative`: source-fixed USD exporter, Apple slices, async native API, strict export smoke tests.
4. `Apple/ThreeLiveStudio/Models`: verified model download/import, progress/cancel/retry, storage checks, memory capability, safe deletion/unload.
5. `Apple/ThreeLiveStudio/Storage`: per-project atomic revision publishing, draft retention, hash-checked loading, existing revision protected on failure.
6. `Apple/ThreeLiveStudio/Creation` and `Preview`: Chinese prompt, presets, editable parameters, real stage progress, cancel, orbit/zoom, model statistics, system export/AR; prevent stale task publication.
7. App shell: blue/cyan/violet reference palette, native controls, Dynamic Type, VoiceOver, reduce motion/transparency, split expanded workspace with compact fallback.
8. Core/compilation/storage tests, Simulator UI journeys (phone/Duo), Release physical-device generation/offline/reopen/export checks; collect measurements.
9. Archive signed Release, inspect artifact identity/native payload/privacy, create new app record if needed, upload TestFlight, read back processing and beta access. No App Store review or public release requested.

## Acceptance evidence

Keep source/build/device/model hashes with outputs in `docs/qa/2026-11-05-native-app`. Track separately: package tests, simulator UI, physical inference/creation, offline cold launch, restore/export, 8GB hardware performance, Duo poses, archive/upload, Apple processing, TestFlight access. Mark the goal complete only when all requested delivery and evidence requirements are actually satisfied.
