# Build the ANTSDR U220 FPGA image (XC7A200T, AD9361 version).
#
#   vivado -mode batch -source build.tcl            # from this directory
#   vivado -mode batch -source build.tcl -tclargs xc7a200tfbg484-2
#
# Everything generated goes into ./build; the source tree is never written.

set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a200tfbg484-1"}]
set root [file normalize [file dirname [info script]]]
set out  $root/build
set jobs [expr {min(8, [exec nproc])}]

file delete -force $out/project
create_project antsdr_u220 $out/project -part $part
set_property target_language Verilog [current_project]

# The stock b200 core is built for the B210 feature set.
set_property verilog_define TARGET_B210=1 [current_fileset]

add_files [glob $root/top/*.v]
add_files [glob $root/lib/*/*.v $root/lib/*/*.vh $root/lib/*/*.ngc]
set_property file_type {Verilog Header} [get_files *.vh]

# import_ip copies the .xci into the project, so generated IP outputs stay in build/
foreach xci [glob $root/ip/*/*.xci] { import_ip $xci }
upgrade_ip [get_ips]
report_ip_status -file $out/ip_status.txt

add_files -fileset constrs_1 $root/xdc/u220.xdc
set_property top antsdr_u220 [current_fileset]
update_compile_order -fileset sources_1

set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

open_run impl_1
report_timing_summary -file $out/timing_summary.txt
report_utilization -file $out/utilization.txt

set status [get_property STATUS [get_runs impl_1]]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {![string match "*write_bitstream Complete*" $status]} {
    puts "BUILD FAILED: $status"
    exit 1
}
set impl [get_property DIRECTORY [get_runs impl_1]]
file copy -force $impl/antsdr_u220.bin $out/u220.bin
file copy -force $impl/antsdr_u220.bit $out/u220.bit
puts "BUILD OK: $out/u220.bin  part $part  WNS $wns ns"
if {$wns < 0} {
    puts "WARNING: timing not met"
    exit 2
}
