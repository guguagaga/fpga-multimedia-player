# 图片缩放验证

从仓库根目录运行：

```powershell
python verification/image_zoom_v193/run.py --output D:/codexworks/zoom_validation --iverilog C:/iverilog/bin/iverilog.exe --vvp C:/iverilog/bin/vvp.exe
```

加入 `--full-chain --vsim E:/modelsim/modelsim_ase/win32aloem/vsim.exe --vendor-sim D:/TD3/sim_release/eg4` 可运行真实图片读取与缩放链路，依赖用户本地安装的厂商RAM仿真模型。厂商库不随仓库重新分发。运行时间显著长于控制测试。

所有输出写入指定目录。测试范围和板上验收步骤见 `docs/IMAGE_ZOOM_V193.md`。软件仿真不验证板卡HDMI信号完整性。
