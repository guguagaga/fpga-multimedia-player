# v187 OSD 自动切图间隔候选

本候选在 v186 已上板确认的源码基线上加入图片轮播状态显示。v186 发布位流和 GitHub 正式 Release 不变；本文件描述的是尚未上板的 v187 候选。

## 画面行为

顶部参数区在图片模式下持续显示实际生效的轮播状态：

- 关闭：`AUTO: OFF`
- 开启：`AUTO: 2s`、`AUTO: 10s`、`AUTO: 120s`、`AUTO: 600s` 等

文本来自 `carousel_period_cfg` 已经在安全边界锁存的周期，以及 `sd_card_bmp` 的实际自动开关状态，不直接读取拨码原始值。图片装载期间改变拨码时，OSD 继续显示旧的有效周期，直到新档位真正生效。进入视频模式后隐藏该文本。

亮度/对比度变化时，已有的约 3 秒 `B:+16 C:160` 提示优先显示；提示结束后恢复自动切图状态。

## CDC 与实现

SD 时钟域将 `{img_auto_on, exp_period_code}` 保持在稳定寄存器中，并翻转一个状态 toggle。视频时钟域同步 toggle 和数据快照，在检测到 toggle 后一次性更新，避免逐位同步造成混合数字。视频域使用 16 项查表生成显示数字，没有在像素路径上加入通用除法器。

## 验证结果

独立 OSD 文本测试通过：关闭、2 秒、10 秒、120 秒、600 秒；同时保留品牌 ROM 的同步读延迟和已有显示输出结构。

使用 Tang Dynasty v6.2.168116、EG4S20BG256、seed 26 完成新鲜综合及完整物理布线：

| 项目 | 结果 |
|---|---:|
| setup WNS | +3.978 ns |
| hold WNS | +0.075 ns |
| setup/hold TNS | 0 / 0 |
| setup/hold 违例端点 | 0 / 0 |
| STA coverage | 92.43% |
| Slice | 9391 / 9800（95.83%） |
| BRAM | 79 个（其中 BRAM32K 16/16） |
| DSP | 22 / 29 |

候选 bit：

`D:\codexworks\framerate_v185_20261029\hdmi_no_signal_v185\scaler_compare_pipeline\candidate\project\td_project\HDMI1.4b_Transmitter_v1.0_Runs\osd_v187_phy_seed26_final\HDMI1.4b_Transmitter_v1.0.bit`

SHA256：`7f03054836550f814cbcdfc3239012be7a29deb002bb7bfb9150d1b184b9cdee`

> 注意：此候选只完成 RTL/全流程验证，尚未经过用户上板。因此不能称为稳定版，也不能覆盖 v186。上板前还应检查 16 档实际显示、图片切换边界、视频进入/退出、OSD 与 HDMI 画面稳定性。

