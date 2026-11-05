# 三个正式拒绝请求的独立诊断

这不是原验收响应的“取回”或成功重试：原`generateJSON`已经丢弃拒绝缓冲。本次对chair/whale/aircraft各另做一次同配置`generateJSONDirect`调用，用原QA`request.json`逐字相同system/user、maxTokens3072、prefill128、temperature0、thinking=false。原来的三项验收仍是拒绝，不生成替代资产。

原始捕获只放在ignored`Apple/.build/production-rejection-raw`。本目录保留固定合成请求的输出证据；三份都没有think标签，无用户内容、环境数据或凭据。见[diagnosis.json](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/rejection-diagnostics/diagnosis.json)、[analysis.json](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/rejection-diagnostics/analysis.json)、[source-provenance.json](/Users/kaisun/Three-Live/docs/qa/2026-11-05-production-quality/rejection-diagnostics/source-provenance.json)。原始字节与QA副本的SHA可核对。

| 案例 | 实际生成token | 返回UTF-8 | 16KB门禁 | 具体文本拒绝原因 |
| --- | ---: | ---: | --- | --- |
| chair | 3072 | 8352 B | 未超 | 达到配置输出上限，JSON停在下一部件dimensions.depth冒号之后；EOF。未补任何字符的prefix已能逐个解出43个完整node，另有第44个id，已超过32node合同。 |
| whale | 1217 | 2860 B | 未超 | 没有达到3072上限；profile第二个控制点前多一个双引号，约303位置数组语法错误。返回尾部有正常的]}，不属于“只差更多token”的情形。 |
| aircraft | 3072 | 5005 B | 未超 | 达到配置输出上限，停在不断追加lathe.profile点的一个新[。未完成的第一个profile已有221个完整二维点（上限64），且声明height4.5（部件上限2.5），即使补长输出也已经违反合同。 |

三项均观测到`native_generation_complete`→`raw_stream_finished`→`direct_finished`，无180秒超时、无取消。不是“引擎没有输出”，也没有证据把它归为素材损坏或A19算子不支持。SDK公开实现表明TokenIterator达到maxTokens后结束；3072普通token且正常返回、末尾JSON未闭合可据此判为达到配置上限。1217一项未暴露实际EOS/unknown细分，不能补造stopReason。

## 语法位置

鲸鱼中的实际片段是：

```text
"profile":[[0.2,0],"[0.25,0.35],...
```

profile合同需要二维数值数组`[[Float,Float],...]`，这里多一个引号，Foundation报告`Badly formed array`，Python独立定位也在约303字符处失败。没有删掉该引号、补括号、修正尺寸或重排控制点来把它算成可接受模型。

椅子和飞行器末尾分别停在：

```text
..."dimensions":{"width":0.02,"height":0.02,"depth":
... [22.9, 3.16], [
```

具体字节见对应`*-synthetic-output.txt`。两项都存在超规划预算的先行问题，而非单纯预算太小：椅子43个完整node>32，飞行器221个控制点>64且height4.5>2.5。不能据此只把输出上限调大就宣称修好。

## 因果边界

- 这三次诊断与原正式拒绝使用同源码、同权重、同提示与生成参数，但原拒绝buffer未保存，**不能证明是原响应的逐字节重放**。同配置拒绝得到重现，原验收结果不改写。
- 文本语法失败发生在ScenePlan/native geometry之前，因此没有后续模型保存或导出失败可以归因。部分prefix字段明显不符合ScenePlan合同，只作分析，不把partialJSON修好后用于验收。
- 本次记录支持分开处理“响应闭合/终止预算”“规划复杂度/取值约束”“返回文本的JSON语法”三类问题；不能用统一的增加token或替换素材解释全部情况。
- 这是Mac诊断，不是手机停止/清理问题的修复证据；不与build3窄范围热修混淆。
