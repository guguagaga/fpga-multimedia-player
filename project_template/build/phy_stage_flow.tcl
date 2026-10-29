# This is default flow script for normal condition: neither syn ip flow nor multi-seed mode.
# Noted that only script in editable zone can be changed. 

if { ![info exists alRun] } { source ./settings.cfg }
proc step_begin { step } {
  set stopFile ".stop.f"
  if {[file isfile .stop.f]} {
    puts ""
    puts " #Halting run"
    puts ""
    return -code error
  }
  set beginFile ".$step.begin.f"
  set platform "$::tcl_platform(platform)"
  set user "$::tcl_platform(user)"
  set pid [pid]
  set host ""
  if { [string equal $platform unix] } {
    if { [info exists ::env(HOSTNAME)] } {
      set host $::env(HOSTNAME)
    }
  } else {
    if { [info exists ::env(COMPUTERNAME)] } {
      set host $::env(COMPUTERNAME)
    }
  }
  set ch [open $beginFile w]
  puts $ch "<?xml version=\"1.0\"?>"
  puts $ch "<ProcessHandle Version=\"1\" Minor=\"0\">"
  puts $ch "    <Process Ownner=\"$user\" Host=\"$host\" Pid=\"$pid\">"
  puts $ch "    </Process>"
  puts $ch "</ProcessHandle>"
  close $ch
}
proc step_end { step } {
  set endFile ".$step.end.f"
  set ch [open $endFile w]
  close $ch
}
proc step_error { step } {
  set errorFile ".$step.error.f"
  set ch [open $errorFile w]
  close $ch
}
set stepList {read_design opt_rtl opt_gate opt_place opt_route bitgen}
set l [lsearch $stepList $start_step]
set r [lsearch $stepList $end_step]
proc prepare { step } {
  upvar device_name device_name
  upvar package_name package_name
  upvar speed speed
  upvar prj_name prj_name
  upvar parent parent
  upvar synWildParams synWildParams
  upvar phyWildParams phyWildParams
  upvar alRun alRun
  upvar singleRun singleRun
  upvar sp sp
  upvar ADCList ADCList
  upvar SDCList SDCList
  set command "import_device $device_name -package $package_name"; if { [info exists speed] } { append command " -speed ${speed}" }; eval $command
  if { ![info exists singleRun] } {
    if { [info exists alRun] } { 
        open_project ${prj_name}.al -single_run
        load_run_param -run ${alRun}
    } else {
    set command "open_project {${prj_name}.prj}"; if { $step != 0 } { append command " -noanalyze" }; eval $command
    }
  }
  set preSteps {non elaborate rtl gate place pr}
  set preStep [ lindex ${preSteps} $step ]
  if { $step == 3 } { import_db $parent/${prj_name}_${preStep}.db }\
  elseif { $step != 0 } { import_db ${prj_name}_${preStep}.db }
  set wildParams ""
  if { [info exists synWildParams] } { set wildParams ${synWildParams} } elseif { [info exists phyWildParams] } { set wildParams ${phyWildParams} }
  for { set i 0 } { $i < [llength $wildParams] } { incr i 3 } {
    set_param [lindex $wildParams $i] [lindex $wildParams [expr $i + 1]] [lindex $wildParams [expr $i + 2]]
  }
  if { [info exists singleRun] } report_param
  if { [info exists sp] } {
    if { [info exists ADCList] } { foreach adc $ADCList { read_adc $adc } }
    if { [info exists SDCList] } {
      clear_sdc -user
      foreach sdc $SDCList { read_sdc $sdc }
    }
  }
}
proc read_design_fun {} {
  upvar prj_name prj_name
  upvar top_model_name top_model_name
  upvar singleRun singleRun
  upvar ADCList ADCList
  upvar IpADCList IpADCList
  upvar SDCList SDCList
  upvar IpSDCList IpSDCList
  if { ![info exists singleRun] } { commit_param -step design }

### Editable zone for read_design ###
  elaborate -top $top_model_name
#####################################
  if { [info exists ADCList] } { foreach adc $ADCList { read_adc $adc } }
  if { [info exists IpADCList] } {
    set i 0
    while {$i < [llength $IpADCList]} {
      read_ip_adc -ip [lindex $IpADCList $i] -file [lindex $IpADCList [expr $i + 1] ]
      incr i 2
    }
  }
  if { [info exists SDCList] } { foreach sdc $SDCList { read_sdc $sdc } }
  if { [info exists IpSDCList] } {
    set i 0
    while {$i < [llength $IpSDCList]} {
      read_sdc -ip [lindex $IpSDCList $i] [lindex $IpSDCList [expr $i + 1] ]
      incr i 2
    }
  }
  export_db ${prj_name}_elaborate.db
}
proc opt_rtl_fun {} {
  upvar prj_name prj_name
  upvar singleRun singleRun
  if { ![info exists singleRun] } { commit_param -step rtl }


### Editable zone for opt_rtl ###
  upvar chipDebugger chipDebugger
  if { ![info exists chipDebugger] } {
     insert_debugger
  } else { insert_debugger $chipDebugger }
  optimize_rtl
  report_area -file ${prj_name}_rtl.area
#################################

  export_db ${prj_name}_rtl.db
}
proc opt_gate_fun {} {
  upvar prj_name prj_name
  upvar area_option area_option
  upvar singleRun singleRun
  if { ![info exists singleRun] } { commit_param -step gate }

### Editable zone for opt_gate ###
  optimize_gate ${area_option} ${prj_name}_gate.area
  legalize_phy_inst
  update_timing
  report_timing_status -file ${prj_name}_gate.ts
  report_timing_summary -file ${prj_name}_gate.timing
  flow_status -file flow.status
##################################

  export_db ${prj_name}_gate.db
}
proc opt_place_fun {} {
  upvar prj_name prj_name
  upvar cwcList cwcList
  upvar singleRun singleRun
  upvar chipDebugger chipDebugger
  upvar bkaADCList bkaADCList
  upvar arr_filter arr_filter
  upvar arr_pwns arr_pwns
  upvar arr_cong arr_cong
  if { ![info exists singleRun] } { commit_param -step place }
  if { ![info exists chipDebugger] } {
     insert_debugger
  } else { insert_debugger $chipDebugger }
  if { [info exists bkaADCList] } { 
     clear_inst_adc
     foreach adc $bkaADCList { read_adc $adc } 
  }

### Editable zone for opt_place ###
  # TD interprets clock objects correctly through its SDC parser.
  # This separate file tightens optimization, not the signoff requirement.
  upvar SDCList SDCList
  clear_sdc -user
  foreach sdc $SDCList { read_sdc $sdc }
  read_sdc ../../../build/optimization_margin.sdc

  # [CHG 2026-10-11 routefix] 拥塞对策：移植 10-09 18:16 成功构建的参数（逐字来自
  # D:/fpga_work/build_run2_ok.log）。fix13 网表在 (x26y58_local4) 出现确定性
  # route 违例 PHY-8023 / RUN-8102（裸 place/route 全量重跑两次均在同一坐标复现）。
  set_param place effort high
  # 【2026-10-19】hfn_opt_effort low 会让靠近饱和的设计在频谱区域出现
  #   **确定性**布线违例 PHY-8023 / RUN-8102（enable_seed=off ⇒ 重跑无效）。
  #   队员的交付包（fpga_fixed_scroll_delivery_20261017）里也是靠移除这一行
  #   突破同类型违例。这里注释掉，改用布局器默认的 hfn 策略。
  #set_param place hfn_opt_effort low   ;# 也不能用 high：实测 high -3435 / low 布线失败 / 不设 -2420
  # ================================================================
  # 【2026-10-20 C1 实验】打开 TD 官方 "TimingHigh" 策略的物理优化参数。
  #   依据 D:/TD3/doc/strategies/official_strategy_ph2.json 里的 TimingHigh：
  #   "Applies more features such as shifter opt and SWNS focus timing fix to
  #    achive better placement timing and enable extra post-route optimization
  #    for timing closure."
  #   本设计 76% 面积占用下最差路径 77% 的延迟是 net（cell 只有 2.4~3.5 ns），
  #   这类"物理优化"参数对症；此前只设了 place effort high，其余全为默认。
  #   ⚠ 有意**不**采用 TimingUltra 的 hfn_opt_effort high：实测更差(-3435)。
  #   回退：删掉下面这批 set_param（备份见 phy_stage_flow.tcl.bak_before_timinghigh_20261020）。
  # ================================================================
  set_param place opt_timing high
  set_param place logic_level_opt on
  set_param place crit_path_opt on
  set_param place timing_driven_mode on
  set_param place aggressive_opt 20
  set_param place aggr_neighbor_dist 5
  set_param place enhanced_beeline_opt 3
  # TD official CongestionHigh strategy, for the 99%-packed FAT candidate.
  # v133: use default ofv; retain other timing/routing settings.
  # v133: use default opt_max_density; retain other timing/routing settings.
  # v133: use default target_density; retain other timing/routing settings.
  # v133: use default target_density_pp; retain other timing/routing settings.
  set_param place dram_area_factor 12
  set_param place enhanced_gp on
  set_param place macro_performance macro_congestion
  set_param place non_crit_opt on
  set_param place post_place_opt high
  set_param place split_data_from_clock on
  set_param place shifter_opt on
  # 【2026-10-20 G1 实验结论：无效，已撤】试过 place enhanced_gp on +
  #   route postrt_opt_extra_round 8，route.qor 与 F1 逐位相同（-94 / 25 端点 / 74.82%）。
  #   说明 physical-opt 这些参数在本设计上已经饱和，最后 ~100 ps 只能靠 RTL。
  #   若将来想再试：把下面两行取消注释即可。
  #set_param place enhanced_gp on
  #set_param route postrt_opt_extra_round 8
  place
  update_timing -mode manhattan
  report_timing_summary -file ${prj_name}_place.timing
  report_area -io_info -file ${prj_name}_phy.area
  flow_status -file place_flow.status
  report_clock_utilization -file place_clock_utilization.txt
  if { [string equal $arr_filter true] } { flow_continue_check -step place -wns $arr_pwns -congestion $arr_cong }
###################################

  export_db ${prj_name}_place.db
}
proc opt_route_fun {} {
  upvar prj_name prj_name
  upvar singleRun singleRun
  upvar arr_filter arr_filter
  upvar arr_rwns arr_rwns
  upvar drHoldFix drHoldFix
  if { ![info exists singleRun] } { commit_param -step route }

### Editable zone for opt_route ###
  # [CHG 2026-10-11 routefix] 同上（route effort high，来自 18:16 成功构建日志）
  set_param route effort routability
  # 【2026-10-20 C1 实验】同上，取自官方 TimingHigh / TimingUltra 的 route 侧：
  #   post_route_opt high        —— 布线后的物理优化（插缓冲/复制驱动/换单元）
  #   postrt_opt_extra_round 4   —— 多跑 4 轮，压 SWNS
  #   这是本设计从没跑过的一步；最差路径 77% 的延迟是 net，正需要它。
  set_param route post_route_opt high
  set_param route postrt_opt_extra_round 4
  # 2026-10-14 EXPERIMENT A: this block has NEVER RUN in any build of this
  # design, because `arr_filter` is `false` in every settings_phy_1.cfg that
  # exists (and this code tests for the string "on").  Consequence: the
  # router always routes with fix_hold at its default and no post-route hold
  # repair pass, which is why the routed hold WNS has stayed at -20 ps.
  #
  # Gated on drHoldFix alone now, so it runs with the existing
  # `set drHoldFix on` and does not depend on arr_filter.  The two
  # flow_continue_check calls are dropped because arr_pwns / arr_rwns /
  # arr_cong are only defined when a caller supplies them, and their effect
  # is to abort the flow on a failing check - not wanted here.
  # Revert: restore the two `arr_filter`-gated blocks.
  if { [string equal $drHoldFix on] } {
    set_param route fix_hold off
    set_param flow qor_monitor off
  }
  route
  if { [string equal $drHoldFix on] } {
    fix_hold
    set_param route fix_hold on
    set_param flow qor_monitor on
    # Final QoR follows restoration of the production SDC.
  }
  report_area -io_info -file ${prj_name}_phy.area
  # Remove optimization-only constraints before final reports, DB and bit.
  upvar SDCList SDCList
  clear_sdc -user
  foreach sdc $SDCList { read_sdc $sdc }
  update_timing -mode final
  report_qor -step route -file route.qor
  report_timing_status -file ${prj_name}_phy.ts
  report_timing_summary -file ${prj_name}_pr.timing
  report_timing_exception -file ${prj_name}_exception.timing
  flow_status -file route_flow.status
  report_clock_utilization -file route_clock_utilization.txt
###################################

  export_db ${prj_name}_pr.db
}
proc bitgen_fun {} {
  upvar prj_name prj_name
  upvar cpcList cpcList
  upvar singleRun singleRun
  if { ![info exists singleRun] } { commit_param -step bitgen }
  if { [info exists cpcList] } {
    import_chipprobe_config $cpcList
    compile_probe
  }

### Editable zone for bitgen ###
  bitgen -bit $prj_name.bit
################################
  upvar chipDebugger chipDebugger
  if { ![info exists chipDebugger] } {
    setup_debugger
  } else { setup_debugger $chipDebugger }
  export_bitgen_param -file .bitgen_param.f 
}
foreach s [lrange $stepList $l $r] {
  step_begin $s
  set ACTIVESTEP $s
  set rc [catch {
    if { [string equal $s $start_step] } { prepare $l }
    ${s}_fun
  } RESULT]
  if { $rc } {
    step_error $s
    return -code error $RESULT
  } else {
    step_end $s
    unset ACTIVESTEP
  }
}
export_flow_status -s $start_step -e $end_step
