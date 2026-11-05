已完成单次真实意图→图像中间闸口，不是文字→3D或手机成功。既有开发花瓶raw由当前原生decoder解码，未手写英文；固定seed93、20步DPM、7.5、CPU&NE、reduceMemory。ImageEngine一次154.432s，真实768PNG原样保留；真实Vision一次0.305s，另存512透明RGBA，无伪造mask、重跑或选seed。

图中可见蓝色螺旋壳形及金色开口边，整体完整；还有范围较大的金色内壁、stem/stand等额外造型，未声称严格全语义或通用题材验收。原图与透明图均为真实本机输出。

Mac own-process phys_footprint每250ms采样，峰值/末值1,889,879,360B；末次采样在ImageEngine return（defer卸载后）与Vision return之后。未保存逐阶段trace，不能把该值唯一归因于ImageEngine，更不能当iPhone6GiB/跨进程峰值或立即释放证明。取消未测。

source/helper/binary/raw与27资源文件前后SHA全部一致，见verification-after-run.json。此处图片和result保持冻结；下一resource-lifetime条件独立保存。
