# ---------------------------------------------------------------------------
# Digilent Atlys (Spartan-6 XC6SLX45-CSG324-3) 빌드 - Xilinx ISE 14.7 명령행 흐름
#
#   source ~/Xilinx/14.7/ISE_DS/settings64.sh   # 먼저 ISE 환경 설정
#   make            V=1 (기본) 빌드 -> build/v1/mandel_atlys.bit
#   make V=2        rtl/common + rtl/v2 로 빌드 -> build/v2/mandel_atlys.bit
#   make V=2 prog   Digilent Adept 2 (djtgcfg) 로 보드에 다운로드 (전원 끄면 사라짐)
#   make V=2 timing 타이밍 요약 / make V=2 util 자원 사용량
#   make clean      모든 버전 빌드 삭제
#
#   버전별 설정 (CORE_DIV, W, IW) 은 rtl/vN/config.mk. XST -generics 로 최상위 파라미터에 넘긴다.
#   DEFS 는 Verilog `define 목록 (XST -define): make V=2 DEFS=SLOTS=1  -> build/v2_SLOTS1/
# ---------------------------------------------------------------------------
TOP   = mandel_atlys
PART  = xc6slx45-csg324-3
V    ?= 1

RTL_DIR = ../../rtl
include $(RTL_DIR)/v$(V)/config.mk

IW   ?= 8
DEFS ?=
# CORE_DIV 를 명령행에서 바꾸면 다른 디렉터리에 빌드 (make V=4 CORE_DIV=7 -> build/v4_div7/)
DEFAULT_DIV := $(shell sed -n 's/^CORE_DIV *?= *//p' $(RTL_DIR)/v$(V)/config.mk)
BUILD = build/v$(V)$(if $(filter-out $(DEFAULT_DIV),$(CORE_DIV)),_div$(CORE_DIV))$(foreach d,$(DEFS),_$(subst =,,$(d)))
RTL   = $(wildcard $(RTL_DIR)/common/*.v) $(wildcard $(RTL_DIR)/v$(V)/*.v) $(TOP).v
CFG   = $(RTL_DIR)/v$(V)/config.mk

all: $(BUILD)/$(TOP).bit

# 프로젝트 / XST 스크립트는 버전마다 생성 (경로는 $(BUILD) 기준)
$(BUILD)/$(TOP).prj: $(RTL) $(CFG) Makefile
	mkdir -p $(BUILD)/xst/tmp
	rm -f $@; for f in $(RTL); do echo "verilog work \"../../$$f\"" >> $@; done

$(BUILD)/$(TOP).xst: $(CFG) Makefile
	@# DEFS 가 바뀌면 빌드 디렉터리 이름도 바뀌므로 따로 의존성을 둘 필요 없다
	mkdir -p $(BUILD)
	printf '%s\n' \
	    'set -tmpdir xst/tmp' 'set -xsthdpdir xst' 'run' \
	    '-ifn $(TOP).prj' '-ifmt mixed' '-ofn $(TOP)' '-ofmt NGC' '-p $(PART)' '-top $(TOP)' \
	    '-generics {W=$(W) IW=$(IW) CORE_DIV=$(CORE_DIV) VERSION=$(V)}' \
	    $(if $(DEFS),'-define {$(DEFS)}') \
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
	grep -E "Number of (Slice Registers|Slice LUTs|occupied Slices|RAMB16BWERs|DSP48A1s):" $(BUILD)/$(TOP)_map.mrp

prog: $(BUILD)/$(TOP).bit
	@# ISE settings64.sh 가 넣는 옛 libstdc++ 를 Adept 가 잡지 않도록 LD_LIBRARY_PATH 를 비운다
	env -u LD_LIBRARY_PATH djtgcfg prog -d Atlys -i 0 -f $(BUILD)/$(TOP).bit

clean:
	rm -rf build

.PHONY: all timing util prog clean
