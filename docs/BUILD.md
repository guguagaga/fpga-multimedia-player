# v114 工程还原和构建

环境：Windows，Tang Dynasty 6.2.168116，EG4S20BG256，Python3，PowerShell；仿真使用Icarus和ModelSim。

本机匹配的完整工程：`D:/codexworks/audio_video_recovery_20261028/board_v114/candidate/project`。公开源码不包含厂商加密/生成IP；从这个完整工程或自己合法取得且哈希匹配的工程导入。v113/v109的PLL等文件可能不同，不能绕过哈希门禁。

```powershell
python -X utf8 tools/assemble_project.py --vendor-project 'D:/codexworks/audio_video_recovery_20261028/board_v114/candidate/project' --out 'build_workspace/candidate/project'
pwsh -NoProfile -File tools/build.ps1 -VendorProject 'D:/codexworks/audio_video_recovery_20261028/board_v114/candidate/project' -TdCommand 'D:/TD3/bin/td_commands_prompt.exe' -Seed 18
```

还原脚本拒绝覆盖已修改文件。构建后正常门禁检查setup、hold与失败端点；本次v114有真实时序违例，不能期待该门禁返回成功，也不要删除检查。

视频离线工具在host/video中。`encode_720p.cpp`输入1280×720 RGB565原始帧、输出C9；`repack_codec10.cpp`无损重打包为C10。参数Q165是165000字节/帧预算，并非JPEG质量。公开refine_boundaries.cpp在相同模式/索引下拟合相邻块颜色；输出还需重新打包校验。任何文件都必须保留标称帧率与真实重采样帧数的一致性，不能仅改头部伪装帧率。

渐变块研究在research/gradient_codec11中，独立于生产清单。现有比特流不支持实验Codec11。
