# GitHub 备份与配套文件

源码仓库：https://github.com/guguagaga/fpga-multimedia-player

本次完整交付：https://github.com/guguagaga/fpga-multimedia-player/releases/tag/submission-20261102

仓库提供分模块源码、PC 编码工具、验证入口、技术报告和源码注释示例。Release 附件保存完整源码压缩包、PDF、可编辑文档和记事本示例；SHA256SUMS.txt 记录附件校验值。

本地文件遗失或需要转交队员时，从同一 Release 下载完整源码包和技术报告，核对 SHA-256 后解压。以该发布中的源码、位流、码表及编码工具配套使用。完整源码包包含构建依赖与普通输入样例，使用方法见解压后的工程源码/README.md。

PowerShell 校验示例（在下载文件所在目录执行）：

```powershell
Get-FileHash -LiteralPath ./fpga-multimedia-player-source-complete.rar -Algorithm SHA256
Get-FileHash -LiteralPath ./technical-report.pdf -Algorithm SHA256
```

将显示的摘要与 SHA256SUMS.txt 对应行核对。仓库源码通过 Git 提交保存修改顺序；固定 Release 对应本次交付，后续修改另行发布。全部原作者版权及许可随文件保留。
