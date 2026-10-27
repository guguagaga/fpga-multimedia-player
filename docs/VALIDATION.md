# v114 验证状态

最终综合/布线完成不等于时序通过：setup −1.980ns、338违例端点；hold +0.027ns、0违例。正常时序门禁保持拒收。用户尚未完成v114板测；v113出图通过但音频反馈有问题。

- sector_recovery: `True`
- restart_policy: `True`
- fragmented_audio: `True`
- audio_fault: `True`
- top_source_switch: `True`
- source_audit: `True`
- fullfilm_audio: `True`
- joint165_pcm: `True`
- q185_pcm: `True`

## 像素/样本正确与显示节拍分别记录

- joint165_pcm: 最大帧间隔门禁（每间隔不超过66.67ms）=`False`；首末显示间平均帧率=`14.9999970000006`。
- q185_pcm: 最大帧间隔门禁（每间隔不超过66.67ms）=`False`；首末显示间平均帧率=`12.631576421053136`。

短片测试包含起播过渡，平均值不能证明全片持续帧率。Q165也可能出现单个83.33ms间隔；Q185不作活动媒体。

上述结果以release_status.json为准。pending/false不是通过；长片数据比对使用加速行为卡，视频并发使用32周期/字节的SD模型，均不代表物理卡、I2S、HDMI和电气时序已验证。旧verification中的历史测试不自动等同于本次重跑。

公开快速回归：`python tools/verify_audio_recovery.py --iverilog PATH_TO_IVERILOG --vvp PATH_TO_VVP`。它直接编译本仓库的扇区源码，并从当前顶层提取选轨控制块；覆盖短读恢复、超时/取消与异常不单独重播，不依赖用户媒体。其通过不能代替整体时序和实板测试。
