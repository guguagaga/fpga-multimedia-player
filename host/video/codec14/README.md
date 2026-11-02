# H6D1 视频编码工具

推荐从上级 `../encode_video.py` 统一入口运行；完整参数与输入输出说明见 `../../../../docs/MEDIA_ENCODING.md`（相对工程根目录为 `docs/MEDIA_ENCODING.md`）。

空间编码器将 RGB565 图像转换为变长块指令，预算固定为每帧 125000 字节。`repack_codec12_stream.py` 合并实色游程，`codec14_transforms.py` 执行颜色差分及索引预测，`pack_h6d1.py` 使用六类上下文固定 Huffman 表封装并回解核对。`encode_ima_audio.py` 将 PCM 伴音转换为 IMA ADPCM，`decode_blocks.py` 提供参考像素解码。

本目录工具与板端 `context_huffman_decoder`、`codec12_lossless_restore` 及码表 ROM 配套。保留的格式编号和 executable 名称是工程接口标识；请不要自行更换码表或改名后混用。`tool_manifest.json` 记录实际分发文件哈希。

ADPCM-XQ 原始源码在 `host/third_party/adpcm-xq`，许可保留在本目录和源码目录。FFmpeg 和 Python 由用户安装。主脚本生成临时文件和输出，工作目录必须位于 D 盘。
