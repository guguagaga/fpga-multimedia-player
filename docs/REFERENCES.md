# 开源参考与日期

日期取自本地保存的 GitHub API commit 元数据；本轮未重新联网声称“最新”。RTL为自写，参考C编解码用于算法和黄金结果。

| 项目 | 引用commit | commit日期(UTC) | 用途 |
| --- | --- | --- | --- |
| [phoboslab/qoa](https://github.com/phoboslab/qoa) | [bc0589710ff6](https://github.com/phoboslab/qoa/commit/bc0589710ff6aa2f50e08fb4d0a815d567bc0f3e) | 2026-09-27T13:28:14Z | QOA算法、反量化表与C黄金解码 |
| [phoboslab/qoi](https://github.com/phoboslab/qoi) | [ffb2d2cb74a1](https://github.com/phoboslab/qoi/commit/ffb2d2cb74a1de60819b21b939f7209aa53e91c1) | 2026-09-27T13:36:43Z | QOI格式、C参考编码与测试 |
| [dbry/adpcm-xq](https://github.com/dbry/adpcm-xq) | [2000733c6d92](https://github.com/dbry/adpcm-xq/commit/2000733c6d92d73c10ddae3ae80232e173d565c8) | 2026-07-14T19:19:27Z | BSD离线IMA编码器，lookahead/noise shaping |
| [amstan/qoa-fpga](https://github.com/amstan/qoa-fpga) | [e7593cb464d4](https://github.com/amstan/qoa-fpga/commit/e7593cb464d47f823065c07a2583715651e9b163) | 2023-05-20T01:09:24Z | 仅研究参考，未移植其FPGA核 |

QOA、QOI的MIT与ADPCM-XQ的BSD许可证随docs/licenses保留。没有引入GPL FPGA QOI核。周期Hann为数学窗函数；频谱定点数值报告保留在本地媒体集成交付的reports/hann.json，未将该历史文件冒充本次v19新执行结果。

## 视频算法研究背景

- Lema 与 Mitchell，*Absolute Moment Block Truncation Coding and Its Application to Color Images*，IEEE Transactions on Communications，1984，DOI [10.1109/TCom.1984.1095973](https://doi.org/10.1109/TCom.1984.1095973)。用作统计代表值的研究背景；本工程不声称重现整套论文算法。
- [divVerent/s2tc](https://github.com/divVerent/s2tc)：此前2026-10-25保存的GitHub搜索元数据显示仓库 `updated_at=2025-12-08T18:17:13Z`。这是仓库元数据更新时间，**不是代码提交日期**；本次没有重新联网核验或复制该库实现，不能据此声称它是最新算法。

AMBTC/S2TC启发的代表色与候选细化、强边缘/时间权重均有历史实验；最终保留QUAD4加率失真预算分配，原因见RESEARCH_HISTORY.md。
