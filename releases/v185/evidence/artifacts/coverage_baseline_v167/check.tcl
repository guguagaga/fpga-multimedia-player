import_device eagle_s20.db -package EG4S20BG256
open_project HDMI1.4b_Transmitter_v1.0.prj -noanalyze
import_db {D:/codexworks/block_redesign_20261028/v167/candidate/project/td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_cjk_align_seed18/HDMI1.4b_Transmitter_v1.0_pr.db}
clear_sdc -user
read_sdc {D:/codexworks/block_redesign_20261028/v167/candidate/project/user_source/constraints_source/timing.sdc}
update_timing -mode final
check_timing -verbose -file coverage.txt
report_clock_summary -file clocks.txt
report_timing_summary -file timing.txt
report_timing_ignored -ep_num 10000 -path_num 1 -file ignored.txt
