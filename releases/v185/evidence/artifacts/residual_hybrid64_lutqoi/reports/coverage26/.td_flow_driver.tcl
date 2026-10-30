# TD 6.2 can return exit code 0 after a sourced flow fails and drops to its
# interactive prompt. Catch the flow error and exit explicitly so callers
# receive the actual result. Read the path from the environment to preserve
# Windows separators, spaces, and non-ASCII names passed by the batch file.
if {![info exists ::env(TD_FLOW_SCRIPT)] || $::env(TD_FLOW_SCRIPT) eq ""} {
    puts stderr "TD_FLOW_FAILED: no flow script supplied"
    exit 2
}

set flow_script [string map {\\ /} $::env(TD_FLOW_SCRIPT)]
if {[catch {source $flow_script} flow_error flow_options]} {
    puts stderr "TD_FLOW_FAILED: $flow_error"
    if {[dict exists $flow_options -errorinfo]} {
        puts stderr [dict get $flow_options -errorinfo]
    }
    exit 1
}

puts "TD_FLOW_FINISHED"
exit 0
