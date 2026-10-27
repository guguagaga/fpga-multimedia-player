> 源码已更新为FAT簇链候选；差异与验收状态见FAT32_CHAIN.md及release_status.json。

# 模块源码导航

模块目录便于组员按功能阅读；工程还原映射见 `project_manifest.json`。接口细节以 RTL 声明为准。这里也保留原工程参考模块；实际参与综合的文件和AutoExcluded属性以TD工程清单为准，不表示每个列出的模块都被当前顶层实例化。

## audio

统一 PCM/QOA/IMA 读取，FIFO补数、采样构建、I2S输出、音量和切歌过渡。

- [volume_control.v](../rtl/audio/volume_control.v) → `rtl/volume_control.v`
- [audio_transition.v](../rtl/audio/audio_transition.v) → `user_source/hdl_source/audio_transition.v`
- [compressed_audio_reader.v](../rtl/audio/compressed_audio_reader.v) → `user_source/hdl_source/compressed_audio_reader.v`
- [fade_in.v](../rtl/audio/fade_in.v) → `user_source/hdl_source/fade_in.v`
- [hdmi_audio_tone_i2s_64fs.v](../rtl/audio/hdmi_audio_tone_i2s_64fs.v) → `user_source/hdl_source/hdmi_audio_tone_i2s_64fs.v`
- [hdmi_audio_tone_pcm_scale.v](../rtl/audio/hdmi_audio_tone_pcm_scale.v) → `user_source/hdl_source/hdmi_audio_tone_pcm_scale.v`
- [I2S_receiver.v](../rtl/audio/I2S_receiver.v) → `user_source/hdl_source/I2S_receiver.v`
- [i2s_transmitter.v](../rtl/audio/i2s_transmitter.v) → `user_source/hdl_source/i2s_transmitter.v`
- [ima_stream.v](../rtl/audio/ima_stream.v) → `user_source/hdl_source/ima_stream.v`
- [media_player.v](../rtl/audio/media_player.v) → `user_source/hdl_source/media_player.v`
- [media_player_shim.v](../rtl/audio/media_player_shim.v) → `user_source/hdl_source/media_player_shim.v`
- [qoa_stream.v](../rtl/audio/qoa_stream.v) → `user_source/hdl_source/qoa_stream.v`
- [i2s_rom_player_single_pll_fix64_rom_ip.v](../rtl/audio/i2s_rom_player_single_pll_fix64_rom_ip.v) → `user_source/hdl_source/rom/i2s_rom_player_single_pll_fix64_rom_ip.v`
- [i2s_test_tone_gen_pll.v](../rtl/audio/i2s_test_tone_gen_pll.v) → `user_source/hdl_source/test/i2s_test_tone_gen_pll.v`
- [wav_player.v](../rtl/audio/wav_player.v) → `user_source/hdl_source/wav_player.v`
- [wav_sample_builder.v](../rtl/audio/wav_sample_builder.v) → `user_source/hdl_source/wav_sample_builder.v`

## control

按键消抖、状态机、曲目与轮播周期控制、输入同步及辅助模块。

- [button_ctrl.v](../rtl/control/button_ctrl.v) → `rtl/button_ctrl.v`
- [carousel_period_cfg.v](../rtl/control/carousel_period_cfg.v) → `rtl/carousel_period_cfg.v`
- [div_u32.v](../rtl/control/div_u32.v) → `rtl/div_u32.v`
- [exp_input_sync.v](../rtl/control/exp_input_sync.v) → `rtl/exp_input_sync.v`
- [key_long.v](../rtl/control/key_long.v) → `rtl/key_long.v`
- [keypad_scan.v](../rtl/control/keypad_scan.v) → `rtl/keypad_scan.v`
- [playback_status.v](../rtl/control/playback_status.v) → `rtl/playback_status.v`
- [player_ctrl.v](../rtl/control/player_ctrl.v) → `rtl/player_ctrl.v`
- [track_ctrl.v](../rtl/control/track_ctrl.v) → `rtl/track_ctrl.v`
- [cjk_brand_16x16.mem](../rtl/control/cjk_brand_16x16.mem) → `user_source/hdl_source/cjk_brand_16x16.mem`
- [font_8x16.mem](../rtl/control/font_8x16.mem) → `user_source/hdl_source/font_8x16.mem`
- [global_def.v](../rtl/control/global_def.v) → `user_source/hdl_source/include/global_def.v`
- [key_remove_shakes.v](../rtl/control/key_remove_shakes.v) → `user_source/hdl_source/key_remove_shakes.v`
- [startup_pulse.v](../rtl/control/startup_pulse.v) → `user_source/hdl_source/startup_pulse.v`
- [twiddle_256.mem](../rtl/control/twiddle_256.mem) → `user_source/hdl_source/twiddle_256.mem`

