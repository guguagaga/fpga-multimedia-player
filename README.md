# FPGA 多媒体播放器 / FPGA Multimedia Player

基于安路 EG4S20BG256 的 RTL 多媒体系统，集成 FAT32 簇链读取、动态图片目录、BMP/QOI 自适应显示、图片轮播与两档缩放、PCM 音乐、视频播放列表、频谱和中文 OSD。

当前提交设计支持 **1280×720、30 fps 视频内容**，HDMI 扫描输出为 720P60。独立恢复布线数据库、加载生产约束后，内部建立裕量 **+0.318 ns**、保持裕量 **+0.022 ns**，违例端点均为 0，时序覆盖率 96.36%。用户已反馈当前视频通路及图片轮播正常；图片切换期间音乐杂音的专项复测尚无本轮明确反馈。

RTL multimedia player with 720p30 video content and 720p60 HDMI output. Current hardware feedback covers video playback and image carousel. Timing and numerical verification records accompany the source; the audio switching-noise retest remains separately tracked.

## 下载与阅读

- [技术报告 PDF](docs/report/technical-report.pdf) · [可编辑 Word](docs/report/technical-report-editable.docx)

- [本次完整备份 Release](https://github.com/guguagaga/fpga-multimedia-player/releases/tag/submission-20261102)：完整源码 RAR、位流、匹配原厂依赖、普通输入样例、技术报告与注释示例。
- [备份内容与校验方式](docs/GITHUB_BACKUP.md) · [构建与依赖导入](docs/BUILD.md) · [PC 媒体编码](docs/MEDIA_ENCODING.md)
- [样例转换步骤](samples/README.md) · [频谱计算复核](verification/spectrum/README.md)
- [源码注释示例](docs/source_examples/源码注释示例.txt) · [源码风格](docs/CODING_STYLE.md) · [协作方式](docs/COLLABORATION.md)

## 当前实现

视频使用空间块表示与可逆字节压缩后级，固定码表与 RTL 解码器配套。音轨按视频帧数生成 48 kHz 单声道 IMA ADPCM；背景音乐使用 48 kHz、16 位双声道 PCM WAV。PC 入口 `host/video/encode_video.py` 接受 FFmpeg 支持的普通视频文件，生成板端配对 VID/VAU。

图片目录按 FAT32 根目录有效图片项继续遍历，保存当前与下一候选的必要状态；已完成 2049 张图片三圈仿真，现场测试卡含 18 张图片。图片预读与实际发布分开握手，自动轮播计时依据画面发布事件；扩展板拨码提供轮播周期与自适应/75%缩小选择。

LUT 18365/19600（93.70%），slice 9445/9800（96.38%），寄存器 11872/19600，BRAM9K 63/64，BRAM32K 16/16，DSP 22/29。参数来自最终物理实现与报告；内部 STA 范围由生产约束定义，外部接口与异步跨域另按约束和同步电路说明。

## 源码与验证入口

`rtl` 按控制、存储、图像、视频、音频、显示、频谱及外存分类，顶层为 `rtl/top/top_tf_hdmi_audio.v`。`project_manifest.json` 定义 131 项构建输入，其中本 Git 仓库提供 112 项源码/模板，19 项原厂依赖通过 `--vendor-project` 从匹配工程或完整 Release RAR 导入。

```powershell
python tools/verify_release.py
```

此命令校验 112 项公开构建输入和 13 项编码工具，并明确报告 19 项外部依赖尚未校验。完整装配与构建按 [BUILD.md](docs/BUILD.md) 操作。工作和临时输出使用 D 盘。

频谱验证已将当前源码与独立整数模型逐值比较：2816 个加窗样本、2816 个复数 FFT 输出、352 个频带高度一致。配套 15 秒普通视频转换得到 450 帧与 720000 个伴音样本，回解及磁盘重读验证通过；详见 `evidence` 和 `verification/spectrum`。

RTL 文件头与说明性注释已整理；可执行逻辑逐行核对保持一致，记录见 `evidence/comment_cleanup.json` 和 `evidence/header_cleanup.json`。本次未因注释整理重新综合位流。`evidence/timing.json` 保留原物理实现身份，最新板级反馈以 `evidence/board_feedback.json` 为准。

`releases`、`research` 和历史文档保留开发记录；当前构建范围以 `project_manifest.json` 为准。仍保留但不属于此次同步源目录的历史文件列于 `docs/LEGACY_FILES.json`。完整备份与 Git 源码的分发范围见 `LICENSE_SCOPE.md` 和备份说明。
