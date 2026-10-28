# FPGA 多媒体播放器 / FPGA Multimedia Player

基于安路 EG4S20BG256 的纯 RTL 多媒体播放器，包含 SD/FAT32 簇链读取、图片预取与轮播、720P Codec8/9/10 视频、PCM/IMA/QOA 音频、HDMI、频谱和中文 OSD。

An RTL multimedia player for the Anlogic EG4S20 FPGA, with FAT32 media access, native 720p video, image playback, audio, spectrum visualization and Chinese OSD.

**当前快照：v114，2026-10-28 当日最终测试版。综合与布线已完成，时序未收敛，尚未完成本版实板验收。** Setup WNS −1.980 ns，338 个违例端点；hold +0.027 ns，0 个违例端点。这个状态应在提交与演示中如实保留。

HDMI 输出为 **1280×720、60Hz**；媒体视频标称 **15fps**，两者不同。前一版 v113 已由用户实测能出图，随后发现音频中途单独重播。v114 修正不安全的音频恢复策略和扇区短读处理；尚未确证实板异常的全部触发原因。

|入口|内容|
|---|---|
|[本次版本与验收](docs/RELEASE_V114.md)|改动、时序、实板反馈、仍待验证事项|
|[模块导航](docs/MODULES.md)|按功能分组的RTL源码|
|[整机数据流](docs/ARCHITECTURE.md)|存储仲裁、显示缓冲、音画同步与时钟边界|
|[构建与还原](docs/BUILD.md)|导入匹配厂商依赖、哈希核对和构建|
|[算法思路](docs/ALGORITHMS.md)|块级率失真分配及音频、图片处理|
|[本次画质实验](docs/QUALITY_20261028.md)|兼容格式的块边拟合与未合入的渐变块|
|[验证状态](docs/VALIDATION.md)|测试通过范围、模型边界及已知失败|
|[FAT32链读取](docs/FAT32_CHAIN.md)|物理碎片读取与文件系统限制|
|[GitHub提交指南](docs/GITHUB_UPLOAD.md)|创建仓库、提交、邀请组员|
|[组内协作与版本顺序](docs/COLLABORATION.md)|分支、PR、同步与上板版本对应|
|[后续优化记录（10月28日）](research/optimization_20261028/README.md)|未采用的时序候选、抽样画质结果与架构探索|
|[依赖与许可](docs/DEPENDENCIES.md)|厂商依赖及公开范围|
|[资料与日期](docs/REFERENCES.md)|既有参考文献、仓库版本和检索日期|

`rtl/` 包含 audio、control、display、image、memory、spectrum、storage、top、video；`host/` 是离线工具；`constraints/` 保存约束；`verification/` 是可公开的合成测试；`research/` 不参与生产工程。

公开包和本地完整工程通过 project_manifest.json 一一映射并记录SHA256。厂商加密/生成IP通过合法持有的匹配工程导入；不包含原片、歌曲、实卡数据、bit或工具可执行文件。保留各文件已有版权和许可证，不自动为整个项目套用统一许可。

FAT32支持物理碎片，但当前UI仍为根目录、最多4张图片/8首歌、首个VID与VAU。尚无任意文件浏览器，也未宣称所有碎片分布和卡延迟都能持续720P15fps。
