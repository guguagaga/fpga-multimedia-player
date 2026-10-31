# R3复现与签核

independent_signoff.json是独立生产SDC时序与源码绑定结果。新构建入口rebuild_r3.py从冻结v186 manifest还原工程，对4个候选RTL文件使用当前分支内容，其余源/依赖必须通过原hash；运行目录必须不存在。脚本面向当前机器D盘路径，不是通用发布安装器。

复现顺序：rebuild_r3.py（综合、布线、独立STA）→ test_r3_image_chain.py（vendor RAM模型整帧图像）→ signoff_candidate.py D:/codexworks/osd_carousel_v187/rebuild_r3（详细签核）。测试所需v186参考coverage来自前一R2的coverage_local.py生成，参考布线DB必须匹配v186发布哈希。全OSD回归在verification/osd_carousel_r2，R3未改变这些DUT，以osd_reuse.json绑定。tb_qoi_start.v补充延后一拍启动的取消/重启测试，ModelSim使用E:/modelsim/modelsim_ase/win32aloem。

任何重建都产生自己的DB和bit哈希，不得继承本版已签核标志。只读报告/DB签核不等同新位流已实板验收。
