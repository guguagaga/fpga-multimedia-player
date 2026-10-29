# v182 工程还原与构建

环境：Windows、Tang Dynasty 6.2.168116、EG4S20BG256、Python 3.11或更新版本、PowerShell。仿真使用ModelSim及Icarus。

从合法持有的本版完整工程导入厂商IP。旧版PLL可能不同，不能绕过哈希检查。当前本机匹配工程为：
`D:/codexworks/board_recovery_v170_20261028/delivery_v182_seed24_playback_recovery_20261029/candidate/project`。

```powershell
python tools/assemble_project.py --vendor-project "D:/你的匹配工程" --out build_workspace/candidate/project
pwsh -NoProfile -File tools/build.ps1 -VendorProject "D:/你的匹配工程" -TdCommand "D:/TD3/bin/td_commands_prompt.exe" -Seed 24
```

assemble_project逐文件检查哈希，拒绝覆盖修改过的文件。build.ps1完成构建后，以独立TD进程再次读取最终布线库及原SDC；该独立报告是时序验收依据。重新布线可能产生不同结果。

```powershell
python tools/recheck_board_routed.py build_workspace --seed 24 --td-command "D:/TD3/bin/td_commands_prompt.exe"
python tools/verify_release.py
```

verify_release验证公开生产源码、发布清单和编码工具，不运行整机仿真。旧verification脚本保留作为历史测试，不能未经复核就宣称覆盖本版。当前原始验证证据在releases/v182/evidence。
