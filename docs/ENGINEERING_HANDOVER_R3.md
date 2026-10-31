# R3 工程交付说明

## 当前基线

R3 在 v186 的 HDMI 时序修复、图片缩放和播放列表上板基线之上增加实际 AUTO 轮播状态显示，并把 QOI 启动控制寄存一拍。独立生产 SDC 新进程 STA：setup +0.301ns、hold +0.024ns、TNS 0、违例端点 0，覆盖96.31%。R3 等待用户上板确认；v186 Release 仍是稳定回退。

## 模块变更

- `rtl/display/osd_player_ui.v`：顶部参数区显示 `AUTO: OFF` 或实际秒数；帧边界锁存状态，亮度/对比度提示优先。
- `rtl/top/top_tf_hdmi_audio.v`：SD→video 一致性状态邮箱，来源为安全边界已生效的 `{img_auto_on, exp_period_code}`。
- `rtl/control/carousel_period_cfg.v`：保留 16 档 2/3/5/8/10/15/20/30/45/60/90/120/180/240/300/600 秒。
- `rtl/image/bmp_read.v`：QOI 启动脉冲寄存一拍，并在新启动拍忽略上一图残留终态；连续 QOI 错误/正常重启回归通过。

## 预读研究结论

R3 已有预读，但过去在周期过半后才启动，主要用于音频带宽保护。v188 尝试在音频水位充足时提前启动，固定模型等待减少约27.9%，但直接实现的准入逻辑造成 setup -1.343ns。复用单比特 `fifo_lvl==3` 后仍有 -0.030ns。v188 不交付，所有失败报告保存在 `verification/image_prefetch_v188` 和 D 盘实验目录。

下一轮如果继续，优先把提前预读请求放到独立调度事件，减少 SD 时钟域组合扇出；先保持当前仲裁器事务所有权和音频最久等待上限，再进行全量STA。不要直接增加 BRAM、复制比较器或删掉音频保护。

## 验证入口

`verification/osd_carousel_r3/independent_signoff.json`：R3 独立STA与源绑定。

`verification/osd_carousel_r3/image_chain.json`：QOI/BMP 实际字节流到写帧提交。

`verification/osd_carousel_r2`：OSD 16档、CDC、全帧像素对照和 QOI 启动修复证据。

`verification/image_prefetch_v188`：提前预读研究、收益和时序失败记录。

复现工程时使用 R3 专用 `verification/osd_carousel_r3/project_manifest.json`，不要把冻结 v186 的根 `project_manifest.json` 当成 R3 manifest。厂商加密 IP 必须从本地合法工程按哈希导入。

## 拍摄交付

拍摄流程见 `docs/CAPTURE_PLAN_R3.md`。交付视频应同时保存原始 HDMI 采集文件、屏幕直拍文件、版本 SHA、SD 清单和按键/显示器设置；剪辑字幕把读卡等待标为系统行为，不声称任意图片固定在设定秒数完成。


## v188提前预读研究最终结论

功能仿真中，音频水位充足时提前预读把两次QOI切换等待从约5.55M/11.06M周期降为4.00M/8.00M，减少约27.9%；BMP/QOI整帧和音频模型回归通过。连续QOI残留done缺陷已修复并有5次重启回归。

但提前准入增加在SD时钟域后，完整生产SDC STA为-1.343ns/17端点；复用已有fifo_lvl单比特后，seed24/12/26均为-0.030ns/1端点。v188不交付。R3保持唯一验收基线。下一轮需把预读准入移到独立时隙调度或仲裁器内部既有事务状态，不能再依赖新增SD组合比较器。
