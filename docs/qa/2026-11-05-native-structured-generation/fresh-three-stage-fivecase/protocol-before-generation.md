# 生成前声明：五个题材的全新三阶段端到端实验

机器人、台灯、鲸鱼、飞行器、椅子沿用原五个固定请求，每例只运行一次。每个到达的阶段都真实新生成：部件提纲→仅用该提纲实际child id/face/purpose的新语义锚点→固定实际模型计划的新几何。没有历史 response、预设、重试、手工坐标或输出修复。单个模型只载入一次，各调用使用原生 Direct 的全新 KV；三阶段 token 上限均为3072，保留32parts、全部8primitive、完整geometry/material/rotation与根placement合同。

现有已测试 outline system 实际是中文；本批原样复用，不冒称已测过英语 outline，也不临时翻译调优。semantic system 是原已测试简短英文；geometry system 是原 ScenePrompt.system 加已声明的锚点协议。具体请求、系统和schema会逐阶段保存。

此版仍是单root、连接式单物体实验范围，不宣称通用多对象森林合同已经完成。通用 AnchorProtocol evaluator 保持同一源码 SHA，仅按显式typed relation/anchor和实际旋转/freeform AABB求值，不按名称或题材猜位置。原有center-pass位置门禁、zero-spread以及AABB非表面接触限制继续适用。

每例共用180秒预算，不给每阶段重新180秒；取消必须等待当前原生producer收束，再进入后续case。同步原生CPU/renderer操作在步骤间检查期限，实际超时和清理耗时照实记录。阶段失败保留原始证据，停止该例后续阶段并进入下一例。有效才生成真实mesh、GLB/USDZ和前/三分之四PNG，无有效资产时不展示替代图。

运行后逐张审阅结构、比例、连接、几何自由度、原请求参数与材质。JSON/格式通过不代表视觉通过；座高、机器人肢体/眼睛、台灯形状/高度、鲸鱼曲尾/鳍/自由轮廓、飞行器机翼/推进器/自由轮廓都按原实际请求判断，不由native helper硬编码这些对象角色。

只使用ignored新runner和新QA目录。正式App/Core/Engine/提示词/权重不变，不操作手机、账户或发布。
