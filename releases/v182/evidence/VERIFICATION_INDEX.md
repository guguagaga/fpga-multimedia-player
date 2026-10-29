# 内部验证索引

联合测试同时检查像素/地址/PCM数据与连续播放。以下等待量为模型中的音频预算等待，判断门槛是最长等待小于一个48kHz采样周期；并非实物测量。短测试的首尾帧区间不宜作为长期平均帧率保证。

| 用例 | 帧数 | 数据正确 | 连续性 | 最长等待(ms) |
|---|---:|---|---|---:|
| av_v182_continuous_3_q125_physical32_recovered | 3 | PASS | PASS | 0.000077 |
| av_v182_continuous_18_q125_loop6_physical32 | 18 | PASS | PASS | 0.000077 |
| av_v182_continuous_3_q125_latency39000_vendor | 3 | PASS | PASS | 0.000099 |
| av_v182_continuous_3_fullfilm_first3_unpacked | 3 | PASS | PASS | 0.000099 |
| av_v182_fragmented_3_q125_fragmented_physical32 | 3 | PASS | PASS | 0.000099 |

18帧用例是三帧素材重复六次，验证跨循环和缓存状态，不是18张独立内容，更不是全片RTL仿真。全片6330帧另有软件格式/无损打包一致性验证。

旧v180与旧卡实际片头的负对照数据正确但连续性失败，最长等待约16.667ms。对应新影片片头用未打包数据进行测试，避免把纯色游程减小的数据量当作未经验证的假设。

图片/退出视频恢复音乐测试沿用原通过结果，当前相关源码逐项哈希一致；原报告在 reused_regressions，审计在 preserved_fixes_audit.json。SPI修改另有真实引脚模型回归。复用不表示重新执行或已完成实物验收。

testbenches保存本轮联合测试及SPI/I2S的测试平台入口；reproduction_scripts保留研究脚本。脚本和run.do中的历史绝对路径、外部ModelSim器件库与大型生成素材需要按原报告准备，不能声称此目录可独立一键复现全部仿真。工程源码的重新综合/布线入口见README。

fresh_routed.json及fresh_routed目录保存独立进程时序复核。内部setup WNS为0.000ns、hold为+0.023ns；原约束未放松，但没有setup余量。外部IO、CDC及真实SDRAM/SD卡验收尚待上板。
