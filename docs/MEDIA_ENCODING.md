# PC 端媒体编码

首次运行可直接使用完整 Release RAR 中的三张 JPG 和一段带音轨的普通 MP4，按 [配套输入样例与转换步骤](../samples/README.md) 完成图片、30 fps 视频和背景音乐转换。Git 仓库仅保存样例说明，输入素材在完整 RAR 内。样例从解压后的工程源码根目录使用相对路径，输出到 D 盘新目录，不自动修改 SD 卡。

## 软件准备

Windows、Python 3.11 或更新版本、FFmpeg 和 FFprobe。图片转换另需 Pillow。FFmpeg/FFprobe 由使用者安装，不随本包分发。两者不在同一目录时显式传入 `--ffprobe`。

## 普通视频转板端 VID 与 VAU

在解压后的 `工程源码` 目录运行。以下相对路径以这个目录为起点；先把自己的输入文件放入 `media` 目录：

```powershell
$ffmpeg = Read-Host '输入本机 ffmpeg.exe 完整路径'
$ffprobe = Read-Host '输入本机 ffprobe.exe 完整路径'
python host/video/encode_video.py ./media/input.mp4 --ffmpeg $ffmpeg --ffprobe $ffprobe --output ./encoded_media/movie --fps 30 --slot 2
```

接受 FFmpeg 支持的 MP4、MKV、MOV、AVI 等输入。默认编码从起点到完整视频末尾；`--start 60 --seconds 10` 可提取试播区间，`--audio ./media/audio.m4s` 可输入同步分离音轨。无音轨视频必须提供 `--audio`。`--fps` 仅支持 20 或 30，`--slot` 支持 1～4。输出目录必须是尚不存在的 D 盘目录，防止覆盖已有媒体。

视频统一采样为 1280×720 RGB565；当前 PC 预处理直接缩放到这个尺寸，输入宽高比不同时会改变比例。空间编码预算保持每帧 125000 字节，候选模式与 RTL 固定码表配套。脚本对可逆后级逐帧回解并重读磁盘验证；这项核对不表示有损空间编码等同原始视频。

伴音转换为 48 kHz、16 位、单声道后使用 IMA ADPCM。音频样本数由 `帧数×48000/帧率` 确定。视频起点与独立音轨起点必须由输入者保持同步。末尾不足一个目标帧的时长会舍弃；短音轨会补静音以达到对应视频样本数。

输出：

- `sdcard/M2_VIDEO.VID` 与 `sdcard/V2_AUDIO.VAU`：复制到 FAT32 卡根目录的配对文件。
- `conversion.json`：分辨率、帧率、帧数、样本数、码率、最大帧长度及文件哈希。
- `encoding.log`：实际编码与回解日志。
- `work`：中间数据，用于复查，完整片段可能占用较大磁盘空间。

文件名称会按 `--slot` 自动变化。新视频的纹理和运动不同，最终载荷也不同；先用短片段检查工具输出和实板持续供数，再准备全片。配套 CS 样本的 720P30 结论仅对应已验证媒体与卡响应条件。

## 图片和背景音乐

```powershell
python host/image/convert_image.py ./media/photo.jpg ./encoded_media/I1_TEST.BMP
python host/audio/convert_music.py ./media/music.m4s ./encoded_media/01_MUSIC.WAV --ffmpeg $ffmpeg
```

图片输出为 24 位未压缩 BMP，保持 EXIF 方向校正后的原尺寸，板端执行自适应显示。输入最大宽高为 4096 像素。音乐输出为 48 kHz、16 位双声道 PCM WAV，具有标准 44 字节文件头。工具重新读取输出核对像素或 PCM 数据。输出采用简短 ASCII 文件名并放在 FAT32 根目录。

## 编码器源码

`host/video/codec14/encode_blocks_experimental.cpp` 是空间编码器源码，Windows 可执行文件附带在同目录。使用 C++17 编译器可构建，例如 `g++ -O3 -std=c++17 encode_blocks_experimental.cpp -o encode_blocks_experimental.exe`。可逆封装、回解与固定码表由同目录 Python 文件实现。

ADPCM-XQ 源码和原许可见 `host/third_party/adpcm-xq`。原软件作者与许可保留，未把该音频编码器声明为原创。预编译程序的 SHA-256 由 `tool_manifest.json` 记录；更换程序或码表后需重新验证输出兼容性。

当前生产视频入口是 `host/video/encode_video.py`，其依赖相邻 `codec14` 目录。`encode_movie.py`、`encode_video_rates.py`、`codec12`、`src`、`playlist` 中的工具保留为格式演进和研究源码，并非当前媒体交付入口；其中个别旧编码程序需要另行构建，不能直接替代上述统一入口。
