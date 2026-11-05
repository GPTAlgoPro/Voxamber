资源生存期独立条件已执行：唯一SDK源改动是ImageEngine同步范围autoreleasepool（含validation/tokenizer、driver/load/generate/PNG/defer卸载，Data在pool外返回）。11项单测和iOS26 generic编译通过。一次同raw/seed93/20DPM/7.5/原计算单元/低内存配置的真实图像生成153.804s，随后一次真实Vision0.288s。两PNG SHA与旧vase逐字相同；旧所有产物不覆盖。

内存仍未解决。同步快照：image return/pool退出后1,466,991,816B；idle1s995,132,616B；再3s993,035,464B；Vision后与强制final均1,219,659,072B。640条每250ms采样/同步snapshot逐条持久，peak2,001,880,336B。final在停止并排空timer队列后采样，与最后JSONL行一致。

这只证明该Mac own-process当前阶段数据，未覆盖CoreML系统服务跨进程峰值或iPhone6GiB预算；不能据此接受Shape5.5GiB admission。旧实验没有相同idle/分阶段读数且缓存条件不同，末值降低不能单独归因于pool。不清MLX缓存、不松闸口、不改Vision源码、没有取消测试、Shape、手机或发布。

实际图像与前景准备中间闸口成立，不是文字到三维或产品验收。
