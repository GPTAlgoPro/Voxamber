# 官方 MiniCPM5-2B-MLX 对照：原生可运行，未改善本产品质量

候选固定为官方 revision `8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3`，总参数2,516,756,480、affine INT4/group64。七项运行资产1,426,008,802bytes已按固定HF metadata验证；权重整文件SHA256为`c207798696a4a454e7ac211b25227625466c693335941cee8904fb922f295cc1`，附固定官方Apache-2.0许可。HF连接中断未通过校验，之后保留有效数据，以字节身份相同的官方ModelScope镜像补全，未使用残缺权重。[下载证据](candidate-download-verification.json)

实际native sanity通过：标准Llama973 tensors完整key/shape匹配，无旧mUP字段；实际ModelContext输入与官方Jinja含BOS/关闭思考前缀逐token相同；EOS配置[1,130073]，真实小回复在130073终止；首token取消并卸载约0.0366s、重载约0.460s、原generic Actor结构化小回复通过。这是Mac原生可运行证据，不是iPhone或3D验收。[sanity](native-sanity/sanity-result.json) · [真实模板与EOS](native-sanity/native-inspection.json)

与Qwen基线使用完全相同的28源码SHA、同一个二进制、逐字节相同的协议与preflight；只更换模型目录。原五个请求各一次、所有到达阶段3072cap/prefill128/greedy/thinkingfalse/compilefalse，共用每例180s期限。阶段失败就停止该例，不重试/修复/预设替代。

| 题材 | Qwen：调用/整例/状态 | MiniCPM5：调用/整例/状态 |
| --- | --- | --- |
| robot | 3 / 26.96s / asset | 1 / 3.78s / reject |
| lamp | 3 / 11.93s / asset | 1 / 2.15s / reject |
| whale | 3 / 49.55s / reject | 3 / 7.50s / reject |
| aircraft | 3 / 17.82s / reject | 1 / 4.23s / reject |
| chair | 3 / 20.62s / asset | 3 / 5.73s / asset |

Mini5进程墙钟23.884s，峰MLX 1,810,578,144bytes，卸载后 active4752bytes/cache0；Qwen峰MLX3,034,562,212bytes。不能把总墙钟比值当加速倍率：Mini5仅到达9个阶段而Qwen15个，生成长度/tokenizer也不同。

具体失败：robot的body.parent=body自环；lamp的cylinder_black.parent=自身；aircraft重复wing_left/wing_right ID，首重复位于index2；whale虽然三阶段JSON完成，tail_fins extrusion的四个profile点只有两个独立点且全共线，Core拒绝。仅chair导出，但[前视图](chair/front.png)和[三分之四视图](chair/three-quarter.png)实际是交叉竖板，不是可用椅子；seat高度0.45、深度0.1被当成厚竖块，腿接侧面/前后面，颜色为灰色。未修改原始数据。[精确诊断](failure-diagnostics.json) · [视觉检查](visual-review.json)

结论：候选的原生兼容性成立、观察内存更低；但同协议只有1/5原生资产、0/5完整请求接受，未胜过仍未达标的Qwen基线。此结果仅针对本次官方INT4+nonthinking/greedy工作流，不推出所有模式/任务的普遍模型排名。正式App和Apple素材包继续使用原Qwen，不选择新默认、不上传或部署新模型。没有手机操作，也没有新提示词/库版本/geometry修复或重试。
