# v187 R3：AUTO切图间隔显示，独立内部STA通过，待上板

R3已修复旧网表引用错误，并将QOI启动脉冲寄存一拍。独立新进程重开最终布线数据库，以未放宽的完整生产SDC检查：setup **+0.301ns**、hold **+0.024ns**，两类TNS和违例端点均为0。9个预期时钟、HDMI像素→串行同步路径、详细覆盖类别检查均通过，coverage **96.31%**。

| 资源 | R3 | v186 |
|---|---:|---:|
| LUT |18221/19600|18207/19600|
| Slice |9389/9800|9391/9800|
| BRAM9K |63/64|63/64|
| BRAM32K |16/16|16/16|
| DSP |22/29|22/29|

本版尚未上板，不更改v186正式Release的稳定资格。原有外部IO/CDC审计范围限制和SDRAM时钟local routing警告保留。

## 验收文件

`D:/codexworks/osd_carousel_v187/delivery_v187_R3_seed24_STA_PASS/bitstream/codec15_v187_R3_AUTO_seed24_INDEPENDENT_STA_PASS_BOARD_TEST.bit`

SHA256：`a2f440504dbf6b1dbeb8d096bd37d5e1f40cc07833f79339d54280f0c52a0a74`

完整本地包包含源码、独立STA/覆盖/资源报告和仿真证据。配套SD文件不变。顶部PLAY右侧、音频格式左侧显示AUTO: OFF；开启图片轮播后显示实际生效间隔，16档2..600秒。视频模式保留这项图片配置状态。亮度/对比度提示优先约3秒，之后恢复。加载中改档遵循原安全生效边界。

上板检查：复位后图片页等5秒观察OFF；KEY4开关轮播并测试2/10/600秒；连续切图与亮度提示恢复；进入/退出视频；CS声音流畅度、片尾同步及自动切换。

## 变更和证据

- 状态使用请求/应答邮箱跨域，源数据保持到确认；目的域帧边界锁存，防止帧内混合数字。
- 全16档+OFF最终RGB71,808像素；全帧921,600像素对照v186，只有状态区1122像素变化，区域外RGB和DE/VS一致。
- CDC32状态、1000快速变化、目的时钟暂停及复位；cfg安全边界全部16档。
- QOI启动脉冲增加一拍寄存，缩短写请求确认→QOI寄存器的组合控制路径，缓冲字节仍按ready握手。
- QOI320x240及BMP1280x960实际SD流→解码→缩放→写入/提交，各921,600像素通过；QOI取消待启动和重启通过。
- 源码/gate/布线DB/bit哈希绑定，新物理流程明确导入本次新gate绝对路径。独立STA细节见 `verification/osd_carousel_r3/independent_signoff.json`，原始报告 `independent_routed.timing`。

当前仓库根project_manifest.json/release_status.json仍保留v186冻结发布身份，不能拿它们对本分支直接执行旧verify_release.py并声称R3通过。R3构建/测试复现入口见verification/osd_carousel_r3；本机冻结工程在D:/codexworks/osd_carousel_v187/rebuild_r3/candidate/project。厂商IP只从本地合法工程导入，不在GitHub分发。

## 已撤回候选与失败记录

旧E3A876…、6713FA…候选误用了旧syn_1 gate.db，源码仿真与位流不对应。此前+3.978ns只有DeriveClock50MHz，作为工程签核无效，已撤回。移除视频隐藏不是图片模式也无显示的根因，先前归因有误。

R2 seed26独立setup -0.730ns/2端点，seed24 -0.166ns/1端点，均不通过；seed18/12因持续拥塞终止并保留日志。R2诊断bit94e7eb…不再作为本次验收目标。v186源目录中曾误覆盖的两个文件已恢复，全部130文件哈希核对通过，原bit/DB未改变。