## display

HDMI物理封装、OSD、字体、视频时序及数码管。

- [brightness_contrast.v](../rtl/display/brightness_contrast.v) → `rtl/brightness_contrast.v`
- [osd_player_ui.v](../rtl/display/osd_player_ui.v) → `rtl/osd_player_ui.v`
- [seg595_display.v](../rtl/display/seg595_display.v) → `rtl/seg595_display.v`
- [char_rom.v](../rtl/display/char_rom.v) → `user_source/hdl_source/char_rom.v`
- [hdmi_phy_warpper.v](../rtl/display/hdmi_phy_warpper.v) → `user_source/hdl_source/hdmi_phy_warpper.v`
- [lane_lvds_10_1.v](../rtl/display/lane_lvds_10_1.v) → `user_source/hdl_source/lane_lvds_10_1.v`
- [osd_brand_rom.v](../rtl/display/osd_brand_rom.v) → `user_source/hdl_source/osd_brand_rom.v`
- [osd_core.v](../rtl/display/osd_core.v) → `user_source/hdl_source/osd_core.v`
- [ax_debounce.v](../rtl/display/ax_debounce.v) → `user_source/hdl_source/SD/ax_debounce.v`
- [color_bar.v](../rtl/display/color_bar.v) → `user_source/hdl_source/SD/color_bar.v`
- [seg_decoder.v](../rtl/display/seg_decoder.v) → `user_source/hdl_source/SD/seg_decoder.v`
- [seg_scan.v](../rtl/display/seg_scan.v) → `user_source/hdl_source/SD/seg_scan.v`
- [video_define.v](../rtl/display/video_define.v) → `user_source/hdl_source/SD/video_define.v`
- [video_delay.v](../rtl/display/video_delay.v) → `user_source/hdl_source/SD/video_delay.v`
- [video_timing_data.v](../rtl/display/video_timing_data.v) → `user_source/hdl_source/SD/video_timing_data.v`
- [video_timing_gen.v](../rtl/display/video_timing_gen.v) → `user_source/hdl_source/SD/video_timing_gen.v`
- [video_coord.v](../rtl/display/video_coord.v) → `user_source/hdl_source/video_coord.v`
- [video_rgb_to_axis_640x480.v](../rtl/display/video_rgb_to_axis_640x480.v) → `user_source/hdl_source/video_rgb_to_axis_640x480.v`
- [video_source_test.v](../rtl/display/video_source_test.v) → `user_source/hdl_source/video_source_test.v`

## image

BMP/QOI解码、缩放、流回压、加载取消、下一张预取与显示提交。

- [img_scaler.v](../rtl/image/img_scaler.v) → `rtl/img_scaler.v`
- [pixel_fifo_24x8.v](../rtl/image/pixel_fifo_24x8.v) → `rtl/pixel_fifo_24x8.v`
- [qoi_stream.v](../rtl/image/qoi_stream.v) → `user_source/hdl_source/qoi_stream.v`
- [bmp_read.v](../rtl/image/bmp_read.v) → `user_source/hdl_source/SD/bmp_read.v`
- [sd_card_bmp.v](../rtl/image/sd_card_bmp.v) → `user_source/hdl_source/SD/sd_card_bmp.v`

## memory

同步/异步FIFO与SDRAM帧读写接口。

- [async_fifo.v](../rtl/memory/async_fifo.v) → `user_source/hdl_source/async_fifo.v`
- [dp_ram.v](../rtl/memory/dp_ram.v) → `user_source/hdl_source/dp_ram.v`
- [frame_fifo_read.v](../rtl/memory/frame_fifo_read.v) → `user_source/hdl_source/SD/frame_fifo_read.v`
- [frame_fifo_write.v](../rtl/memory/frame_fifo_write.v) → `user_source/hdl_source/SD/frame_fifo_write.v`
- [frame_read_write.v](../rtl/memory/frame_read_write.v) → `user_source/hdl_source/SD/frame_read_write.v`
- [sdram.v](../rtl/memory/sdram.v) → `user_source/hdl_source/SD/sdram.v`

## spectrum

Hann加窗、FFT、幅值/角度计算与频谱叠加。

