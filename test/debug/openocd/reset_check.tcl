# Reset paths through OpenOCD (run by test/debug/run_ocd.sh after
# heliodor-1.cfg or heliodor-4.cfg): OpenOCD's own `reset halt` and
# `reset run` (ndmreset with haltreq held), then, by DMI writes, hartreset with
# its dmcontrol readback, and resethaltreq with hartreset and with ndmreset.
# Each check prints "ok <name>" or "FAIL <name>"; the last line is
# "RESET_CHECK PASS" or "RESET_CHECK FAIL". DMI bits are Debug Spec 1.0.

poll off
set fail 0
set loop 0x80000000

proc check {name cond} {
    if {[uplevel 1 [list expr $cond]]} {
        echo "ok $name"
    } else {
        echo "FAIL $name"
        set ::fail 1
    }
}
proc dmstatus {} { return [riscv dmi_read 0x11] }
proc dmcontrol {v} { riscv dmi_write 0x10 [expr {$v | 1}] }
proc wait_status {mask val} {
    for {set i 0} {$i < 600} {incr i} {
        if {([dmstatus] & $mask) == $val} { return 1 }
        sleep 20
    }
    return 0
}
proc reg_val {name} {
    regexp {0x[0-9a-f]+} [reg $name force] v
    return $v
}
proc dcsr_cause {} { return [expr {([reg_val dcsr] >> 6) & 7}] }
# Background polling is off, so let OpenOCD see the hart's state before
# halting it.
proc sync_halt {} {
    [target current] arp_poll
    halt
}
# Leaves the selected hart running a jump-to-self in DRAM.
proc run_loop {} {
    sync_halt
    mww $::loop 0x0000006f
    resume $::loop
    sleep 50
}

set halted  [expr {1 << 9}]
set running [expr {1 << 11}]
set haverst [expr {1 << 19}]
set hartrst [expr {1 << 29}]
set ackhr   [expr {1 << 28}]
set ndm     [expr {1 << 1}]
set setrhr  [expr {1 << 3}]
set clrrhr  [expr {1 << 2}]

foreach t [target names] {
    targets $t
    echo "== $t"
    set hs [expr {[$t cget -coreid] << 16}]

    # OpenOCD's reset halt: ndmreset with haltreq held, the hart stops before
    # its first instruction.
    run_loop
    reset halt
    check "$t reset_halt.pc" {[reg_val pc] == 0}
    check "$t reset_halt.cause" {[dcsr_cause] == 3}

    # OpenOCD's reset run: the hart leaves reset running.
    run_loop
    reset run
    sleep 50
    check "$t reset_run.running" {([dmstatus] & $running) != 0}
    sync_halt
    check "$t reset_run.pc" {[reg_val pc] == 0}

    # hartreset: reads back as 1 while held; the hart restarts at the reset
    # vector, running, with havereset until acknowledged.
    run_loop
    dmcontrol [expr {$hs | $hartrst}]
    check "$t hartreset.readback1" {([riscv dmi_read 0x10] & $hartrst) != 0}
    check "$t hartreset.havereset" {[wait_status $haverst $haverst]}
    dmcontrol $hs
    check "$t hartreset.readback0" {([riscv dmi_read 0x10] & $hartrst) == 0}
    check "$t hartreset.running" {[wait_status $running $running]}
    dmcontrol [expr {$hs | $ackhr}]
    check "$t hartreset.ack" {([dmstatus] & $haverst) == 0}
    sync_halt
    check "$t hartreset.pc" {[reg_val pc] == 0}

    # resethaltreq with hartreset: the hart halts before its first
    # instruction.
    run_loop
    dmcontrol [expr {$hs | $setrhr}]
    dmcontrol [expr {$hs | $hartrst}]
    dmcontrol $hs
    check "$t resethaltreq_hart.halted" {[wait_status $halted $halted]}
    dmcontrol [expr {$hs | $ackhr | $clrrhr}]
    sync_halt
    check "$t resethaltreq_hart.pc" {[reg_val pc] == 0}
    check "$t resethaltreq_hart.cause" {[dcsr_cause] == 3}

    # resethaltreq with ndmreset.
    run_loop
    dmcontrol [expr {$hs | $setrhr}]
    dmcontrol [expr {$hs | $ndm}]
    dmcontrol $hs
    check "$t resethaltreq_ndm.halted" {[wait_status $halted $halted]}
    dmcontrol [expr {$hs | $ackhr | $clrrhr}]
    sync_halt
    check "$t resethaltreq_ndm.pc" {[reg_val pc] == 0}

    # clrresethaltreq took: the next ndmreset leaves the hart running.
    dmcontrol [expr {$hs | $ndm}]
    dmcontrol $hs
    check "$t resethaltreq_clr.running" {[wait_status $running $running]}
    dmcontrol [expr {$hs | $ackhr}]
    sync_halt
}

if {$fail} {
    echo "RESET_CHECK FAIL"
} else {
    echo "RESET_CHECK PASS"
}
shutdown
