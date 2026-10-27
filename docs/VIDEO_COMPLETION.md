> 历史设计/实验记录；本次冻结状态、720p60参数及已知问题以 [当前版本](RELEASE_V114.md) 和 release_status.json 为准。

# 720P视频与FAT32交付记录

更新时间2026-10-27T16:34，源码`fat_chain_v56`，状态`EXPERIMENTAL_TIMING_NOT_CLOSED`。本版尚未实板验收，当前没有通过最终时序门槛的推荐720P bit。

## 实现与全片文件

原生1280×720、标称15fps，HDMI有效区1280×720、约30Hz。RGB565两像素组成32位显存字，三帧共5,529,600字节。不是把800×600简单放大。

全片6330帧/422秒，985,099,264字节；活动SD视频`M1_C10.VID`先前以正常文件复制得到单段连续分配，并通过SHA256核对：`e002cb2449090a99f444781b03f4adb6948c37fa2d0a6d73fe6939990cc9e7b8`。本阶段没有再次改卡或替换音轨。旧800×600 bit不能播放这份720P文件。

只读FAT32 mapper支持非连续簇：共享SD仲裁、每路游标、FAT缓存、CMD18不跨簇预读。SPC1..128逻辑均测试；小簇、极端碎片及真实卡延迟仍影响吞吐。并不要求用户今后每次复制都拿到连续文件，但该能力尚待当前源码时序和板测验收。

## 格式与资源

`video_player.LEGACY_CODECS`默认1保留Codec1/2/5/6/7；720P顶层设0仅接收Codec8/9/10，错误头拒绝、损坏/短块补黑。图片、音频、频谱保留。

| 综合快照 | LUT | FF | BRAM9K | BRAM32K | DSP |
| --- | ---: | ---: | ---: | ---: | ---: |
| fat_chain_v35 | 18236/19600 | 11930/19600 | 63/64 | 9/16 | 24/29 |
| fat_chain_v37 | 17857/19600 | 11851/19600 | 63/64 | 9/16 | 24/29 |
| fat_chain_v43 | 17949/19600 | 11954/19600 | 63/64 | 9/16 | 24/29 |
| fat_chain_v44 | 17952/19600 | 11954/19600 | 61/64 | 10/16 | 24/29 |
| fat_chain_v56 | 17774/19600 | 12018/19600 | 53/64 | 12/16 | 24/29 |

QOI索引存储从BRAM9K重分配到BRAM32K，BRAM9K从63降到61。尺寸源先选择再乘是源码结构调整，综合DSP总量仍为24；没有实测减少DSP。后续使能与图片头流水的目的和最终时序见[TIMING_OPTIMIZATION.md](TIMING_OPTIMIZATION.md)。

## 吞吐证据与同步边界

全片最大单帧164,351字节、平均155,623.81字节，视频payload平均2,334,357.16字节/秒。连续码量最大的三帧是零起点4003..4005，164,102/163,648/164,159字节。

96KB/s合成PCM音轨读流量下，后两帧完成间隔69.765/70.252ms，超出15fps的66.667ms预算；测试没有人为暂停。改为24.1KB/s合成IMA流量后为65.220/65.707ms。这两个数字来自固定流量模型，不含真实IMA解码器。

九帧合成音频流量循环已PASS：8,294,400视频像素、9次显示发布、28,800采样预算。真实IMA联合测试另行记录：

来源`fat_chain_v52/reports/actual_ima_video.json`，结果PASS；范围：3 native720 frames=heaviest triplet repeated1x; actual compressed_audio_reader/IMA decoder,2048-byte FIFO high watermark,48kHz PCM consumed under AV budget, every PCM sample compared with C reference; shared25MHz-byte SD/CMD18/FAT/video writer and pixel checks. Audio32 real blocks near266.86s, fragmented independently. Not I2S/physical card/long or full-film board playback.。记录的工程源与当前快照全部一致。

真实IMA模型包含压缩音轨读取器、IMA解码、FIFO高水位、48kHz消费和视频共享FAT/SD/CMD18/仲裁。每个PCM采样与独立C参考比较，每个视频像素与软件参考比较，等待全部显示与采样预算结束后才PASS。它仍不含真实I2S、SDRAM芯片、显示器或物理SD时延分布。

显示发布按30Hz刷新且受实际帧就绪限制，不能仅凭某两个解码完成间隔小于66.667ms就宣称全片锁定15fps或无音画误差。音频预算机制能在视频卡顿时限制音频继续提前，但不补回已经丢失的播放时间。当前仍须实板检查全片同步和流畅性。

## 音轨候选及后续门槛

可选IMA音轨由已下载ADPCM-XQ0.5、前瞻5、1024字节块生成，48kHz单声道，有效20,256,000采样恰好422秒，10,163,260字节，约24,083.55字节/秒。全长Python解码与C解码逐块一致，抽取32块/64,387采样通过RTL；有损SNR32.88dB，需试听。未写入卡上。

最终门槛：源码对应的完整布线setup/hold零违例；再检查F156P1锁定720p30、422秒全片与循环、碎片跨簇、连续播放/暂停/退出/重进和多次切图切歌。详细来源、源码哈希、模型范围和失败时序如实保留在[VALIDATION.md](VALIDATION.md)及`release_status.json`。资料日期见[REFERENCES.md](REFERENCES.md)。
