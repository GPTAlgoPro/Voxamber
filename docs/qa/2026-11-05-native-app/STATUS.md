# Voxamber 0.1.0 (2) — 2026-11-05

状态：内部 TestFlight 服务端可测试，仅本人已获邀请；尚未确认接受、安装或素材冷下载。App Store 1.0 仍为准备提交，无公共审核/发布。

## 已有实际证据

- Qwen3.5 4B INT4，纯原生 Swift MLX/Metal。官方 Qwen3.8 最小公开型号27B不满足8B档上限；不把3.5称最新整个系列。
- 同一12GB iPhone17ProMax、iOS27.2真实本地权重校验后，Direct单轮1031输入tokens首输出1.896秒；旧交互封装路径曾首输出前120秒超时。更换为实测单轮路径，不推断SDK具体内部哪句是原因。
- 优化版原生App实测椅子/机器人/台灯生成、几何、双格式、保存重开、RealityKit加载均通过；生成耗时55.26/62.88/14.90秒。峰值物理内存3,167,998,240字节；加载/卸载重复后MLX残留4–8KB。首轮加载跟随hash读取，不冒充冷磁盘测试。
- 推理层取消0.0526秒、卸载0.0455秒。之前“正在停止”长期显示是诊断任务未纳入App工作任务而停止处理仍改UI；build2已连接任务归属、停止原因和停止到空闲记录，后台完成收尾前保持lease。新版实际UI取消还需安装验证。
- Core40项、导出5项、存储/素材/取消状态20项通过；单屏iOS26创建/保存/分享/重开与大字号模型页2项UI测试通过。
- Duo展开双栏实际截图已取；多屏Duo自动化分享面板检查尚未通过（主屏截图为黑，是否驱动限制未定），不可把代码自适应或单屏通过冒充所有Duo姿态验收。
- Apple千问素材pack1 COMPLETE，15文件roundtrip和服务端hash匹配。新build签名中AppGroup、真实ExtensionKit下载扩展、3项BA声明、10模型文件pins一致；Apple真冷下载/取消仍待TestFlight。
- 独立官网6个中英文页面HTTPS200，支持/隐私/营销URL均已在ASC精确回读。
- 分发IPA26项审计通过，无QA/测试/解释器/权重残留；SHA256见distribution2-audit.json。Apple validation及upload成功，VALID/IN_BETA_TESTING、组/构建双向关联与本人邀请见testflight-build2-readback.json。

## 仍需验证/改进

1. 接受内部TestFlight邀请，安装0.1.0(2)；当前开发设备已断开，hotfix2没有经开发通道覆盖安装。
2. 在TestFlight用Apple托管入口首次冷下载、取消/重试、安装完整性及断网新建/修改/保存/导出。
3. 新版UI手动取消、后台取消与last-stop.json实际耗时；Duo闭合/半折/展开连续性和分享。
4. 通用AI造型质量仍为早期：接受任意题材并支持自由网格/轮廓，复杂对象语义/比例不保证。不能把合法JSON/格式验证当任意对象质量验收。

Git：开发始终dev；本次已发内部TestFlight为一次beta发布，main仅合入这一发布快照。模型/缓存/密钥不入仓库。
