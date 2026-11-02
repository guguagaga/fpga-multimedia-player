onerror {quit -code 1}
vlib work
vlog {D:/codexworks/image_iterator_v195_20261101/build_shared_onehot/candidate/project/user_source/hdl_source/qoi_stream.v} {D:/TD3/sim_release/eg4/eg_logic_dram.v}
vlog -sv {D:/codexworks/image_iterator_v195_20261101/tests/onehot_full_chain/bmp/tb.v} {D:/codexworks/image_iterator_v195_20261101/build_shared_onehot/candidate/project/user_source/hdl_source/SD/sd_card_bmp.v} {D:/codexworks/image_iterator_v195_20261101/build_shared_onehot/candidate/project/user_source/hdl_source/SD/bmp_read.v} {D:/codexworks/image_iterator_v195_20261101/build_shared_onehot/candidate/project/rtl/img_scaler.v} {D:/TD3/sim_release/eg4/eg_phy_bram32k.v} {D:/TD3/sim_release/eg4/eg_phy_glbl.v}
vlog {D:/codexworks/image_iterator_v195_20261101/build_shared_onehot/candidate/project/user_source/hdl_source/sd_arbiter.v}
vlog {D:/codexworks/image_iterator_v195_20261101/build_shared_onehot/candidate/project/rtl/fat32_list.v}
vsim -gEARLY=1 work.tb work.glbl +W=320 +H=240 +KIND=0
run -all
quit -code 0
