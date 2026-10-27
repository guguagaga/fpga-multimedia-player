# 目录与图片头流水回归

2026-10-27，全部输入为人工生成，不含真实SD卡或版权媒体。参考实现为优化前的工程自有源码，保留用于外部接口逐拍对照。

目录：16组完整扫描，SPC1..128、连续/间歇字节、碎片根目录、所有媒体类型、容量上限、重复和无效项、高簇号。

图片头：83类BMP/QOI头，缩放开/关、扫描/加载，共332次判定；另与Python接受条件核对。此测试不解码完整图片，完整链路模型和STA结果另见docs/VALIDATION.md。

在公开仓库根目录执行：

```powershell
$env:IVERILOG='C:/iverilog/bin/iverilog.exe'
$env:VVP='C:/iverilog/bin/vvp.exe'
python -X utf8 verification/pipeline/run_directory.py
$env:MODELSIM='E:/modelsim/modelsim_ase/win32aloem/vsim.exe'
$env:TD_SIM_DIR='D:/TD3/sim_release/eg4'
python -X utf8 verification/pipeline/run_header.py
```

按自己的安装位置调整路径。器件仿真模型由用户合法安装的TD提供，未随仓库分发。结果在generated目录，已被gitignore排除。

补充回归：`python -X utf8 verification/pipeline/run_root_tail.py`验证root cluster127的FAT项位于扇区最后4字节时的7种边界；使用上面的IVERILOG/VVP环境变量。`python -X utf8 verification/pipeline/run_cache32.py`比较推断SD缓存与实际BRAM32K原语，51事务/26112字节，使用MODELSIM/TD_SIM_DIR。两者均为人工模型，不代表真实SD卡电气时序。
