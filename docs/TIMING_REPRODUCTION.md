# 时序复现与 TD 工程运行

本仓库保持 `rtl/`、`constraints/`、`project_template/`、`host/`、`tools/` 的分模块结构。本次更新包含工程配置、构建及复现脚本；位流、物理数据库和完整交付压缩包由接收方在本地保存。

## 打开源码工程

需要 TD 6.2.168116、Python 3.11 或更新版本。将仓库放在 D 盘英文路径，在仓库根目录打开 PowerShell。`$vendorProject` 选择匹配的原厂依赖目录，例如本地完整交付包中的 `vendor_original`：

```powershell
$vendorProject = Read-Host '输入匹配原厂依赖目录的完整路径'
python tools/verify_release.py --vendor-project "$vendorProject"
if ($LASTEXITCODE -ne 0) { throw '输入校验失败' }
python tools/assemble_project.py --vendor-project "$vendorProject" --out ./build_workspace/review/project
if ($LASTEXITCODE -ne 0) { throw '工程装配失败' }
```

在 TD 中打开 `build_workspace/review/project/td_project/HDMI1.4b_Transmitter_v1.0.al`。工程引用的 131 项输入全部经过哈希检查，其中 112 项来自本仓库、19 项来自匹配原厂依赖。

`.al` 保存面积优先映射、映射策略 2、较高打包努力程度及 `more_lut_pair` 等参数。界面策略名称仍可显示 `Default`，实际配置应查看参数及运行日志。

## 从原布局数据库复现通过结果

使用本地 `FPGA_Multimedia_All_In_One.rar` 解压后的 `FPGA_Multimedia_TD` 文件夹。此完整包包含 `src/`、`implementation_checkpoint/`、`bitstream/`、原结果与校验清单。本次源码更新没有上传该 RAR；11 月 2 日的历史 Release 附件不作为此入口的输入。

在本 Git 仓库根目录执行：

```powershell
$deliveryRoot = Read-Host '输入本地完整包解压后 FPGA_Multimedia_TD 文件夹的路径'
$tdCommand = Read-Host '输入本机 td_commands_prompt.exe 的完整路径'
python tools/reproduction/reproduce_from_place.py --project-root "$deliveryRoot" --td-command "$tdCommand"
if ($LASTEXITCODE -ne 0) { throw '复现或独立时序检查失败，请查看本次日志' }
```

脚本校验完整包文件，复制原 `_place.db`，从 `opt_route` 阶段重新布线、修复保持时间并生成位流；之后启动独立 TD 进程，重新加载新 `_pr.db` 和生产约束检查时序。每次运行新建目录，输出位于本地完整包的 `src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/reproduce_place_运行时间/`。

最终报告位于该目录的 `independent_check/`：`result.json`、`fresh_pr.timing` 和 `route.qor`。`flow_stdout.txt`、`settings.cfg`、`local_flow.tcl` 分别记录实际日志、配置和执行流程。可加 `--prepare-only` 仅检查文件并准备运行目录，不启动布线。

2026 年 11 月 3 日从完整 RAR 新解压目录运行的结果为：

| 检查项 | 独立复核结果 |
|---|---:|
| 建立裕量 | +0.318 ns |
| 保持裕量 | +0.022 ns |
| 建立／保持违例端点 | 均为 0 |
| STA 覆盖率 | 96.36% |

时钟集合、频率、生产约束和覆盖范围核对通过；HDMI 同步时钟路径仍在检查范围内。新旧位流均为 719252 字节，仅文件头 `# Date:` 行中的 5 个字节不同，其余字节完全一致。原位流 SHA-256 为 `41b03883c718e0d52f04e61a9cf0228363c1bdfc3c3e51d023bcb012e3d267f4`。

该结果以原布局数据库为起点，不重新综合或布局。修改 RTL 后，应重新构建修改后的设计；原布局数据库不会包含后续代码改动。

## 关键设置与执行顺序

| 设置 | 值 |
|---|---|
| 起止阶段 | `opt_route` → `bitgen` |
| SD 优化阶段 setup uncertainty | 0.600 ns |
| 视频优化阶段 setup uncertainty | 0.300 ns |
| `route effort` | `routability` |
| `route post_route_opt` | `high` |
| `route postrt_opt_extra_round` | `4` |
| 保持时间修复 | `route` 后单独执行 `fix_hold` |
| 最终检查 | 独立进程恢复生产 SDC，执行 final STA |

脚本只在生成的运行目录中调整模板：开始阶段改为 `opt_route`，并在 `route` 前重新加载生产 SDC 和优化裕量。源 RTL、原厂 IP、引脚约束和生产 SDC 不变。

`restore_production_sdc` 将生产 SDC 文件清单独立保存，避免 `clear_sdc` 改动工具全局变量后丢失约束。优化裕量用于引导布线，最终报告恢复生产约束。运行进程内的时序报告可能与独立重新加载后的结果不同，最终数值以独立检查为准。

## 从源码重新综合、布局和布线

```powershell
$vendorProject = Read-Host '输入匹配原厂依赖目录的完整路径'
$tdCommand = Read-Host '输入本机 td_commands_prompt.exe 的完整路径'
./tools/build.ps1 -VendorProject "$vendorProject" -TdCommand "$tdCommand" -Python python -Seed 18
```

完整构建使用包内综合／物理配置及 SD 0.600 ns、视频 0.300 ns 的优化裕量。种子 18 影响新布局起点；从原布局续跑时不重新应用布局种子。

从源码重新布局的结果需要单独检查。此前一次对照完成布线但存在 −0.128 ns 建立违例；11 月 3 日另一次全源码对照完成综合和布局，随后在布线未完成时停止。本次已验证的成功复现范围是原布局续跑，未证明 GUI 普通全流程或从源码全量构建必然通过时序。

有意修改公开构建输入后，可先运行 `python tools/refresh_project_manifest.py` 查看差异，再加 `--accept-local-edits` 更新清单；脚本在 `build_workspace/` 保存旧清单。可用 `--vendor-project` 额外检查原厂依赖，原厂文件不匹配时拒绝更新。更新清单不改变已验收位流或原时序证据的适用范围。
