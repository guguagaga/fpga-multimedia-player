# 720P20/30 编码工具

这是 H6D1 实验格式工具，需要配套支持格式14/H6D1的位流，v183不能直接播放。视频先沿用生产Codec12编码器的空间画质参数，再无损重编码；并非原视频逐像素无损。音频IMA是有损编码。

## 环境

Windows、Python 3.11以上、FFmpeg；编码器exe及C++源码、ADPCM-XQ exe及许可已附带。Python脚本仅使用标准库。FFmpeg需自行安装并传入完整路径。工作目录及输出放在D盘，输出文件夹必须尚不存在。

## 编码

在本工具目录打开PowerShell，填写真实路径：

```powershell
$env:PYTHONDONTWRITEBYTECODE='1'
python -X utf8 .\encode_h6d1_video.py --ffmpeg 'D:\tools\ffmpeg.exe' --fps 30 --start 0 --seconds 10 --video 'D:\media\video.mp4' --audio 'D:\media\audio.m4a' --output 'D:\codexworks\my_720p30'
python -X utf8 .\encode_ima_audio.py --video 'D:\codexworks\my_720p30\EXPERIMENTAL_720P30.VID' --pcm 'D:\codexworks\my_720p30\EXPERIMENTAL_AUDIO.VAU' --output 'D:\codexworks\my_720p30\EXPERIMENTAL_AUDIO_IMA.VAU'
```

视频与音频在同一文件时，两个输入路径可相同。分离文件应先核实时间起点对齐。`--seconds`乘目标帧率必须为整数；全片271.2秒、30fps为8136帧。输入视频按Lanczos缩放到1280×720并按目标帧率取帧；工具不会凭空产生30张不同内容，低帧率原片不适合用于证明30fps。

视频编码参数固定为`500 8000 125000 15`，最后的15为模式掩码，不是帧率。编码器使用4路分段加速。原始帧每秒约55.3MB，271.2秒需要约15GB中间数据，另需编码输出空间。

成功后检查相邻JSON的`passed`、帧数和SHA256。H6D1封装会逐帧逆变换并从磁盘回读验证；运行中的`.partial`不能拿去播放。IMA工具会独立解码检查样本数量，并保留`.verify.wav`供试听。没有自动写SD卡或删除旧文件的动作。

## 放入播放列表

配套位流通过验收后，第二个视频使用根目录`M2_VIDEO.VID`，对应音频`V2_AUDIO.VAU`。从已完成的H6D1视频和IMA文件复制并改名；同编号不要同时保留多个活动VID/VAU副本，备份应放到电脑。不要把PCM与IMA两个伴音同时作为相同编号放在根目录。

`index_residual.json`为冻结码表，必须与配套位流的ROM成套，不能只改单侧。增加更高码率、更高分辨率或更长预读不由此脚本自动保证，仍需带宽和上板验证。

ADPCM-XQ版本为0.5，本项目2026-10-30使用现有本地工具并记录SHA256；此日期是集成日期，不是其上游发布日期。许可见`ADPCM-XQ-LICENSE.txt`。本包不包含FFmpeg。
