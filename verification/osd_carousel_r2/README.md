# v187 R2验证记录

此目录保存修复构建数据库引用错误时的RTL测试与v186参照。旧v187候选已撤回，不能使用旧的+3.978ns数字。rebuild_local.py为当前机器的构建审计脚本，固定D盘路径，不是通用发布构建入口。

- tb_rgb.v：16档及关闭，71,808个最终RGB像素，帧边界锁存，B/C提示优先级。
- tb_cdc.v：32状态、1000次快速变化、目的时钟暂停和共同复位。
- tb_frame.v：921,600像素对照v186，仅状态矩形变化，DE/VS一致。
- top_rtl.png：真实RTL RGB输出的顶部裁剪，示例AUTO: 10s。

运行用Icarus Verilog -g2012，顶层tb。RGB和frame使用osd_player_ui.v、char_rom.v、osd_brand_rom.v；frame还需reference_osd.v；CDC使用carousel_period_cfg.v。请在含匹配font_8x16.mem、cjk_brand_16x16.mem、anlogic_logo.mem的目录运行。参考ROM取自本次还原工程。

当前有效构建证据在D:/codexworks/osd_carousel_v187/rebuild_r2，布线后独立STA尚在进行，不能称为通过。
