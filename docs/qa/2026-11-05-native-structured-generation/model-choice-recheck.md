# 官方小模型重新核对

本轮唯一推荐比较官方 MiniCPM5-2B-MLX 与现有 Qwen3.5-4B，先做实际原生加载/模板/EOS sanity，再决定是否运行同一五例协议。模型默认、Apple素材包和正式代码均保持千问不变。

MiniCPM5-2B官方总参数2,516,756,480（不含embedding部分为1,981,982,720），2026-09系列，标准Llama架构、权重与仓库Apache-2.0。官方MLX affine INT4/group64权重1,416,035,216bytes，七运行资产合计1,426,008,802bytes，固定revision8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3。[模型卡](https://huggingface.co/openbmb/MiniCPM5-2B) · [官方MLX](https://huggingface.co/openbmb/MiniCPM5-2B-MLX)

当前固定MLX Swift LM3.32.3已有Llama实现且配置静态匹配，但必须检验实际量化tensor key/shape、RoPE、untied head、TokenizersBackend、独立chat_template.jinja的thinkingfalse以及EOS1/130073，不能靠架构名称判定已兼容。此模型无旧MiniCPM的mUP配置字段，不应套scale_emb/scale_depth。

官方V-Apps给GGUF版建议≥6GB RAM；官方LiteRT文档报告不同INT4量化在iPhone17Pro用Metal/CPU可初始化。这不是我们的MLX手机实测，也没有本MLX量化的iPhone峰值RAM证据。42层GQA在8K BF16 KV的静态计算约336MiB，此外还需权重、激活、临时buffer等；只说明12GB档具备候选可行性。[手机需求](https://github.com/OpenBMB/MiniCPM-V-Apps) · [不同LiteRT量化的设备证据](https://github.com/OpenBMB/MiniCPM/blob/main/docs/deployment/litert.md)

SALA总9,477,203,968超限，稀疏attention不是参数变少；旧MiniCPM4.1-8B总8,185,253,888高于严格8.0B。Qwen官方3.8目录仍只有27B/180B/2.4T及FP8，最小实际总27,781,427,952，不存在本轮能确认的官方≤8B3.8通用小模型。[官方目录](https://huggingface.co/models?author=Qwen&search=Qwen3.8)

现有Qwen thinkingbudget技术上有SDK钩子，但当前wrapper禁用；Qwen3.5 tagged协议没有已验证硬预算转换，JSON grammar还需等到final阶段才能开启。因此它不是现有开关的无成本比较，本轮不同时引入。

完整精确文件清单、metadata身份、许可来源、代码位置与证据边界见[JSON报告](model-choice-recheck.json)。对新模型的3D质量优势目前未知，不能从语言/代码榜单推出。
