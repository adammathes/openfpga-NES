# Cheat loader testbench runner.
#
# Usage:
#   make -C sim test     # build and run all tb_cheat_loader tests
#   make -C sim clean    # remove build artifacts

IVERILOG ?= iverilog
VVP      ?= vvp

RTL_DIR     := ../rtl

SOURCES := \
	tb_cheat_loader.sv \
	$(RTL_DIR)/cheat_loader.sv \
	$(RTL_DIR)/cheatcodes.sv

FILE_SOURCES := \
	tb_cheat_file.sv \
	$(RTL_DIR)/cheat_loader.sv \
	$(RTL_DIR)/cheatcodes.sv

.PHONY: test test-file clean

test: tb_cheat_loader.vvp
	@$(VVP) tb_cheat_loader.vvp

test-file: tb_cheat_file.vvp
	@$(VVP) tb_cheat_file.vvp

tb_cheat_loader.vvp: $(SOURCES)
	@$(IVERILOG) -g2012 -o $@ $(SOURCES)

tb_cheat_file.vvp: $(FILE_SOURCES)
	@$(IVERILOG) -g2012 -o $@ $(FILE_SOURCES)

clean:
	rm -f tb_cheat_loader.vvp tb_cheat_loader.vcd tb_cheat_file.vvp tb_cheat_file.vcd overflow.gg
