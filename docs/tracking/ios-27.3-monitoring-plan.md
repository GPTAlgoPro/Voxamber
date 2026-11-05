# iOS 27.3 发布与维珀兼容性跟踪

设定日期：2026-11-05；当前项目方案校正：2026-11-06；时区：Asia/Shanghai。

## 当前项目优先

以根目录 [AGENTS.md](../../AGENTS.md)、[原生实施记录顶部修正](../plans/2026-11-05-native-minicpm-app.md) 和 [结构化造型方案](../plans/2026-11-05-native-structured-generation-design.md) 为准。当前是通用离线 3D 建模产品 **维珀 / Voxamber**，bundle `com.kaisun.voxamber`，工程 `Apple/ThreeLiveStudio.xcodeproj` 已存在并在 `dev` 开发。

采用原生 Swift / MLX / Metal / Apple 框架；App 不含 Python、JavaScript / Boa 或其他脚本运行时。题材不设白名单；目标为 12GB+ iPhone 和自适应 Duo；端侧基础模型不得超过 8B。现有本地模型路径不依赖 Apple 系统模型开放，不能用旧计划阻止当前研发、重新建立工程或迁回早期建筑专用架构。旧 [12 月设计](../plans/2026-12-iphone-offline-xcode-design.md) 仅保留历史。

## 已确认的官方基线

Apple 2026-10-31 公告计划于 12 月随 iOS 27.3 推出中国区首批核心系统功能，未给出具体正式日期，也未明确确认第三方 Foundation Models API 同步开放。2026-11-06 检查仍为 `iOS 27.3 beta (24C5037i)` 和 `Xcode 27.3 beta (27C5020n)`，不能触发正式版提醒。

## 调度与检查

沿用任务当前保存的调度：**每日 00:00**。初始安排为每小时；2026-11-06 读取实际任务时已为日检，本轮同步任务内容时保留了该调度及通知配置，不覆盖后来调整。

- 先查 Apple Developer Releases；若出现候选正式版，打开对应官方说明，核对正式版版本、build、日期，排除 Beta / RC / Developer Preview。
- 另查对应正式 Xcode / SDK 兼容性、中国区资格与 SystemLanguageModel 文档。来源不可访问只记“本次未知”，保留最后可信状态；不把错误当作未发布或模型不可用。
- 首次确认正式版后，在当前对话提醒更新，给出官方链接、build 和日期；不自行升级 OS、切换 Beta、改变账户或签名配置。
- 分别记录正式 OS、中国区第三方 API 资格、目标机模型 availability、真正断网生成结果，不以其中之一代替其他证据。
- 用 [状态记录](ios-27.3-watch.json) 去重，例行无变化仅更新检查记录。

这是本机当前对话定时任务，需要 Mac 开机并保持桌面 App 运行；离线、关机、排队和源站错误可能延迟检查，不能保证 Apple 发布瞬间送达。

## 正式版后与 12 月动作

1. 对现有 Voxamber 工程评估新 SDK / OS 兼容性，保留进行中的用户改动；不重建项目、不自动迁移架构。
2. Apple 系统本地模型仅作为可能新增的本地候选。使用前单独验证资格、中文结构化生成、复杂通用场景能力和实际性能；不引入 PCC 或云推理回退，不默认替换已使用的本地模型。
3. 包测试、Simulator、真机推理、离线完整旅程、archive/upload、Apple 处理及 TestFlight 安装可用性分别取证。历史构建回执不证明当前脏工作树构建通过。
4. 2026 年 12 月首次检查发出一次当前研发的阶段复盘和下一步建议，复用已有开发进度，不重新宣布开工或恢复旧建筑限定。

正式版提醒、现有工程兼容评估与 12 月阶段复盘完成后停止本发布跟踪；待验模型资格和设备事项保留在项目研发记录。如果无法停用，应明确记录实际状态。

## 一手来源

- [Apple：中国区推出公告，2026-10-31](https://www.apple.com.cn/newsroom/2026/10/apple-intelligence-features-are-coming-to-users-in-china/)
- [Apple Developer Releases](https://developer.apple.com/news/releases/)
- [Apple Intelligence 支持说明](https://support.apple.com/zh-cn/121115)
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Xcode 与 SDK 系统要求](https://developer.apple.com/xcode/system-requirements)
- [桌面定时任务运行条件](https://learn.chatgpt.com/docs/automations?surface=app)
