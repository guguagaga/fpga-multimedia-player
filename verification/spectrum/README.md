# 频谱计算复核

`verify_spectrum.py` 将包内 RTL 的 ModelSim 输出与独立 Python 整数模型逐项比较，并计算报告中的窗增益、频点映射、幅值近似误差和 FFT 计算量。`tb_spectrum.v.in` 是配套仿真平台模板，运行时生成具体样本数和帧数。

## 运行

准备 Python 3.11 或更新版本、NumPy，以及可用的 ModelSim。工程解压在 D 盘后，从 `工程源码` 根目录运行：

```powershell
$vsim = Read-Host '输入本机 ModelSim vsim.exe 完整路径'
$out = './verification_output/spectrum_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
$env:PYTHONDONTWRITEBYTECODE = '1'
python verification/spectrum/verify_spectrum.py --vsim $vsim --output $out
if ($LASTEXITCODE -ne 0) { throw '频谱复核失败，请查看输出目录的 simulation.log' }
```

输出目录必须是尚不存在的 D 盘目录。运行时从脚本位置确定工程根目录，无需配置开发者本机源码路径。断言参与结果比较，Python 应按普通模式运行，勿加入 `-O`。仿真最长等待 300 秒。

所有生成文件、仿真库和临时目录均位于指定输出目录。其中 `simulation.log` 保留仿真日志，`rtl_values.txt` 保存逐项结果，`spectrum_math_verification.json` 保存最终计算结果和本次源码 SHA-256。日志中的文件名可能使用 Windows 本地代码页，成功标记按 ASCII 字节读取。

## 验证范围

- 输入共 11 组：静音、冲激、直流、6 组整数频点正弦、非整数频点正弦，以及固定种子的随机数据。
- 对比 2816 个加窗样本、2816 个复数 FFT 输出和 352 个频带高度，覆盖连续分析帧的峰值保持与衰减。
- 从当前源码提取 Hann 系数和频带映射，读取包内 `rtl/control/twiddle_256.mem`；模型使用与 RTL 一致的定点舍入、饱和和移位规则。
- 记录每次 `start` 到 `done` 的周期数；校核频带分组及柱高查表公式，并以 NumPy 浮点 FFT 提供误差参照。

本目录的 `spectrum_math_verification.json` 是本次提交源码的复核运行结果，路径采用工程根目录下的相对路径，哈希对应本次运行实际读取文件。`source_sha256` 中的顶层及 `spectrum_display.v` 是关联设计记录；此次逐值仿真的直接编译单元为 `audio_frame.v`、`fft_256.v`、`butterfly.v`、`twiddle_rom.v`、`spectrum_capture.v` 和 `dp_ram.v`。

`../report/spectrum_math_verification.json` 保留早期报告计算记录，内部的绝对路径及哈希表示当时验证来源。其 `candidate_shared_onehot/rtl/…` 路径在本包按相同 `rtl/…` 相对路径查找；验证当前源码请以本目录结果或重新运行结果为准。这里记录的是 RTL 仿真与数值模型结果，硬件音频采样和输出格式的测试另由工程验收记录描述。
