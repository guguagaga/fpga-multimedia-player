# v185 / 64 扇区候选验证复现

需要 Python 3.11+。请把交付包解压到 D 盘。默认工程路径是同包 `source/candidate/project`；使用 GitHub 分模块源码时，先按 project_manifest 还原工程，并以 `--project` 指定路径。

## 厂商模型仿真

需要自行安装 ModelSim 和合法取得的 Tang Dynasty。厂商库不随包分发；运行前核对库、源码及测试数据 SHA256。

```powershell
python -X utf8 .\run.py --list
python -X utf8 .\run.py --case peak720p --project 'D:\你的工程' --vsim 'E:\modelsim\modelsim_ase\win32aloem\vsim.exe' --td-root 'D:\TD3'
```

spi、spi_tail 检查实际 SPI 协议、64 扇区缓存和 CMD12 收尾；scanout 检查实际读取区反馈和手动/自动切换；long_control 覆盖 8136 帧小像素控制及 EOF；peak720p 对 30 张完整 720P 画面、48000 个 PCM 样本和每个显示间隔检查。全尺寸厂商模型可能运行数小时。

## 编译仿真持续压力

使用 Verilator 和 MinGW/w64devkit，版本记录见证据目录。仅 RAM 原语换成已做厂商模型差分的仿真模型；候选 RTL 不变。

```powershell
python -X utf8 .\run_compiled.py --case peak300_50000 --project 'D:\你的工程' --tool-root 'D:\codexworks\toolchains\oss-cad-20261029' --validate-only
python -X utf8 .\run_compiled.py --case peak300_50000 --project 'D:\你的工程' --tool-root 'D:\codexworks\toolchains\oss-cad-20261029'
```

可选 peak30_40000、peak300_40000、peak300_50000。300 帧使用最高码率一秒的原编码载荷重复十次，配 11 秒 IMA 音轨，消费前 10 秒的 480000 个样本；不是完整影片 RTL 仿真。所有 299 个间隔必须为 3030304 核心周期，且检查像素、PCM、EOF。失败结果不得当作通过。

原始验证所用 cases 清单另存 original_validation_cases.json。当前复现清单只保留本次门禁使用的厂商模型用例，故清单整体哈希与历史运行记录不同；每项原始 RTL 与素材哈希保持一致。运行目录自动新建，不覆盖历史记录。这里不宣称实际 SD 卡、外部 IO 和整板验收已通过。
