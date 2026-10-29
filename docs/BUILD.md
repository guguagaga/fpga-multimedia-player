# v183 候选工程还原与构建

环境：Windows、Tang Dynasty 6.2.168116、EG4S20BG256、Python 3.11或更新版本、PowerShell。仿真使用ModelSim及Icarus。

从合法持有的本版完整工程导入厂商IP。旧版PLL可能不同，不能绕过哈希检查。当前本机匹配工程为：
`D:/codexworks/board_recovery_v170_20261028/delivery_v182_seed24_playback_recovery_20261029/candidate/project`。

```powershell
python tools/assemble_project.py --vendor-project "D:/你的匹配工程" --out build_workspace/candidate/project
pwsh -NoProfile -File tools/build.ps1 -VendorProject "D:/你的匹配工程" -TdCommand "D:/TD3/bin/td_commands_prompt.exe" -Seed 26
```

assemble_project逐文件检查哈希，拒绝覆盖修改过的文件。build.ps1完成构建后，以独立TD进程再次读取最终布线库及原SDC；该独立报告是时序验收依据。重新布线可能产生不同结果。

```powershell
python tools/recheck_board_routed.py build_workspace --seed 26 --td-command "D:/TD3/bin/td_commands_prompt.exe"
python tools/verify_release.py
```

verify_release核对公开候选源码、工程映射、独立时序和测试证据身份，不运行整机仿真。当前证据在releases/v183/evidence；已上板确认的v182保留在对应tag和Release。


## v183 候选构建

本分支通过独立内部时序检查的是 seed26。请使用 `-Seed 26`；位流仍待上板验收。
不要仅凭同一构建进程的 QoR 判断通过，必须完成 `recheck_board_routed.py` 的独立时序检查。

## 功能仿真

控制、末帧跨域、视频切换和音频切换可使用便携入口：

```powershell
python verification/playlist/run_checks.py --project build_workspace/candidate/project --test controls --benches verification/playlist --output build_workspace/test_controls
```

`--test` 还可选 `eof`、`video`、`audio`。输出目录须不存在，避免覆盖证据。
视频和音频用例使用 ModelSim 及 TD 厂商 RAM 模型；可用 `--modelsim`、`--td-root` 指定路径。
720P三帧测试引用私有原片fixture，公开仓库保留台架和结果，单凭公开台架不能复现该私有素材测试。
内部STA沿用稳定版约束；外部IO、CDC与板级长期稳定性仍需分别验收。
实板步骤见 [BOARD_ACCEPTANCE_V183.md](BOARD_ACCEPTANCE_V183.md)。
