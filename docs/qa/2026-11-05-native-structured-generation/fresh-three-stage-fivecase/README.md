# 五题材全新三阶段实验：尚不具备正式移植条件

五个原固定请求各只执行一次，按机器人、台灯、鲸鱼、飞行器、椅子的顺序，每个阶段都真实新生成。一个模型进程、一次模型载入、15次调用，三阶段上限均3072 tokens，各例共用180秒期限；没有缓存答案、预设、重试、手工坐标或结果修复。实际进程墙钟 127.943s，无180秒超时；卸载后MLX active4000 bytes/cache0。

| 题材 | 新调用 | 整例耗时 | 原生/导出状态 | 真实结果 |
| --- | ---: | ---: | --- | --- |
| robot | 3 | 26.96s | 真实资产+双图 | 双眼重叠，头非正方体 |
| lamp | 3 | 11.93s | 真实资产+双图 | 高度0.994m而非约0.8m |
| whale | 3 | 49.55s | 拒绝，无替代资产 | geometry达到3072，拒绝且buffer不可见 |
| aircraft | 3 | 17.82s | 拒绝，无替代资产 | p1.height=3.5m超过2.5m门禁 |
| chair | 3 | 20.62s | 真实资产+双图 | 座面约0.994m，实心底框0.5m高 |

已逐张查看六张实际PNG：

- 机器人：[前视](robot/front.png)、[三分之四](robot/three-quarter.png)。提纲明确Left/Right眼，但新semantic阶段给两眼都选择center；几何两球完全同中心，故只见一眼。可用X spread0.155m，不是zeroSpread或renderer假设。头的0.35×0.25×0.35m也不满足立方体要求。
- 台灯：[前视](lamp/front.png)、[三分之四](lamp/three-quarter.png)。本次灰色圆柱底座/支杆、红圆锥罩等类型正确，但总高约0.994m，超过约0.8m目标24.25%；罩宽0.12m、高0.25m，轮廓尖细。
- 椅子：[前视](chair/front.png)、[三分之四](chair/three-quarter.png)。四腿与后置靠背正确，但实心base_frame高0.5m，座面约0.994m，明显偏离约0.45m要求。

飞行器实际raw保留：第一个lathe机身p1的dimensions.height=3.5m，违反Core0.02...2.5m规则；该节点profile12点，两翼各7点。没有缩放修复或渲染被拒输出。

鲸鱼只观察到1857输入→3072输出、SDK outputLimit、grammarTerminated=false，42.111s；并非180秒超时。正式generateJSON在长度拒绝时没有把buffer返回给runner，因此不能确定实际cutoff node、profile/vertices/triangles个数，甚至不能由metadata单独区分开着数组或完整JSON后继续空白。首个规划节点whale_body是mesh，后续另有mesh和三处extrusion；这些是模型计划及schema容量，不是已观察生成计数。不得伪称数组跑满。详见[失败诊断](failure-diagnostics.json)。本次没有重放取raw。

模型先规划自由几何点/面数量、再用exact counts约束数组，是值得进一步检验的合同方向；本批还不足以证明鲸鱼的具体截断原因，也不会解决飞行器标量范围或机器人语义选错。未来获授权的新诊断应在同一次Direct调用中先保留length raw，再做同等formal验证，不应重试本次失败当作验收。

完整[视觉审阅](visual-review.json)、[每阶段结果](results.json)、[来源](provenance.json)、[运行前声明](protocol-before-generation.md)、[运行后核验](verification-after-run.json)均保留。三份GLB均零错误/警告，USDZ导入与格式检查通过，但完整原请求接受数为0/5。两个明确要求自由几何的非模板题材均没有接受资产，不能宣称通用自由建模通过。

本版明确是单root连接式单物体prototype。已测outline system实际为中文并原样复用，semantic为原简短英文，geometry为原ScenePrompt+声明的anchor语义。通用求值器SHA不变，生产源码/旧QA/模型stat身份保持不变，没有App移植、手机操作、模型下载或发布。
