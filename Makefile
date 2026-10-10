# Simulation with Icarus Verilog 12+.
#   make test         - build and run every testbench (fails on any FAIL/ERROR)
#   make run-<tb>     - run a single testbench, e.g. make run-tb_cache_axi4
#   make clean

TESTS ?= tb_cache_axi4
SRC   := $(wildcard rtl/*.sv)
BUILD := build

.PHONY: test clean

test: $(addprefix run-,$(TESTS))

run-%: $(BUILD)/%.vvp
	@echo "==> $*"
	@vvp -n $< | tee $(BUILD)/$*.log
	@! grep -qE "FAIL|ERROR:" $(BUILD)/$*.log
	@grep -qE "ALL PASS|: 0 error\(s\)" $(BUILD)/$*.log

$(BUILD)/%.vvp: $(SRC) tb/%.sv | $(BUILD)
	iverilog -g2012 -s $* -o $@ $(SRC) tb/$*.sv

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