- [audio_arc_calculate.v](../rtl/spectrum/audio_arc_calculate.v) → `user_source/hdl_source/audio_arc_calculate.v`
- [audio_frame.v](../rtl/spectrum/audio_frame.v) → `user_source/hdl_source/audio_frame.v`
- [butterfly.v](../rtl/spectrum/butterfly.v) → `user_source/hdl_source/butterfly.v`
- [cordic_atan.v](../rtl/spectrum/cordic_atan.v) → `user_source/hdl_source/cordic_atan.v`
- [fft_256.v](../rtl/spectrum/fft_256.v) → `user_source/hdl_source/fft_256.v`
- [spectrum_capture.v](../rtl/spectrum/spectrum_capture.v) → `user_source/hdl_source/spectrum_capture.v`
- [spectrum_display.v](../rtl/spectrum/spectrum_display.v) → `user_source/hdl_source/spectrum_display.v`
- [twiddle_rom.v](../rtl/spectrum/twiddle_rom.v) → `user_source/hdl_source/twiddle_rom.v`

## storage

SD SPI 初始化、CMD17/CMD18缓存、扇区读取、FAT32列表及多客户端仲裁。

- [fat32_list.v](../rtl/storage/fat32_list.v) → `rtl/fat32_list.v`
- [sd_card_cmd.v](../rtl/storage/sd_card_cmd.v) → `user_source/hdl_source/SD/sd_card_cmd.v`
- [sd_card_sec_read_write.v](../rtl/storage/sd_card_sec_read_write.v) → `user_source/hdl_source/SD/sd_card_sec_read_write.v`
- [sd_card_top.v](../rtl/storage/sd_card_top.v) → `user_source/hdl_source/SD/sd_card_top.v`
- [spi_master.v](../rtl/storage/spi_master.v) → `user_source/hdl_source/SD/spi_master.v`
- [spi_sniffer.v](../rtl/storage/spi_sniffer.v) → `user_source/hdl_source/SD/spi_sniffer.v`
- [sd_arbiter.v](../rtl/storage/sd_arbiter.v) → `user_source/hdl_source/sd_arbiter.v`
- [sector_byte_source.v](../rtl/storage/sector_byte_source.v) → `user_source/hdl_source/sector_byte_source.v`

## top

顶层时钟、跨域、SD仲裁和媒体/显示模式连线。

- [top_tf_hdmi_audio.v](../rtl/top/top_tf_hdmi_audio.v) → `user_source/hdl_source/top_tf_hdmi_audio.v`

## video

块流解码、像素重排、帧缓存、显示提交和音频样本主时钟。

- [av_sample_sync.v](../rtl/video/av_sample_sync.v) → `rtl/av_sample_sync.v`
- [video_codec8_block_decoder.v](../rtl/video/video_codec8_block_decoder.v) → `rtl/video_codec8_block_decoder.v`
- [video_codec8_raster.v](../rtl/video/video_codec8_raster.v) → `rtl/video_codec8_raster.v`
- [video_player.v](../rtl/video/video_player.v) → `rtl/video_player.v`


## FAT簇链与本轮优化接口

- `rtl/storage/fat32_sector_mapper.v`：owner0图片、1音频、2目录raw、3视频；虚拟文件扇区换算物理簇链，512字节缓存与三路游标，错误按owner返回。只读，无写卡。
- `rtl/storage/fat32_list.v`：FAT32挂载、根目录链、四图/八歌及首个VID/VAU；导出FAT起点/数据区/簇位移/最大簇/有效几何。
- `rtl/video/video_player.v`：`LEGACY_CODECS`默认1、当前顶层0；只接收Codec8/9/10的生产配置。扇区后继与文件末尾预计算，帧像素和音画预算规则保留。
- `rtl/image/img_scaler.v`：`BOUNDED_WIDTH`默认0，生产1依赖既有width<=4096头检查；坐标仍为最近邻floor映射。
- `rtl/image/qoi_stream.v`：`BRAM32_INDEX`默认0、生产1，切换索引表存储实现；接口和QOI token不变。
- `rtl/image/image_center_720p.v`：800×600图片放入1280×720，左右240、上下60像素留边；FIFO空/单项状态与指针差保持一致。

未新增软核或通用目录浏览器。各接口错误恢复、数据宽度、时钟与限制见FAT32_CHAIN.md、NATIVE720P.md和各模块注释。

`rtl/storage/sd_card_top.v`/`sd_card_sec_read_write.v`新增`PREFETCH_BRAM32`，默认0保留推断存储，当前顶层显式1使用两块BRAM32K保存8KiB预读缓存；命令/缓存同步读时序保持。图片读取器v56六状态使用显式独热编码，外部`state_code`与协议拍数保留，未重新开启曾导致工具崩溃的自动FSM推断。
