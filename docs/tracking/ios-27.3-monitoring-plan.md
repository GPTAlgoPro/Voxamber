# iOS 27.3 跟踪与 12 月研发安排

设定日期：2026-11-05；时间基准：Asia/Shanghai。用户已授权跟踪正式版发布、提醒更新、在本项目设计 Xcode 工程，2026 年 12 月正式研发。

## 当前已确认的发布基线

Apple 在 2026-10-31 的中国新闻稿中确认：首批核心 Apple 智能功能计划随 **12 月的 iOS 27.3 正式版**面向中国用户推出。尚未给出具体正式发布日期。2026-11-03 发布的仍是 `iOS 27.3 beta (24C5037i)` 与 `Xcode 27.3 beta (27C5020n)`。

这份新公告优先于当前仍写“尚不可用”的旧支持页面。公告涉及首批系统功能，没有明确承诺第三方 Foundation Models 的中国区调用资格；不能据此直接宣布本项目的本地模型依赖已经就绪。

## 跟踪规则

- 每小时检查官方发布列表，发现候选正式版后打开对应发布说明，核对版本、build 和日期；Beta、开发者预览与 RC 均不能触发正式版发布完成状态。
- 同时跟踪中国区功能说明、Foundation Models 开发者文档，以及对应 Xcode 正式版和 SDK 兼容性。
- 首次确认 27.3 正式版后，在当前对话报告更新建议、官方链接、版本及 build；提示在 iPhone“设置 → 通用 → 软件更新”中更新。这里只提醒，不代替用户操作系统升级，也不切换 Beta 通道。
- 记录三个独立事实：OS 正式版已发布、中国区第三方本地模型 API 已开放、目标 iPhone 的 `SystemLanguageModel.default.availability` 实测可用。某一项完成不能代替其他项。
- 使用 [状态记录](ios-27.3-watch.json) 去重并保留证据。网页临时错误不等于“尚未发布”；下次检查应重试并保留最后一次可信状态。

这是本机当前对话的定时跟踪；需要 Mac 开机并保持桌面 App 运行。离线、关机、任务排队或来源不可访问会延迟检查。目标是在可运行条件下每小时发现一次发布变化，不是 Apple 的即时推送。

## 发布后工程动作

1. 根据 [Xcode 工程方案](../plans/2026-12-iphone-offline-xcode-design.md) 在 `Apple/` 中准备 `ThreeLiveStudio.xcodeproj`；读取当前文件和 Git 状态，保留用户正在进行的工作。
2. 对照正式 Xcode / SDK 重新核对 Foundation Models API 和 Three-Live 依赖，再固定版本。将 USDZ 修正编入本地编译器，移除手机对 Python、Mac USD 命令和在线 CDN 的依赖。
3. 区分“工程已建立”“本地构建通过”“已安装手机”“飞行模式端到端通过”，逐项记录。没有实际执行的层级不得标为完成。
4. 如果届时早于 12 月，只准备工程与验证入口；正式功能研发从 2026-12-01 起推进。

## 12 月启动

12 月首次检查时发出本项目研发启动报告，不重复发布同一提醒。即使正式版延期，仍可先推进工程骨架、共享几何、参数编辑和双格式导出；中文模型集成保留在实际可用性门槛后，不用云端服务替代。

正式版更新提醒、工程准备和 12 月启动报告都完成后，停止这条发布跟踪。未解决的模型资格或设备验收问题写入研发计划；若该跟踪无法自行停用，应明确报告，而非假定已停止。

## 一手来源

- [Apple：中国区推出公告，2026-10-31](https://www.apple.com.cn/newsroom/2026/10/apple-intelligence-features-are-coming-to-users-in-china/)
- [Apple Developer Releases](https://developer.apple.com/news/releases/)
- [Apple Intelligence 支持说明](https://support.apple.com/zh-cn/121115)
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Xcode 与 SDK 系统要求](https://developer.apple.com/xcode/system-requirements)
- [桌面定时任务运行条件](https://learn.chatgpt.com/docs/automations?surface=app)
