# 720P20/30 配套编码指南

使用交付包的 `encoder/` 或 Release tools-verification.zip 中的同名目录。新格式为 Codec14/H6D1，需要配套位流，旧 v183 无法播放。视频仍采用原 Codec12 空间配置；新增阶段可逆，不代表原视频逐像素无损。

## 使用条件

Windows、Python3.11+、FFmpeg。编码器与 ADPCM-XQ 的 Windows exe 及原有许可随工具包附带；FFmpeg自行安装。普通Git中的 host/video/codec14 主要为源码，先从Release取得完整工具包。所有输出与临时目录放D盘，输出目录须尚不存在。

在 encoder 目录运行：

```powershell
$env:PYTHONUTF8='1'
$env:PYTHONDONTWRITEBYTECODE='1'
python -X utf8 .\encode_h6d1_video.py --ffmpeg 'D:\tools\ffmpeg.exe' --fps 30 --start 0 --seconds 10 --video 'D:\media\video.mp4' --audio 'D:\media\audio.m4a' --output 'D:\codexworks\my_720p30'
python -X utf8 .\encode_ima_audio.py --video 'D:\codexworks\my_720p30\EXPERIMENTAL_720P30.VID' --pcm 'D:\codexworks\my_720p30\EXPERIMENTAL_AUDIO.VAU' --output 'D:\codexworks\my_720p30\EXPERIMENTAL_AUDIO_IMA.VAU'
```

音视频在同一源文件时，两个输入路径相同即可；分离源文件应先核对时间起点。`--seconds × --fps` 必须为整数帧；当前全片为271.2秒、8136帧。`--fps`支持20/30，工具按目标时间线取帧，不用插值凭空产生运动细节。低帧率原片即使编码为30fps，也可能重复画面。

原片Lanczos缩放到1280×720、RGB565。当前工具对非16:9视频会拉伸，因此先预处理宽高比再编码。生产参数固定为 `500 8000 125000 15`，末项15是允许模式掩码，不是帧率；不能改这个数字来提高帧率。

后级进行RGB565代表值差分、块内索引行预测及六上下文Huffman编码；每帧重置，不依赖其他帧。冻结表 `index_residual.json` 与硬件 `residual_tree.mem` 必须成套。交付门禁已经核对全部1536个码字与硬件树；不得只更换一侧码表。

## 输出与验收

- `EXPERIMENTAL_720P30.VID`：H6D1视频，只有配套格式14位流可读取。
- `EXPERIMENTAL_AUDIO.VAU`：临时PCM伴音；运行第二条命令生成最终 `EXPERIMENTAL_AUDIO_IMA.VAU`。
- 视频及IMA旁的JSON须为 `passed:true`，帧数、样本数和哈希一致；IMA工具同时保留独立解码的 `.verify.wav` 供试听。
- `source.rgb565`、分片和 `original.VID` 为复现中间文件，工具不会自动删除。271.2秒的30fps原始帧约15GB，还需其他输出空间。

IMA为有损48kHz单声道音频；本候选顶层不启用QOA音频硬件。工具不会自动写SD卡，失败或运行中的 `.partial` 不能拿去播放。

配套位流准备好后，将最终VID复制为卡根目录 `M2_VIDEO.VID`，最终IMA伴音复制为 `V2_AUDIO.VAU`。先备份同编号旧文件，不要同时保留两个同编号活动VID/VAU。安全弹出、插回开发板并复位。视频模式KEY1下一部、KEY2上一部、KEY0暂停/继续、KEY3退出。

## 验证范围

完整影片新增H6D1压缩层回解后与Codec12 token一致；原片重新按30fps解码的8136张输入帧也已逐帧核对。编码工具在独立目录完成3帧视频和4800音频样本的运行检查。软件重建预览用于判断编码画质，不代表板上录像。

任意新影片的峰值数据量可能更大，不能把当前素材的吞吐结论直接套用。完整上板验收需检查实际时长、音画同步、自动/手动切换、暂停及退出恢复音乐。HDMI应采集为720P60，内容帧率与扫描刷新率分别检查。

ADPCM-XQ版本0.5；上游工具输出版权年份2024，本项目集成日期2026-10-30，不能把集成日期当作上游发布日期。许可见工具包中的ADPCM-XQ-LICENSE.txt。
