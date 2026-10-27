# 视频格式参数化回归

2026-10-27：10组小帧测试。参考为参数化改动前的工程自有`video_player`源码。
默认参数逐拍核对旧格式Codec1/2/5/6/7及块格式；生产参数0拒绝旧格式，块格式正常帧逐拍一致，并核对短帧/非法操作码的黑色补齐、暂停和FIFO阻塞。

需要本地合法TD BRAM仿真模型与ModelSim，不在仓库内再分发这些模型。

```powershell
$env:MODELSIM='E:/modelsim/modelsim_ase/win32aloem/vsim.exe'
$env:TD_SIM_DIR='D:/TD3/sim_release/eg4'
python -X utf8 verification/video_specialization/run.py
```

结果在`generated/video_specialization.json`；此测试不能代替真实720P整帧、吞吐、布线STA或板测。
