# FPGA 多媒体播放器 / FPGA Multimedia Player

基于安路 EG4S20BG256 的纯 RTL 多媒体播放器：SD/FAT32 簇链读取、BMP/QOI 图片自适应与轮播、Codec8/9/10/12 视频、PCM/IMA/QOA 音频、HDMI、频谱和中文 OSD。

**当前稳定基线：v182，2026-10-29。用户使用配套 bit 与新影片上板后反馈“一切正常”。** 内部独立时序检查通过：setup WNS 0.000 ns、hold WNS +0.023 ns、违例端点为零。setup 无正余量，外部 IO/CDC 与量化耐久性验证仍需完善。

HDMI 输出为1280×720、60Hz；当前配套影片为真实1280×720、15fps、422秒。显示刷新率与视频帧率不同。

An RTL multimedia player for the Anlogic EG4S20 FPGA. The v182 paired bitstream/media received a normal-operation report from the project owner. Internal timing passes with zero setup margin; this is not a claim of exhaustive board qualification.

## 下载与阅读入口

- [v182 Release：源码、比特流与配套工具打包下载](https://github.com/guguagaga/fpga-multimedia-player/releases/tag/v182-board-confirmed-20261029)
- [版本改动与上板验收](docs/RELEASE_V182.md)
- [模块源码导航](docs/MODULES.md)
- [构建、厂商依赖导入与独立时序复核](docs/BUILD.md)
- [视频编码工具与媒体配对](docs/ENCODING_V182.md)
- [验证范围和原始证据](docs/VALIDATION.md)
- [后续稳定性路线](docs/STABILITY_ROADMAP.md)
- [协作流程](docs/COLLABORATION.md) · [依赖与许可](docs/DEPENDENCIES.md)

`rtl/`按功能分组；`project_manifest.json`映射回参与构建的准确目录。`research/`保留历史探索，不参与生产构建。文件名含experimental的Codec12模块已在本版工程清单中使用，不以文件名判断是否进入生产。

打包附件包含本版bit、编码器可执行文件及源码。源码树保留现有许可证范围；厂商生成/加密IP从合法持有且哈希匹配的工程本地导入。原视频、歌曲和软件截图未加入GitHub包，媒体哈希与规格可在release_status.json核对。

目前UI为根目录、最多4张图片/8首歌曲及首个视频和配套音轨。支持FAT链不代表任意SD卡延迟、任意码率均可无停顿播放。请使用配套编码配置，不能仅修改文件头把15fps改成30fps。
