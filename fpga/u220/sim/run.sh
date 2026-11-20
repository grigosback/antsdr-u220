#!/usr/bin/env bash
# Simulate u220_core with Vivado xsim. Output goes to fpga/build/sim.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fpga=$(cd "$here/../.." && pwd)
out=$fpga/build/sim
mkdir -p "$out" && cd "$out"

xvlog --nolog -i "$fpga/lib/control" \
    "$fpga"/lib/fifo/axi_fifo*.v "$fpga"/lib/control/ram_2port.v \
    "$fpga"/u220/u220_ctrl.v "$fpga"/u220/u220_stream.v "$fpga"/u220/u220_spi.v "$fpga"/u220/u220_core.v > "$out/compile.log" 2>&1 || { grep -E "ERROR" "$out/compile.log"; exit 1; }
xvlog --nolog -sv "$here/tb_u220_core.sv" > "$out/compile.log" 2>&1 || { grep -E "ERROR" "$out/compile.log"; exit 1; }
xelab --nolog -debug off tb_u220_core -s tb > "$out/compile.log" 2>&1 || { grep -E "ERROR" "$out/compile.log"; exit 1; }
xsim --nolog tb -R | tee "$out/sim.log" | grep -E "PASS|FAIL"
