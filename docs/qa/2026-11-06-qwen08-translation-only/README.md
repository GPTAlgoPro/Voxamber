# 单字段正向翻译：结构 3/3，完整语义 2/3

本轮是 Root 预声明的第三个窄合同条件，不修补前两轮 raw，不重放失败当作原条件成功。使用相同三条开发合成请求、同一份固定量化模型、512/greedy0/prefill128/noThink 与当前 exact Root source/schema。没有图片、三维、作品发布、手机、模型替换或额外推理。

模型只返回 positivePrompt；title 由原用户首行空白归一后 prefix40 原生生成，negative 原生固定空。这两项只算集成行为，不计模型语言或负向能力。ASCII/1–180 也只是结构闸口，完整英文语义仍逐项检查。[预声明协议](protocol-before-run.md) · [精确 system/schema/请求](fixed-requests.json) · [新 wire diff](condition-decoder.diff)

## 唯一批次

执行前 parent 收到 armed live handle，确认零模型载入/调用后启动授权 RUN。实际 **1 次载入、3 次 fresh 调用**。同次 raw 先保存，再应用正式 QwenJSONObject 和逐字 CreationIntentDecoder.decode(response,sourcePrompt:)。十项完整资源在前后均重算 whole SHA 匹配；16 个相关源/配置与二进制前后不变。前两轮 22+19 个冻结文件及清单也保持不变。[来源](provenance-before-run.json) · [执行结果](results.json) · [回读](verification-after-run.json)

| 请求 | 正向字符 / tokens | 单次耗时 | 完整正向语义 |
| --- | --- | ---: | --- |
| 台灯 | 180 / 48 | 3.462s | 未通过：保留主体/红锥罩/灰圆柱底座/细圆柱杆/可选球泡，但末尾 `with an overall lamp ` 为悬空短语，丢失明确的整体约 0.8m |
| 蓝色螺旋贝壳花瓶金边 | 72 / 21 | 0.767s | 通过：一个蓝色 spiral shell vase，golden rim 明确在 opening |
| 小提琴与独立琴弓 | 69 / 22 | 0.765s | 通过：一琴一弓、two distinct objects、fully in frame，未增加颜色材质门槛 |

三题 raw 都只有 positivePrompt，英文可读、解码通过、grammarTerminated=true。没有上轮 pattern+maxLength 警告。台灯没有达到 512-token cap，也不是 SDK outputLimit：它在 180 字符边界形成完整 JSON，但留下不完整意思。不能给其补上高度、缩写重跑或放宽量纲评分来计成功。[完整逐项语义审阅](semantic-review.json)

花瓶与小提琴的真实正向进步保留；同时不把结构 3/3 等同语义 3/3。这三条没有单独的用户排除句，未证明一般排除处理能力。英文字符集正确不保证主体、关系或数量正确，native title/empty negative 不算 LLM 成绩。

## 观察范围

Mac 模型载入 0.948s，完整进程 6.242s（含末尾文件复核），峰 MLX 730,820,596 bytes；卸载后 active 3,008/cache0。没有继续微调提示词、加长度、换模型或追加模型调用。是否另走 Apple Translation 或单独验证 MiniCPM5 是 Root 后续明确决策，不由本记录自动触发。

这是三条复用开发样本的 helper 阶段证据，不代表跨题材可靠性、iPhone 时延/内存、真实图像、真实神经网格或最终 App 验收。原量化来源的有限 norm 指纹证明仍见[首次条件](../2026-11-06-qwen08-intent/README.md)，未升级成全 packed 矩阵的起源证明。
