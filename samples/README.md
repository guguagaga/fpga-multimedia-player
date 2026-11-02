# 配套输入样例与转换步骤

本页保留完整 Release RAR 的样例操作说明。普通 JPG/MP4 素材及 `media_manifest.json` 放在完整 RAR 的 `工程源码/samples` 中，Git 历史只保存说明。请先下载 [本次完整备份](https://github.com/guguagaga/fpga-multimedia-player/releases/tag/submission-20261102)，从解压后的 `工程源码` 运行下列命令。素材由用户提供，用于本项目编码与播放测试。

| 文件 | 输入规格 | 测试用途 |
|---|---|---|
| `images/artwork.jpg` | 1920×1080 JPEG | 色彩与图案显示 |
| `images/landscape.jpg` | 1920×1080 JPEG | 景物细节与自适应显示 |
| `images/cup.jpg` | 1280×720 JPEG | 较低输入分辨率的显示对照 |
| `video/cs_highlights_15s.mp4` | 约 15 秒，1920×1080、30 fps，H.264 视频及 AAC 双声道音频 | 视频与音轨转换 |

短片取自用户提供的 CS 素材第 75～90 秒。输入音轨为 44.1 kHz，转换工具会重采样为板端使用的 48 kHz。三张图片均为 16:9，板端自适应后占用相同显示区域；原图内容、压缩和分辨率共同影响清晰度。

## 运行前准备

将工程解压到 D 盘，在 PowerShell 中进入包内的 `工程源码` 目录。以下路径均从该目录开始。准备 Python 3.11 或更新版本、Pillow、FFmpeg 与 FFprobe；工具依赖和格式说明见 [PC 端媒体编码](../docs/MEDIA_ENCODING.md)。

```powershell
if ((Get-Location).Drive.Name -ne 'D') { throw '请先进入 D 盘解压后的工程源码目录' }
$ffmpeg = Read-Host '输入本机 ffmpeg.exe 完整路径'
$ffprobe = Read-Host '输入本机 ffprobe.exe 完整路径'
if (!(Test-Path -LiteralPath $ffmpeg -PathType Leaf)) { throw '未找到 FFmpeg' }
if (!(Test-Path -LiteralPath $ffprobe -PathType Leaf)) { throw '未找到 FFprobe' }
$out = './encoded_media/sample_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
if (Test-Path -LiteralPath $out) { throw '输出目录已存在，请重新选择目录名' }
New-Item -ItemType Directory -Path "$out/tmp" | Out-Null
$env:TEMP = (Resolve-Path "$out/tmp").Path
$env:TMP = $env:TEMP
$env:PYTHONDONTWRITEBYTECODE = '1'
```

本次输出使用 D 盘新目录。请在同一个 PowerShell 窗口继续执行后面的命令，使 `$out` 等变量保持有效。

## 转换三张图片

```powershell
python host/image/convert_image.py ./samples/images/artwork.jpg "$out/images/I1_ART.BMP"
if ($LASTEXITCODE -ne 0) { throw '图片 artwork 转换失败' }
python host/image/convert_image.py ./samples/images/landscape.jpg "$out/images/I2_LAND.BMP"
if ($LASTEXITCODE -ne 0) { throw '图片 landscape 转换失败' }
python host/image/convert_image.py ./samples/images/cup.jpg "$out/images/I3_CUP.BMP"
if ($LASTEXITCODE -ne 0) { throw '图片 cup 转换失败' }
```

输出为 24 位未压缩 BMP，保留方向校正后的输入尺寸。脚本检查 BMP 文件头、行对齐、文件长度，并回读核对像素；成功时打印 `PASS` 和 SHA-256。

## 转换 30 fps 视频及配套伴音

```powershell
python host/video/encode_video.py ./samples/video/cs_highlights_15s.mp4 --ffmpeg $ffmpeg --ffprobe $ffprobe --output "$out/video" --fps 30 --slot 2 --seconds 15
if ($LASTEXITCODE -ne 0) { throw '视频转换失败，请查看输出日志' }
```

`$out/video` 必须事先不存在，由编码脚本创建。输出位于：

- `$out/video/sdcard/M2_VIDEO.VID`：1280×720、30 fps 的板端视频。
- `$out/video/sdcard/V2_AUDIO.VAU`：与视频帧数配对的 48 kHz 单声道 IMA ADPCM 伴音。
- `$out/video/conversion.json`：实际帧数、样本数、载荷及哈希。
- `$out/video/encoding.log`：编码和回解验证日志。

15 秒在 30 fps 下对应 450 帧、720000 个单声道伴音样本；最终以工具根据实际输入时长生成的 `conversion.json` 为准。回解校验确认可逆封装与中间编码数据一致，空间压缩本身采用有损表示。

## 从短片提取背景音乐 WAV

```powershell
python host/audio/convert_music.py ./samples/video/cs_highlights_15s.mp4 "$out/music/01_CS.WAV" --ffmpeg $ffmpeg
if ($LASTEXITCODE -ne 0) { throw '音乐转换失败' }
```

此命令使用短片内的音轨，输出标准 44 字节文件头、48 kHz、16 位双声道 PCM WAV。脚本回读检查参数和全部 PCM 数据，并打印时长及哈希。AAC 输入的实际解码时长由 FFmpeg 决定，不把容器标称时长当作精确样本数。相邻 `.pcm` 是转换中间文件，无需放入卡中。

随包短片的提取实测为每声道 720005 个样本，约 15.000104 秒；与严格按视频帧数生成的 VAU 伴音不同，这一步保留 FFmpeg 解码重采样后的完整音轨。

## 输出文件与卡上文件的关系

这些命令只生成本地文件，不自动写入 SD 卡。确认转换成功后，可按需要手动复制 BMP、WAV，以及成对的 VID/VAU 到 FAT32 卡根目录。图片与 WAV 使用简短 ASCII 的 8.3 文件名；当前图片目录按根目录中受支持文件遍历，音乐列表识别 `.WAV`。

`M2_VIDEO.VID` 和 `V2_AUDIO.VAU` 占用第二个视频槽位，必须配对更新。卡上同名文件会发生替换，`I1_ART.BMP`、`I2_LAND.BMP`、`I3_CUP.BMP` 和 `01_CS.WAV` 也需先检查是否重名；复制前应把需要保留的原文件备份到电脑。保留第一槽视频时不要改动它的配对文件。

转换工具拒绝覆盖已有输出文件或已有视频输出目录。重复试验时重新执行准备步骤，使用新的输出目录；无需删除先前试验结果。
