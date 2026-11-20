# Dump every primitive cell of a synthesized checkpoint as "REF_NAME NAME",
# for cells.py. Usage: vivado -mode batch -source cells.tcl -tclargs <dcp> <out>
lassign $argv dcp out
open_checkpoint $dcp
set fp [open $out w]
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE}] {
    puts $fp "[get_property REF_NAME $c] $c"
}
close $fp
