# Build an ANTSDR U220 FPGA image (XC7A200T, AD9361 version).
#
#   vivado -mode batch -source build.tcl -tclargs <target> [part]
#
#   target  u220        own minimal design (u220/)            -> build/u220/u220.bin
#           b210compat  MicroPhase's B210-compatible design   -> build/b210compat/b210compat.bin
#   part    default xc7a200tfbg484-1
#
# Everything generated goes into build/<target>; the source tree is never written.

set target [expr {[llength $argv] > 0 ? [lindex $argv 0] : "u220"}]
set part   [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xc7a200tfbg484-1"}]
set root   [file normalize [file dirname [info script]]]
set src    $root/$target
set out    $root/build/$target
set jobs   [expr {min(8, [exec nproc])}]

switch $target {
    u220       { set top u220_top }
    b210compat { set top antsdr_u220 }
    default    { puts "unknown target '$target'"; exit 1 }
}

file delete -force $out/project
create_project $target $out/project -part $part
set_property target_language Verilog [current_project]

if {$target eq "b210compat"} {
    # the stock b200 core is built for the B210 feature set
    set_property verilog_define TARGET_B210=1 [current_fileset]
}

add_files [glob $src/*.v]
add_files [glob $root/lib/*/*.v $root/lib/*/*.vh $root/lib/*/*.ngc]
set_property file_type {Verilog Header} [get_files *.vh]

# import_ip copies the .xci into the project, so generated IP outputs stay in build/
set fh [open $src/ip.txt]
foreach ip [split [string trim [read $fh]] "\n"] { import_ip $root/ip/$ip/$ip.xci }
close $fh
upgrade_ip [get_ips]
report_ip_status -file $out/ip_status.txt

add_files -fileset constrs_1 [glob $src/*.xdc]
set_property top $top [current_fileset]
update_compile_order -fileset sources_1

set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

set status [get_property STATUS [get_runs impl_1]]
if {![string match "*write_bitstream Complete*" $status]} {
    puts "BUILD FAILED: $status"
    exit 1
}
open_run impl_1
report_timing_summary -file $out/timing_summary.txt
report_utilization -file $out/utilization.txt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]

set impl [get_property DIRECTORY [get_runs impl_1]]
file copy -force $impl/$top.bin $out/$target.bin
file copy -force $impl/$top.bit $out/$target.bit
puts "BUILD OK: $out/$target.bin  part $part  WNS $wns ns"
if {$wns < 0} {
    puts "WARNING: timing not met"
    exit 2
}
