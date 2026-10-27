# QOI BRAM32K回归

2026-10-27：完全人工合成的QOI字节和独立Python像素参考；所有操作码、alpha散列、碰撞、输入空洞、输出阻塞、两张8192像素完整图及177像素取消/重启。生产BRAM32_INDEX=1与默认推断存储逐拍一致。用户提供本地合法TD仿真模型，仓库不再分发模型。

```powershell
$env:MODELSIM='E:/modelsim/modelsim_ase/win32aloem/vsim.exe'
$env:TD_SIM_DIR='D:/TD3/sim_release/eg4'
python -X utf8 verification/qoi_bram32/run.py
```

结果位于generated/qoi_bram32.json；不等于完整SD读图或时序、实板验收。
