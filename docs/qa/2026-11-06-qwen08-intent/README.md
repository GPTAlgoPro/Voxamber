# Qwen 0.8B intent helper：格式通过，三题完整语义均未通过

本记录只验证 Mac 上的文字意图辅助阶段，没有生成图片或三维模型、操作手机、写作品库、换模型或改生产源码。三个请求均为预先固定的合成测试，未翻译、修复、补答案或重试。

## 来源指纹的有限结论

本地使用 `mlx-community/Qwen3.5-0.8B-4bit@da28692b5f139cb0ec58a356b437486b7dac7462`。十项运行文件共 645,315,928 bytes，在本次原生执行前后均完整重算 SHA256；权重 625,229,487 bytes，SHA256 `f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e`。原始许可证另保留，不把下载碎片当完整资产。

该固定 revision 的 README 前置数据写 Base，正文写 post-trained 版本，已独立读取并保存事实与 card SHA，不能单靠该文案确定源权重。[卡片冲突](card-conflict.json)

官方 Instruct 固定 `2fc06364715b967f1860aea9cf38778875588b17`；Base 的公开 main 在探测时解析并固定为 `dc7cdfe2ee4154fa7e30f5b51ca41bfa40174e68`。两个官方 1,746,942,600-byte 文件的 metadata whole SHA 不同，header 形状/布局相同。本次没有下载两个完整官方文件；metadata 中的 whole SHA 也不是本次整文件实算值。[官方 metadata](official-metadata.json)

实际 HTTP206 只读取 header 和五个未量化 language-model norm，第一次直接比较加第二次转换比较合计 **274,208 bytes**。这里官方抽样 dtype 实为 BF16。按 pinned MLX Qwen35 的标准 RMSNorm `source + 1` 并做 BF16 round-to-nearest-even 后：

- 本地五个 tensor、共 4,352 元素与固定 Instruct **全部逐元素一致**。
- 与固定 Base 没有一个 tensor 完全一致，逐元素为 3,997/4,352 一致，355 个不同。
- 本地 conv1d 最后一轴已为 1；当前 sanitizer 不会把已经转换的 norm 再加一次 1。

这是抽样 norm 支持 Instruct 来源的实证，**不是全模型每个 packed quantized matrix 来源的证明**，也不是官方数值 golden parity 或 helper 质量证明。不据此自动修卡片、换模型或声称全部转换正确。[原值比较](origin-fingerprint.json) · [转换后比较](origin-normalized-norm-fingerprint.json)

公开原始来源：[量化固定 revision](https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit/tree/da28692b5f139cb0ec58a356b437486b7dac7462)、[官方 Instruct 固定 revision](https://huggingface.co/Qwen/Qwen3.5-0.8B/tree/2fc06364715b967f1860aea9cf38778875588b17)、[官方 Base 固定 revision](https://huggingface.co/Qwen/Qwen3.5-0.8B-Base/tree/dc7cdfe2ee4154fa7e30f5b51ca41bfa40174e68)。

## 一次真实受控辅助测试

实际编译并使用当前 `CreationIntentDecoder.swift` 的逐字副本、原 CreationIntent/error 类型片段和正式 QwenNative，未链接采样候选。系统与 schema SHA、15 项相关源/配置、二进制、请求与 rubric 在执行前固定，执行后全部匹配。规则为 512 output tokens、prefill128、greedy0、no thinking、当前 exact schema、early JSON stop、一个模型载入、三次 fresh 调用。[预声明协议](protocol-before-run.md) · [逐字请求](fixed-requests.json) · [执行前来源](provenance-before-run.json)

为保留同次原始文本，调用明确是 Direct + 逐字正式 QwenJSONObject + 逐字 CreationIntentDecoder，不冒称字面调用 generateJSON。每题 raw 在任何解码检查前落盘；没有额外试调用、预设或重放。

| 请求 | 单次耗时 | 格式/原解码器 | 完整辅助合同结果 |
| --- | ---: | --- | --- |
| 原台灯 | 2.257s | 通过，63 tokens | 失败：正/负提示仍中文，且正向回显禁用的 Y=0 坐标；颜色与主要组件保存成立 |
| 新螺旋蓝色贝壳花瓶金边 | 1.648s | 通过，64 tokens | 失败：仍中文；负向字段含所需金边、螺旋、贝壳、花瓶的中文否定描述，不是可接受英文 unwanted-concept list |
| 小提琴与独立琴弓两物体 | 1.633s | 通过，58 tokens | 失败：仍中文；正向保持两物体要求，但负向又重复同一所需构图 |

三题 title 均保留中文用户语言。主语/颜色/计数的部分保存不等于英文图像 brief 可用；不能把 JSON 3/3 当辅助阶段 3/3。花瓶的金边位置也没有明确保留为 rim；负向中文“没有…”的实际图像效果没有测量，不能伪称已经看到生成失败。这里只判定该字段不满足当前清晰英文列表合同。[逐项语义审阅](semantic-review.json)

模型载入 0.936s，完整进程 6.791s（含末尾文件复核），峰 MLX 651,414,135 bytes；卸载后 active 3,008 bytes、cache 0。均为 Mac 数据，不是 iPhone 时延、物理峰值、生成质量或整条流水线验收。[实际结果](results.json) · [执行后核验](verification-after-run.json)

当前解码器主要校验键/类型/长度/控制字符，并未验证英文语言或负向语义；因此它接受了这三份不满足 system 要求的结果。这是接入验收缺口与模型实测行为，不是证明 Base 起源、量化降质、后端错误或所有 0.8B 模型能力的因果结论。生产阶段应另行决定是否继续此 checkpoint；本任务没有自动更换或追加模型调用。
