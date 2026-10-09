# ---------------------------------------------------------------------------
# Digilent Atlys (Spartan-6 XC6SLX45-CSG324-3) 빌드 - Xilinx ISE 14.7 명령행 흐름
#
#   source ~/Xilinx/14.7/ISE_DS/settings64.sh   # 먼저 ISE 환경 설정
#   make            V=1 (기본) 빌드 -> build/v1/matrix_atlys.bit
#   make V=2        rtl/common + rtl/v2 로 빌드 -> build/v2/matrix_atlys.bit
#   make V=2 prog   Digilent Adept 2 (djtgcfg) 로 보드에 다운로드 (전원 끄면 사라짐)
#   make V=2 timing 타이밍 요약 / make V=2 util 자원 사용량
#   make clean      모든 버전 빌드 삭제
# ---------------------------------------------------------------------------
TOP   = matrix_atlys
PART  = xc6slx45-csg324-3
V    ?= 1

RTL_DIR = ../../rtl
BUILD   = build/v$(V)
# 버전 폴더에 공통 파일과 같은 이름이 있으면 그것으로 바꾼다
VER_RTL = $(wildcard $(RTL_DIR)/v$(V)/*.v)
RTL     = $(filter-out $(addprefix $(RTL_DIR)/common/,$(notdir $(VER_RTL))),$(wildcard $(RTL_DIR)/common/*.v)) \
          $(VER_RTL) $(TOP).v

all: $(BUILD)/$(TOP).bit

$(BUILD)/$(TOP).prj: $(RTL) Makefile
	mkdir -p $(BUILD)/xst/tmp
	rm -f $@; for f in $(RTL); do echo "verilog work \"../../$$f\"" >> $@; done

$(BUILD)/$(TOP).xst: Makefile
	mkdir -p $(BUILD)
	printf '%s\n' \
	    'set -tmpdir xst/tmp' 'set -xsthdpdir xst' 'run' \
	    '-ifn $(TOP).prj' '-ifmt mixed' '-ofn $(TOP)' '-ofmt NGC' '-p $(PART)' '-top $(TOP)' \
	    '-opt_mode Speed' '-opt_level 1' '-keep_hierarchy No' > $@

$(BUILD)/$(TOP).ngc: $(BUILD)/$(TOP).prj $(BUILD)/$(TOP).xst
	cd $(BUILD) && xst -ifn $(TOP).xst -ofn $(TOP).syr

$(BUILD)/$(TOP).ngd: $(BUILD)/$(TOP).ngc atlys.ucf
	cd $(BUILD) && ngdbuild -dd _ngo -uc ../../atlys.ucf -p $(PART) $(TOP).ngc $(TOP).ngd

$(BUILD)/$(TOP)_map.ncd: $(BUILD)/$(TOP).ngd
	cd $(BUILD) && map -w -p $(PART) -ol high -o $(TOP)_map.ncd $(TOP).ngd $(TOP).pcf

$(BUILD)/$(TOP).ncd: $(BUILD)/$(TOP)_map.ncd
	cd $(BUILD) && par -w -ol high $(TOP)_map.ncd $(TOP).ncd $(TOP).pcf
	cd $(BUILD) && trce -v 200 -fastpaths $(TOP).ncd $(TOP).pcf -o $(TOP).twr

$(BUILD)/$(TOP).bit: $(BUILD)/$(TOP).ncd
	cd $(BUILD) && bitgen -w -g StartUpClk:JtagClk $(TOP).ncd $(TOP).bit

timing: $(BUILD)/$(TOP).ncd
	grep -A12 "^Timing summary" $(BUILD)/$(TOP).twr
	grep -A30 "Derived Constraint Report" $(BUILD)/$(TOP).twr | head -40

util: $(BUILD)/$(TOP).ncd
	grep -E "Number of (Slice Registers|Slice LUTs|occupied Slices|RAMB16BWERs|RAMB8BWERs|DSP48A1s):" $(BUILD)/$(TOP)_map.mrp

prog: $(BUILD)/$(TOP).bit
	@# ISE settings64.sh 가 넣는 옛 libstdc++ 를 Adept 가 잡지 않도록 LD_LIBRARY_PATH 를 비운다
	env -u LD_LIBRARY_PATH djtgcfg prog -d Atlys -i 0 -f $(BUILD)/$(TOP).bit

clean:
	rm -rf build

.PHONY: all timing util prog clean
