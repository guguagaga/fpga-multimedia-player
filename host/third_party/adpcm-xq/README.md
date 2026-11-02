# ADPCM-XQ 源码

上游项目：https://github.com/dbry/adpcm-xq

本目录保留工程配套 IMA ADPCM 编码工具的 C 源码与原 BSD 许可。编码参数为 `-8 -b10 -n`；预编译 Windows 工具在 `host/video/codec14/adpcm-xq.exe`，文件身份由该目录清单记录。

用支持 C99 的编译器可从这三个 C 文件重新编译，例如：

```text
gcc -O3 -std=c99 adpcm-xq.c adpcm-lib.c adpcm-dns.c -lm -o adpcm-xq.exe
```

源码及许可从工程既有配套工具提取，打包日期为 2026-11-02。构建后的可执行文件哈希可能随工具链变化，应重新执行编码、解码和样本数核对后使用。项目未将 IMA 算法或 ADPCM-XQ 软件声明为原创。
