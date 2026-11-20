# Out-of-context synthesis of one heliodor top. Driven by run.sh, which sets
# the environment: SYN_TOP, SYN_GENERICS (space-separated NAME=VALUE),
# SYN_FILES (file list), SYN_PART, SYN_OUT, SYN_THREADS.
set top      $::env(SYN_TOP)
set generics $::env(SYN_GENERICS)
set part     $::env(SYN_PART)
set out      $::env(SYN_OUT)
set_param general.maxThreads $::env(SYN_THREADS)
# Keep every RAM-inference and pruning message (the default stops at 100).
set_param messaging.defaultLimit 1000000

set fp [open $::env(SYN_FILES) r]
set files [split [string trim [read $fp]] "\n"]
close $fp
read_verilog -sv $files

set gargs {}
foreach g $generics { lappend gargs -generic $g }

set t0 [clock seconds]
synth_design -top $top -part $part -mode out_of_context \
    -flatten_hierarchy rebuilt {*}$gargs
set t1 [clock seconds]
puts "SYN_TIME synth_design [expr {$t1 - $t0}] s"

report_utilization -file $out/util.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/util_hier.rpt
report_utilization -hierarchical -hierarchical_depth 12 -file $out/util_hier_full.rpt
report_ram_utilization -detail -file $out/ram.rpt
write_checkpoint -force $out/post_synth.dcp
puts "SYN_TIME total [expr {[clock seconds] - $t0}] s"
