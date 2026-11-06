# 正向英文合同新条件：两题解码通过，一题正向语义通过

这是旧三题失败后预声明的**新合同 condition**，不是修复旧 raw、隐蔽重试或新的独立留出集。旧 22 个冻结文件及其清单逐字不变。未修改生产代码来通过本轮，也没有换模型、生成图片/三维、操作手机或写用户作品。

## 预先固定的变更

唯一合同变更来自 Root 当前 CreationIntentDecoder：忠实正向英文翻译，positive ASCII 1–180，negativePrompt const 空；title 仍用户语言，明确排除仍须保留在 positive。新 source/system/schema/regression SHA 在调用前固定。原三个合成请求、十项完整权重、512/greedy0/prefill128/noThink、exact formal 校验与原解码器保持声明条件。[协议](protocol-before-run.md) · [精确请求](fixed-requests.json) · [合同 diff](condition-decoder.diff) · [执行前来源](provenance-before-run.json)

程序在模型载入前停在 armed stdin，parent 收到 live handle 后才启动唯一一批。实际一个模型载入、三次 fresh 调用，每题同次 raw 先保存再校验；没有额外 warm-up、翻译、补字段、输出修补或第二批。十文件在执行前后完整重算 SHA 均匹配。[结果](results.json) · [执行后核验](verification-after-run.json)

## 真实结果分层

| 请求 | 单次耗时 / consumed tokens | 当前解码器 | 正向语义与完整合同 |
| --- | --- | --- | --- |
| 台灯 | 3.328s / 66 | 拒绝 | 正向英文保留红锥罩/灰圆柱底座/细圆柱杆/可选球泡，但 241 字符超 180、缺 required negativePrompt；把 0.8m 含糊接在 base/floor 高度上，title 为英文 LED Desk Lamp |
| 蓝色螺旋贝壳花瓶金边 | 0.603s / 45 | 通过 | blue/vase/spiral/gold rim 保存，但 shell 被替成 spiral flower，title 为英文 Blue Spiral Flowerpot；不满足忠实主体要求 |
| 小提琴与独立琴弓 | 0.593s / 44 | 通过 | 正向英文正确保留一琴一弓、两个独立物体、完整入镜；这项正向核心语义通过，但 title 英文 Violin and Bow 仍违反用户语言要求 |

因此：**格式/当前解码器 2/3；正向核心翻译语义 1/3；完整含 title 语言的辅助合同 0/3。** 不能把三题可读英文等同三题忠实翻译，也不能把小提琴的正向进步抹掉。颜色、关系和可选球泡按原声明评估，没有新加木纹、姿态或维度阈值。[逐项审阅](semantic-review.json)

花瓶和小提琴的空 negative 是合同机械强制，不计“模型学会正确负向清单”。台灯根本未输出该字段，不能笼统计 3/3 const 成功。三题没有独立的用户排除句，因此没有证明一般排除处理能力。

## Native grammar 的实际边界

三次均观察到 pinned xgrammar 警告：同时给 pattern 与 minLength/maxLength/format 时忽略 length/format。ASCII pattern 不能被说成同时可靠约束了 180 字符。当前 decoder 的长度/字段集合检查仍然正确拒绝台灯。

台灯 metadata 为 jsonComplete、grammarTerminated=false，raw 是仅含 title/positivePrompt 的完整 JSON。它是完整 object，却不是完整意图合同；不能当作 schema-valid。警告直接解释了长度约束边界，但不能仅据这条日志断言 required 字段缺失的底层原因。缺失内容没有补回或再次生成。[grammar 观测](native-grammar-observation.json)

## 范围与时延

Mac 模型载入 0.909s，完整进程 5.734s（含末尾文件复核），峰 MLX 640,066,125 bytes；卸载后 active 3,008/cache0。16 个相关 source/config、exact decoder 和 binary 前后哈希一致。旧三题的来源指纹仍在[原条件](../2026-11-06-qwen08-intent/README.md)，未重新解释成全权重起源证明。

这是开发用三题辅助阶段观察，不是可靠性、iPhone 性能、真实图像、神经形状或整条 App 成功验收。未自动切模型或继续新调用。
