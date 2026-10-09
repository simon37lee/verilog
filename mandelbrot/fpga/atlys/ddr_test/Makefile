# ---------------------------------------------------------------------------
# DDR2 점검: MIG 3.92 예제 설계 (트래픽 생성기) 를 Atlys 에 올린다. mandelbrot 설계와 상관없이 DDR2 만 본다
#   LED7 = 보정 완료 (calib_done), LED6 = 오류 (쓴 값과 읽은 값이 다름)
#   정상이면 LED7 켜짐, LED6 꺼짐
#
#   source ~/Xilinx/14.7/ISE_DS/settings64.sh
#   make        빌드 -> build/example_top.bit
#   make prog
# ---------------------------------------------------------------------------
TOP   = example_top
PART  = xc6slx45-csg324-3
BUILD = build
RTL   = $(wildcard rtl/*.v) $(wildcard rtl/mcb_controller/*.v) $(wildcard rtl/traffic_gen/*.v)

all: $(BUILD)/$(TOP).bit

$(BUILD)/$(TOP).prj: $(RTL) Makefile
	mkdir -p $(BUILD)/xst/tmp
	rm -f $@; for f in $(RTL); do echo "verilog work \"../$$f\"" >> $@; done

$(BUILD)/$(TOP).xst: Makefile
	mkdir -p $(BUILD)
	printf '%s\n' 'set -tmpdir xst/tmp' 'set -xsthdpdir xst' 'run' \
	    '-ifn $(TOP).prj' '-ifmt mixed' '-ofn $(TOP)' '-ofmt NGC' '-p $(PART)' '-top $(TOP)' \
	    '-opt_mode Speed' '-opt_level 1' > $@

$(BUILD)/$(TOP).ngc: $(BUILD)/$(TOP).prj $(BUILD)/$(TOP).xst
	cd $(BUILD) && xst -ifn $(TOP).xst -ofn $(TOP).syr

$(BUILD)/$(TOP).ngd: $(BUILD)/$(TOP).ngc $(TOP).ucf
	cd $(BUILD) && ngdbuild -dd _ngo -uc ../$(TOP).ucf -p $(PART) $(TOP).ngc $(TOP).ngd

$(BUILD)/$(TOP)_map.ncd: $(BUILD)/$(TOP).ngd
	cd $(BUILD) && map -w -p $(PART) -ol high -o $(TOP)_map.ncd $(TOP).ngd $(TOP).pcf

$(BUILD)/$(TOP).ncd: $(BUILD)/$(TOP)_map.ncd
	cd $(BUILD) && par -w -ol high $(TOP)_map.ncd $(TOP).ncd $(TOP).pcf
	cd $(BUILD) && trce -v 20 $(TOP).ncd $(TOP).pcf -o $(TOP).twr

$(BUILD)/$(TOP).bit: $(BUILD)/$(TOP).ncd
	cd $(BUILD) && bitgen -w -g StartUpClk:JtagClk $(TOP).ncd $(TOP).bit

prog: $(BUILD)/$(TOP).bit
	env -u LD_LIBRARY_PATH djtgcfg prog -d Atlys -i 0 -f $(BUILD)/$(TOP).bit

clean:
	rm -rf $(BUILD)

.PHONY: all prog clean
