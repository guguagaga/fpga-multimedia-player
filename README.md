# FPGA 多媒体播放器 / FPGA Multimedia Player

**新增 v187 R3：AUTO切图间隔显示，独立内部时序通过。** 用户已反馈交互改善，仍受最低读图时间约束；本版以预发布提供，未宣称全片音视频已重新完成板测。[R3说明](docs/OSD_CAROUSEL_V187.md) · [图片延迟优化方案](docs/IMAGE_LATENCY_NEXT.md)。下文v186保留为完整板测稳定基线。

基于安路 EG4S20BG256 的纯 RTL 多媒体播放器，支持 SD/FAT32 簇链、BMP/QOI 自适应图片、音乐、视频播放列表、频谱与中文 OSD。

**当前 v186：1280×720、30fps 视频内容，HDMI 输出 720P60。** 用户已确认本位流启动显示、完整 CS 影片播放、片尾音画同步和自动切换正常。独立重开布线数据库检查：setup **+0.265ns**、hold **+0.030ns**、零违例；像素时钟到 HDMI 串行时钟路径已纳入同步分析。

Board-confirmed 720p30 video playback with 720p60 HDMI output. This release repairs omitted synchronous HDMI timing constraints and pipelines the image-fit control comparison. Physical feedback covers startup, a full 271.2-second CS clip, end A/V sync, and automatic next-video switching.

- [v186 下载：位流、测试媒体、源码与工具](https://github.com/guguagaga/fpga-multimedia-player/releases/tag/v186-720p30-board-confirmed-20261031)
- [本版修改与上板记录](docs/RELEASE_V186.md) · [验证范围](docs/PERFORMANCE_RESULTS_720P30.md)
- [架构与算法](docs/ARCHITECTURE_720P30.md) · [分模块源码](docs/MODULES.md) · [构建](docs/BUILD.md)
- [高画质编码工具](host/video/codec14/README.md) · [视频切换与编号](docs/VIDEO_PLAYLIST_V183.md)
- [协作方式](docs/COLLABORATION.md) · [原 v185 故障记录](docs/V185_BOARD_FAILURE.md)

第二部 CS 是 720P30 / H6D1，M2_VIDEO.VID 与 V2_AUDIO.VAU 配对；第一部沿用 720P15 的 M1_C10.VID / V1_AMIYA.VAU。文件名 C10 不代表其实际格式。视频保留 Codec12 空间画质设置，再用可逆预测与六上下文 Huffman 减少存储字节；并非原视频逐像素无损。IMA 伴音有损。

本版修正两处错误的 HDMI 时钟分组，并把图片纵向缩放比较与状态跳转拆开。没有降低分辨率、帧率、PLL 频率或画质。六组完整图片逐像素对照、两种格式的读取/缩放/写帧集成测试通过；视频和音频源码与原持续吞吐测试完全匹配。

LUT 18207/19600，BRAM9K 63/64，BRAM32K 16/16，slice 占用 95.83%。剩余 LUT 不等同于无成本的可布线空间。OSD 自动切图间隔显示与新的频谱改进尚未合入这个冻结版本。

原 v185 存在启动无 HDMI 信号，保留撤回和失败记录。v186 的上板反馈不代表所有显示器、SD 卡或多小时老化均已验证。内部 STA 不替代外部接口电气与完整 CDC 审计。

厂商生成/加密 IP 只记录路径与哈希，需从合法持有的匹配工程本地导入。源文件原有版权与工具许可保留，不为混合来源工程新增统一许可证。
