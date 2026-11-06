本次只验证已完成意图到真实图像的中间闸口，成功后最多一次真实 Vision 前景准备；不是文字到三维或手机成功。

读取既有真实 raw 与原 sourcePrompt，调用当前原生 CreationIntentDecoder。固定 seed93、20步 DPM、guidance7.5、cpuAndNeuralEngine、reduceMemory=true，VAE 保持上游 cpuAndGPU。只有一次 ImageEngine.generate；失败不重跑、不换provider、不改seed或提示词。768原PNG原样保存；Vision成功另存512透明PNG，失败不补mask。

运行前存 source/helper/raw/resource hashes，先启动ARMED真实handle，再发送RUN。实际Mac own-process phys_footprint每250ms采样；不是iPhone6GiB或系统跨进程总峰值。无取消验收、Shape、手机、App、ASC、main或新权重下载。
