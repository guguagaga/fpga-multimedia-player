# v182配套视频编码

当前验证配置为1280×720、15fps、Codec12、打包前每帧125000字节预算。附件含匹配的encode_blocks_experimental.exe，源码与Python包装在host/video/codec12。

先从Release包取出encoder目录，在该目录中运行：

```powershell
python encode_video_codec12.py --input "D:/原片.mp4" --output "D:/codexworks/试编码.VID" --ffmpeg "C:/Users/Admin/Desktop/ffmpeg/ffmpeg.exe" --frames 3
```

确认短样本后，换用未占用的输出名并去掉--frames 3编码全片。需要Python 3.11+和自行安装的FFmpeg。工具使用二进制管道和逐帧有限内存打包，拒绝覆盖已有文件，输出哈希及校验记录。

当前缩放参数适合16:9原片，其他比例会拉伸为1280×720。视频工具不生成音轨，需另外准备时间匹配的48kHz音轨。不得把其他原片与当前配套音轨混用。

原始编码器最后一个参数15是功能位掩码，不是帧率；不能改成30获得30fps。相同纯色块游程打包不改变像素表示。当前完整影片规格与哈希见release_status.json。

源码编译示例：`g++ -O3 -std=c++17 encode_blocks_experimental.cpp -o encode_blocks_experimental.exe`。编译器版本可能影响二进制哈希；包装器锁定已测试exe，自己编译的版本须重新验证并显式更新工具的哈希，不能直接冒充已验收版本。
