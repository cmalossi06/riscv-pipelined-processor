# Functional simulation with Icarus Verilog.
# Test programs are loaded with $readmemh, so the simulations run from programs/.
#   make single   single-cycle RV32I core
#   make pipeline 5-stage pipelined core, RV32I test program
#   make rv32m    5-stage pipelined core, RV32M test program
#   make all      run all three
#   make clean    remove generated files

BUILD = build

all: single pipeline rv32m

single: $(BUILD)/single.vvp
	cd programs && vvp -n ../$<

pipeline: $(BUILD)/pipeline.vvp
	cd programs && vvp -n ../$<

rv32m: $(BUILD)/rv32m.vvp
	cd programs && vvp -n ../$<

$(BUILD)/single.vvp: sim/tb_single_cycle.v rtl/riscv_single_cycle.v
	mkdir -p $(BUILD)
	iverilog -g2012 -o $@ $^

$(BUILD)/pipeline.vvp: sim/tb_pipeline.v rtl/riscv_pipeline.v
	mkdir -p $(BUILD)
	iverilog -g2012 -o $@ $^

$(BUILD)/rv32m.vvp: sim/tb_pipeline_rv32m.v rtl/riscv_pipeline.v
	mkdir -p $(BUILD)
	iverilog -g2012 -o $@ $^

clean:
	rm -rf $(BUILD) programs/*.vcd

.PHONY: all single pipeline rv32m clean
