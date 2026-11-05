# 小型语义能力对照：两个条件均正确 6/6

预先声明两种诊断条件：同一个简短英文 system、同一份冻结模型的六个 child id/face/purpose 行，同一 `QwenEngine.generateJSONDirect`、768 token 上限、prefill128、greedy；唯一推理参数差异是传入 exact-N schema 或 `jsonSchema=nil`。没有长 ScenePrompt、原椅子请求、尺寸表或几何生成。seat 的实际冻结 purpose 中本来含 Y=0.45m，这段模型原文保留，没有加入额外坐标。

| 条件 | 输入/输出 token | 首 token | 调用耗时 | 原始 JSON/ID/标签 | 用途匹配 |
| --- | --- | ---: | ---: | --- | --- |
| 结构约束 | 339 / 65 | 0.699s | 1.516s | 通过 | 6/6 |
| 无结构约束 | 339 / 65 | 0.324s | 0.946s | 通过 | 6/6 |

两份原始输出逐字节相同（223 bytes，SHA256 `2aad6a466da5eb7041b0688ffc8296df17decad771dec1f8dec523e1a6eabd32`）：seat=center、backrest=back、leg_1=frontLeft、leg_2=frontRight、leg_3=backLeft、leg_4=backRight。对照实际 purpose 的人工 QA 表仅在运行后建立，未给模型逐 ID 答案，也未修改任何输出。严格解码没有移除 fence、补括号、改标签或做别名转换。

这个小样本证明模型在简短语义任务下确实能作出这六项选择，而且小型 native grammar 没有把答案强制成 center。它支持继续评估“语义步骤选择锚点，几何步骤固定已选锚点”的方案。它没有单独证明长流程失败由哪一个因素造成，也没有排除完整复杂 schema 路径的其他问题；更不等于椅子或通用 3D 创作通过。

完整[相同请求](identical-request.json)、[结构约束原始输出](structured/response.raw.txt)、[无约束原始输出](unconstrained/response.raw.txt)、[详细结果](results.json)、[人工语义核验](semantic-review.json)及[来源](provenance.json)已保存。两次调用属于预声明条件，不是失败后的重试。正式源码与旧 QA 未改，未生成几何、操作手机、下载新权重或执行发布。全流程 3.424s，卸载后 MLX active4000 bytes/cache0；均为 Mac 诊断数据，调用顺序与预热可能影响计时。
