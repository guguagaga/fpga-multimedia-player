# v186 精确工程还原与构建

Windows、Tang Dynasty 6.2.168116、EG4S20BG256、Python3.11+、PowerShell；工作和临时文件放D盘。厂商依赖按project_manifest.json从合法持有的匹配工程导入。本机匹配工程：D:/codexworks/framerate_v185_20261029/hdmi_no_signal_v185/scaler_compare_pipeline/candidate/project。

```powershell
python -X utf8 tools/verify_release.py
python -X utf8 tools/assemble_project.py --vendor-project 'D:/你的匹配工程' --out build_workspace/candidate/project
& .\tools\build.ps1 -VendorProject 'D:/你的匹配工程' -TdCommand 'D:/TD3/bin/td_commands_prompt.exe' -Python 'python' -Seed 26
```

构建以0.6ns SD /0.2ns视频额外目标优化，最终恢复实际签核SDC，再新开TD进程重开数据库。CONSTRAINT_POLICY.json明确记录新增HDMI同步时序覆盖和图片控制流水修改，保留原约束哈希，不伪造旧基线。检查全部时钟、setup/hold、覆盖率与新增路径；同进程QoR不能替代独立复核。重建位流可能不同，需要重新验证，旧报告只对应记录中的SHA256。

测试包包含位流、两个视频/音轨、独立音乐和图片。源码工具包另含编码器和持续仿真复现数据；厂商库不随包分发。详细测试范围见PERFORMANCE_RESULTS_720P30.md。
