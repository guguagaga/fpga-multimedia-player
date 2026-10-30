# FPGA 多媒体播放器 / FPGA Multimedia Player

基于安路 EG4S20BG256 的纯 RTL 多媒体播放器，支持 SD/FAT32 簇链、BMP/QOI 自适应图片、音乐、视频播放列表、频谱与中文 OSD。

**本分支为 v185：真实1280×720、30fps 的待上板验收候选。HDMI扫描保持720P60。** 独立原约束内部时序通过：setup +0.386ns、hold +0.030ns，零违例端点。v182 保持 GitHub 最新稳定发布，v183 可用于已验证的四视频切换回退。

An RTL multimedia player with a 720p30 content candidate and 720p60 HDMI scanout. Internal timing and layered simulation pass; physical board qualification remains pending.

- [v185候选下载](https://github.com/guguagaga/fpga-multimedia-player/releases/tag/v185-720p30-board-test-20261030)
- [v182稳定发布](https://github.com/guguagaga/fpga-multimedia-player/releases/tag/v182-board-confirmed-20261029)
- [架构与算法](docs/ARCHITECTURE_720P30.md) · [相对v183改动](docs/CHANGES_FROM_V183.md)
- [性能与验证边界](docs/PERFORMANCE_RESULTS_720P30.md) · [原始证据](releases/v185/evidence)
- [模块源码导航](docs/MODULES.md) · [构建](docs/BUILD.md) · [编码工具](host/video/codec14/README.md)
- [播放列表按键与编号](docs/VIDEO_PLAYLIST_V183.md) · [协作](docs/COLLABORATION.md)

视频保留Codec12空间配置，用可逆预测与六上下文Huffman降低存储量，不额外加重块量化。最高码率原载荷重复10次，两档卡首响应模型均检查300张完整720P画面、480000个PCM样本及299个均匀显示间隔；另有厂商模型30帧复核和8136帧小尺寸控制长测。它们不等于全片整板RTL测试，最终观感和稳定性需上板确认。

64扇区物理缓存与16KiB压缩字节FIFO并存；QOI索引转移至LUT存储，释放大块RAM。综合LUT17695/19600，BRAM9K63/64，BRAM32K16/16。没有放宽原约束或通过继续扩大启动缓冲隐藏持续欠供。

新视频必须配套格式14/H6D1位流。第二组文件为M2_VIDEO.VID、V2_AUDIO.VAU，配套片长271.2秒；伴音为有损48kHz单声道IMA-XQ。实验顶层关闭QOA音频，PCM/IMA、BMP/QOI保留。完整编码器exe、复现数据和媒体位于Release附件，不放普通Git。

厂商生成/加密IP只记录路径与哈希，从合法持有的匹配工程本地导入；没有为混合来源工程新增统一许可证。源文件原有版权与工具许可保留。
