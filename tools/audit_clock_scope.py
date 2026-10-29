"""Reject apparent passes caused by missing or changed clocks in final STA."""
import re
EXPECTED={'sd_card_clk':100.000,'video_clk':74.256,'ext_mem_clk':125.000,'audio_mclk':12.295,'hdmi_5x_clk':371.333,'clk':50.000,'u_audio_pll/pll_inst.clkc[0]':75.002,'sys_pll_m0/pll_inst.clkc[2]':125.000}
def audit_clock_scope(text, expected=None):
    expected = EXPECTED if expected is None else expected
    clocks={n:float(f) for f,n in re.findall(r'^\s*clk\d+:\s+([\d.]+)\s+\d+\s+(\S+)\s*$',text,re.M)}
    constraints=re.search(r'^Constraint File\s*:\s*(.*)$',text,re.M)
    coverage=re.search(r'STA coverage\s*:\s*([\d.]+)%',text)
    uncertainties=re.findall(r'Clock Uncertainty\s*:\s*([\d.]+)ns \(sdc uncertainty: ([\d.]+)ns, default uncertainty: ([\d.]+)ns\)',text)
    defaults_ok=bool(uncertainties)
    for block in re.split(r'(?=^Slack\s+:)',text,flags=re.M):
        u=re.search(r'Clock Uncertainty\s*:\s*([\d.]+)ns \(sdc uncertainty: ([\d.]+)ns, default uncertainty: ([\d.]+)ns\)',block)
        if not u:continue
        total,sdc,default=map(float,u.groups())
        begin=re.search(r'^Begin Point\s*:\s*(\S+)',block,re.M)
        end=re.search(r'^End Point\s*:\s*(\S+)',block,re.M)
        # TD reports zero jitter for a register's own feedback path (also in
        # the unmodified baseline); ordinary register paths retain0.100ns.
        self_feedback=bool(begin and end and begin[1].rsplit('.',1)[0]==end[1].rsplit('.',1)[0])
        defaults_ok &= total==default and (default==0.1 or (default==0 and self_feedback))
    checks={'clock_set_matches':clocks.keys()==expected.keys(),'clock_frequencies_match':all(n in clocks and abs(clocks[n]-f)<.002 for n,f in expected.items()),'constraint_file_present':bool(constraints and 'timing.sdc' in constraints[1]),'coverage_not_reduced':bool(coverage and float(coverage[1])>=96.3),'final_sdc_uncertainty_zero':bool(uncertainties) and all(float(sdc)==0 for total,sdc,default in uncertainties),'default_uncertainty_retained':defaults_ok}
    return {'passed':all(checks.values()),'checks':checks,'clocks_mhz':clocks}
