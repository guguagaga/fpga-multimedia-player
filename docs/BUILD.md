# 构建与验证

## 环境和厂商依赖

Windows、Python 3.11 或更新版本，以及安路 Tang Dynasty 工具。目标器件为 EG4S20BG256。实际安装版本请以工具 About 或启动信息为准。仿真脚本还需要相应 ModelSim、Icarus Verilog 或 Verilator；具体入口参数见脚本帮助。

将 Git 仓库检出到 D 盘，在 PowerShell 中进入仓库根目录。下文路径以该目录为起点。Git 源码提供 112 项公开构建输入及配套工具；19 项原厂依赖保留原版权、许可与加密内容，通过外部路径导入。完整 Release RAR 自带匹配的 `工程源码/vendor_original`，来源与校验值见 `docs/EXTERNAL_DEPENDENCIES.json`。

```powershell
python tools/verify_release.py
$vendorProject = Read-Host '输入完整 Release 解压后 vendor_original 目录，或合法持有的匹配原厂工程根目录'
python tools/verify_release.py --vendor-project $vendorProject
python tools/assemble_project.py --vendor-project $vendorProject --out ./build_workspace/candidate/project
```

第一条命令仅校验 112 项公开输入及 13 项编码工具，明确标出外部依赖未检查；指定外部目录后补全 19 项身份核对。装配器逐项核对 SHA-256，成功后得到 131 项完整构建输入。完整 RAR 内的装配器可默认读取随包原厂依赖。许可范围见 `LICENSE_SCOPE.md`。

## 从源码重新构建

```powershell
$tdCommand = Read-Host '输入本机 td_commands_prompt.exe 完整路径'
& ./tools/build.ps1 -VendorProject $vendorProject -TdCommand $tdCommand -Python python -Seed 18
```

脚本先校验并装配工程，再综合、布局布线，并在独立进程内恢复生产时序约束检查建立、保持及覆盖范围。优化阶段使用 SD 0.600 ns、video 0.300 ns 的附加裕量；最终签核恢复生产 SDC。

随报告的通过位流由既定 seed18 布局数据库继续执行布线优化取得。从源码重新布局可重建功能设计，但布局数据库和工具版本会影响物理结果，不能把新构建自动标记为既有位流的时序通过。必须检查新产生的报告，并重新进行板级验收。

内部 STA 覆盖生产约束所定义的路径。外部接口延迟和异步跨域检查范围见约束与技术报告；其范围不由 WNS 数值代替。

## 验证入口

- `tools/verify_release.py`：本包 FPGA 构建输入、编码工具及生产 RTL 一致性检查。
- `tools/verify.ps1`：装配后运行 SD 与图片相关回归，需要 ModelSim。
- `tools/verify_native720p.ps1`：像素、缓冲和时序模型回归，需要脚本声明的模拟器与器件库。
- `tools/verify_fat32.ps1`：FAT32 回归，参数见脚本。
- `verification` 中模块级平台可独立运行；历史文件名用于匹配测试对象，结果不能未经核对直接套用于更改后的 RTL。

本次交付准备只运行源码装配校验、脚本语法检查及媒体工具冒烟测试，没有重复执行完整 FPGA 综合布线。

`verify_routed.py` 与 `coverage_baseline.json` 保留为较早约束审计的研究工具，不是当前一键构建入口。当前入口调用 `recheck_board_routed.py`，采用 `docs/CONSTRAINT_POLICY.json` 绑定的生产 SDC；若修改约束或覆盖范围，应另外建立对应的审计基准。

## 可移植入口与归档材料

生产构建入口为 `tools/build.ps1`，装配和包校验入口分别为 `tools/assemble_project.py`、`tools/verify_release.py`。脚本通过 `__file__` 或 `$PSScriptRoot` 定位包内输入；EDA、模拟器和 FFmpeg 由使用者参数指定。将包移动或重新解压后无需修改源码中的工程根路径。

`tools/verify.ps1`、`tools/verify_native720p.ps1`、`tools/verify_fat32.ps1` 在 Git checkout 中传入 `-VendorProject` 指向匹配依赖，均支持 `-Python`。仿真工具参数必须指向接收方实际安装位置。

`verification/README.md` 划分可移植测试入口与开发过程归档平台。归档中的运行记录、原始 `.do` 及局部重布局脚本可能包含原实验路径，用于追溯试验输入，不属于生产构建或编码入口。它们没有在本次迁移检查中重新执行，也不会被生产构建自动调用。
