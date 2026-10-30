# v185 精确工程还原与构建

Windows、Tang Dynasty 6.2.168116、EG4S20BG256、Python3.11+、PowerShell。工作与临时目录放D盘。厂商依赖按manifest从合法持有工程导入；本机匹配工程为 D:/codexworks/framerate_v185_20261029/residual_hybrid64_lutqoi/candidate/project。

```powershell
python -X utf8 tools/verify_release.py
python -X utf8 tools/assemble_project.py --vendor-project 'D:/你的匹配工程' --out build_workspace/candidate/project
& .\tools\build.ps1 -VendorProject 'D:/你的匹配工程' -TdCommand 'D:/TD3/bin/td_commands_prompt.exe' -Python 'python' -Seed 26
```

build.ps1先核对原始源码并导入依赖，使用0.6ns SD /0.2ns视频额外收紧目标布局布线，再新开TD进程按原SDC签核。必须检查全部时钟、setup/hold与coverage类别；构建进程内QoR不能替代该复核。重建bit可能不同，旧二进制报告不能作为新bit的证明。

Release中的tools-verification.zip提供完整仿真数据；在其verification目录运行run.py或run_compiled.py，并用--project指向已还原工程。详细版本/范围见包内README。下载的bit仍需用户上板确认；现有外部IO和CDC审计边界没有被内部STA通过消除。
