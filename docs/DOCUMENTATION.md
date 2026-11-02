# 文档阅读与维护

## 阅读顺序

1. 从包根目录的 [README](../README.md) 了解提交基线、目录职责和当前验证范围。
2. 阅读随包技术报告，按总体约束、流水线结构、模块通路、算法推导、性能与验证结果理解设计。
3. 按 [构建说明](BUILD.md) 检查构建输入并装配工程；媒体准备按 [PC 编码说明](MEDIA_ENCODING.md) 和 [样例转换指南](../samples/README.md) 操作。
4. 查阅 [验证说明](../verification/README.md)，选择需要复现的测试；修改源码前阅读 [代码风格](CODING_STYLE.md)。

## 设计说明如何对应实现

算法正文按“目标与约束 → 变量和数据格式 → 计算过程 → 硬件或软件实现 → 复杂度与资源 → 实例验证”连续展开。公式旁交代单位、位宽、舍入和适用条件；实例紧接对应算法，便于把计算与结果联系起来。

模块说明以实际接口为边界，写明生产者、消费者、数据单位、有效条件、阻塞行为、完成条件及复位行为。读卡完成、解码完成、像素写入完成、帧发布和扫描接管分别对应各层事件。图片预读、视频缓冲和共享 SD 仲裁据此解释数据怎样流动、缓冲区何时可复用。

资源规划说明当前分配与选择依据：片上 FIFO 吸收供数间隔，外部 SDRAM 保存完整帧，分时运算单元承担频谱计算。容量、带宽和时钟参数以提交源码及对应结果为准；文档只陈述有依据的设计事实。

## 验证与复现入口

验证说明依次给出测试对象、输入或操作、观察量、通过准则、当前结果和适用范围。仿真结果注明模型条件；板级反馈注明实际确认的功能。源码清单、位流和报告结果通过校验信息关联。新增修改需要对应的新验证结果。

在 D 盘解压后的 `工程源码` 目录运行：

```powershell
python tools/verify_release.py
python tools/assemble_project.py --out ./build_workspace/candidate/project
```

完整构建入口为 `tools/build.ps1`；SD 与图片、原生分辨率、FAT32 测试入口分别为 `tools/verify.ps1`、`tools/verify_native720p.ps1`、`tools/verify_fat32.ps1`。依赖、工具路径与参数见 [BUILD.md](BUILD.md)。包完整性校验、功能仿真、布局布线时序及板级验收各自记录结果。

媒体工具的 README 或使用说明应包含依赖、运行目录、完整命令、参数单位、输入与输出格式、配对规则以及校验方式。当前统一视频入口是 `host/video/encode_video.py`，图片和音乐入口是 `host/image/convert_image.py`、`host/audio/convert_music.py`。随包样例提供可直接复现的输入；实际命令与输出文件名见 [MEDIA_ENCODING.md](MEDIA_ENCODING.md)。

## 文档组织参考

以下 GitHub 文档已于 **2026-11-02** 实际读取。链接固定到完整提交 SHA；日期为 GitHub 文件历史中最近修改提交的 UTC 提交日期，用于标识所读文档。参考内容为章节组织、接口说明和复现方法。

| 工程文档 | 文件修改提交日期 | 借鉴内容 |
|---|---|---|
| [OpenTitan UART Theory of Operation](https://github.com/lowRISC/opentitan/blob/5bf939116fb31367822adbfc3ab1784cdc57a06a/hw/ip/uart/doc/theory_of_operation.md) | 2026-09-10 | 框图、接口行为、FIFO 事件和定量边界顺序展开 |
| [Zephyr Threads](https://github.com/zephyrproject-rtos/zephyr/blob/1da4cec0e3cce9f0a3f387cb2afa5c2e2a1ec748/doc/kernel/services/threads/index.rst) | 2026-08-28 | 概念、生命周期、状态与实现示例分层 |
| [FFmpeg Developer Documentation](https://github.com/FFmpeg/FFmpeg/blob/c736c6d10f58c28d1fbb1c7e1b50487015e4dd3e/doc/developer.texi) | 2026-08-11 | 接口注释、命名一致性、文档同步和可复现回归 |
