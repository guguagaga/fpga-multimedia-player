# 验证代码目录与运行范围

## 对外入口

从解压后的 `工程源码` 目录运行 `tools/verify.ps1`、`tools/verify_native720p.ps1` 或 `tools/verify_fat32.ps1`。这些入口按包路径装配生产源码，将测试模型复制到包内工作目录，并接收调用者提供的模拟器路径。`tools/verify_audio_recovery.py` 直接按自身路径定位 RTL 和模板，支持指定 Icarus Verilog 与 vvp。

## 归档平台

以下目录为开发过程或特定实验配置的归档，不由生产构建/编码入口调用：`osd_carousel_r2`、`osd_carousel_r3`、`dynamic_directory`、`codec14`、`playlist`。其中带有 `local`、`rebuild`、`route` 的脚本及部分 `.do` 保留生成时的工程路径、工具路径或参考模型位置。重新执行时应先按当前装配工程与工具参数适配，并核对模型边界；本次迁移检查不将这些归档脚本声明为即开即用。

其余模块目录保存测试平台、参考模型和既有记录。历史日志中的绝对路径用于证据追溯，不是当前生产程序的运行依赖。技术报告所引验证状态按对应输入和版本范围解释，不以脚本存在代替测试通过。
