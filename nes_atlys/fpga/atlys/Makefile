# ---------------------------------------------------------------------------
# Digilent Atlys (Spartan-6 XC6SLX45-CSG324-3) 빌드 - Xilinx ISE 14.7 명령행 흐름
#
#   ISE 환경 (settings64.sh) 은 xst 가 PATH 에 없으면 Makefile 이 알아서 불러온다.
#   설치 위치가 다르면 ISE_DIR=... 로 지정 (기본 ~/Xilinx/14.7/ISE_DS)
#
#   make ROM=~/roms/smb.nes   ROM 을 BRAM 에 넣은 비트스트림 (build/nes_atlys.bit)
#   make                      마지막으로 지정한 ROM 그대로 (처음이면 빈 ROM)
#   make ROM=none             빈 ROM 으로 (UART 로더로 올릴 때)
#   make prog                 Digilent Adept 2 (djtgcfg) 로 보드에 다운로드 (전원 끄면 사라짐)
#   make load ROM=...         실행 중인 보드에 UART 로 ROM 올리기 (PORT=/dev/ttyUSB0)
#   make timing               타이밍 요약 보기
#   make clean
#
#   ROM 은 맵퍼 0 (NROM) 만 된다: Super Mario Bros., Excitebike, Donkey Kong, Balloon Fight ...
# ---------------------------------------------------------------------------
SHELL  := /bin/bash
ISE_DIR ?= $(HOME)/Xilinx/14.7/ISE_DS

# ISE 명령 앞에 붙인다: PATH 에 xst 가 없으면 settings64.sh 를 source (XILINX, PATH, LD_LIBRARY_PATH 설정)
ifeq ($(shell command -v xst 2>/dev/null),)
ISE = source $(ISE_DIR)/settings64.sh $(ISE_DIR) >/dev/null &&
endif

# CPU 디코드 -> 버스 -> PPU 경로가 10 ns 에 거의 꽉 차서 (원본 설계 그대로) 배치배선 노력도를 최대로
MAP_OPTS ?= -ol high -xe n -global_opt speed -register_duplication on -logic_opt on
PAR_OPTS ?= -ol high -xe n

TOP    = nes_atlys
PART   = xc6slx45-csg324-3
BUILD  = build
PYTHON ?= python3
PORT   ?= /dev/ttyUSB0
ROM    ?=

RTL = $(wildcard ../../rtl/*.v) $(shell find ../../rtl/fpga_nes -name '*.v') $(wildcard *.v)

# 비트스트림에 넣을 ROM 은 build/rom/rom_name 에 기억한다 (--blank = 빈 ROM)
#   ROM= 을 주면 그 값으로 바꾸고 (내용이 바뀔 때만 써서 불필요한 재합성을 막는다),
#   안 주면 마지막 값을 그대로 쓴다 -> ROM 없이 make prog / make timing 해도 다시 합성하지 않는다
ROM_ARG := $(if $(filter none,$(ROM)),--blank,$(if $(ROM),$(abspath $(ROM))))
$(shell mkdir -p $(BUILD)/rom; \
        if [ -n '$(ROM_ARG)' ]; then echo '$(ROM_ARG)' | cmp -s - $(BUILD)/rom/rom_name || echo '$(ROM_ARG)' > $(BUILD)/rom/rom_name; \
        elif [ ! -f $(BUILD)/rom/rom_name ]; then echo '--blank' > $(BUILD)/rom/rom_name; fi)
ROM_SRC := $(shell cat $(BUILD)/rom/rom_name)

all: $(BUILD)/$(TOP).bit

$(BUILD)/rom/rom_cfg.vh: $(BUILD)/rom/rom_name ../../tools/nes2hex.py $(filter-out --blank,$(ROM_SRC))
	$(PYTHON) ../../tools/nes2hex.py $(ROM_SRC) $(BUILD)/rom

ise-check:
	@$(ISE) command -v xst || { echo "ISE 를 찾을 수 없습니다: ISE_DIR=$(ISE_DIR)"; exit 1; }

$(BUILD)/$(TOP).ngc: $(RTL) $(TOP).prj $(TOP).xst $(BUILD)/rom/rom_cfg.vh
	mkdir -p $(BUILD)/xst/tmp
	cd $(BUILD) && $(ISE) xst -ifn ../$(TOP).xst -ofn $(TOP).syr

$(BUILD)/$(TOP).ngd: $(BUILD)/$(TOP).ngc atlys.ucf
	cd $(BUILD) && $(ISE) ngdbuild -dd _ngo -uc ../atlys.ucf -p $(PART) $(TOP).ngc $(TOP).ngd

$(BUILD)/$(TOP)_map.ncd: $(BUILD)/$(TOP).ngd
	cd $(BUILD) && $(ISE) map -w -p $(PART) $(MAP_OPTS) -o $(TOP)_map.ncd $(TOP).ngd $(TOP).pcf

$(BUILD)/$(TOP).ncd: $(BUILD)/$(TOP)_map.ncd
	cd $(BUILD) && $(ISE) par -w $(PAR_OPTS) $(TOP)_map.ncd $(TOP).ncd $(TOP).pcf
	cd $(BUILD) && $(ISE) trce -v 200 -fastpaths $(TOP).ncd $(TOP).pcf -o $(TOP).twr

$(BUILD)/$(TOP).bit: $(BUILD)/$(TOP).ncd
	cd $(BUILD) && $(ISE) bitgen -w -g StartUpClk:JtagClk $(TOP).ncd $(TOP).bit

timing: $(BUILD)/$(TOP).ncd
	grep -A12 "^Timing summary" $(BUILD)/$(TOP).twr
	grep -A30 "Derived Constraint Report" $(BUILD)/$(TOP).twr | head -40

prog: $(BUILD)/$(TOP).bit
	@# ISE settings64.sh 가 넣는 옛 libstdc++ 를 Adept 가 잡지 않도록 LD_LIBRARY_PATH 를 비운다
	env -u LD_LIBRARY_PATH djtgcfg prog -d Atlys -i 0 -f $(BUILD)/$(TOP).bit

load:
	@test -n "$(ROM)" -a "$(ROM)" != none || { echo "ROM=게임.nes 를 지정하세요"; exit 1; }
	$(PYTHON) ../../tools/nes_loader.py $(ROM) -p $(PORT)

clean:
	rm -rf $(BUILD)

.PHONY: all timing prog load clean ise-check
