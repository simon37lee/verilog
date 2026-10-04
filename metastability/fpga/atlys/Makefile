# ---------------------------------------------------------------------------
# Digilent Atlys (Spartan-6 XC6SLX45-CSG324-3) 빌드 - Xilinx ISE 14.7 명령행 흐름
#   Spartan-6 는 Vivado 가 지원하지 않으므로 ISE 14.7 (WebPACK, 무료) 이 필요하다.
#
#   source ~/Xilinx/14.7/ISE_DS/settings64.sh   # 먼저 ISE 환경 설정
#   make            합성 -> 배치배선 -> 타이밍 리포트 -> 비트스트림 (build/meta_lab_atlys.bit)
#   make prog       Digilent Adept 2 (djtgcfg) 로 보드에 다운로드 (전원 끄면 사라짐)
#   make taps       TDC 탭 지연 (meta_lab_atlys.v 의 TAP_X10_A/B 에 반영)
#   make timing     타이밍 요약 보기
#   make clean
# ---------------------------------------------------------------------------
TOP   = meta_lab_atlys
PART  = xc6slx45-csg324-3
BUILD = build

RTL = $(wildcard ../../rtl/*.v) $(wildcard *.v)

all: $(BUILD)/$(TOP).bit

$(BUILD)/$(TOP).ngc: $(RTL) $(TOP).prj $(TOP).xst
	mkdir -p $(BUILD)/xst/tmp
	cd $(BUILD) && xst -ifn ../$(TOP).xst -ofn $(TOP).syr

$(BUILD)/$(TOP).ngd: $(BUILD)/$(TOP).ngc atlys.ucf
	cd $(BUILD) && ngdbuild -dd _ngo -uc ../atlys.ucf -p $(PART) $(TOP).ngc $(TOP).ngd

$(BUILD)/$(TOP)_map.ncd: $(BUILD)/$(TOP).ngd
	cd $(BUILD) && map -w -p $(PART) -ol high -o $(TOP)_map.ncd $(TOP).ngd $(TOP).pcf

$(BUILD)/$(TOP).ncd: $(BUILD)/$(TOP)_map.ncd
	cd $(BUILD) && par -w -ol high $(TOP)_map.ncd $(TOP).ncd $(TOP).pcf
	cd $(BUILD) && trce -v 200 -fastpaths $(TOP).ncd $(TOP).pcf -o $(TOP).twr

$(BUILD)/$(TOP).bit: $(BUILD)/$(TOP).ncd
	cd $(BUILD) && bitgen -w -g StartUpClk:JtagClk $(TOP).ncd $(TOP).bit

taps: $(BUILD)/$(TOP).ncd
	python3 taps.py $(BUILD)/$(TOP).twr

timing: $(BUILD)/$(TOP).ncd
	grep -A12 "^Timing summary" $(BUILD)/$(TOP).twr
	grep -A30 "Derived Constraint Report" $(BUILD)/$(TOP).twr | head -40

prog: $(BUILD)/$(TOP).bit
	@# ISE settings64.sh 가 넣는 옛 libstdc++ 를 Adept 가 잡지 않도록 LD_LIBRARY_PATH 를 비운다
	env -u LD_LIBRARY_PATH djtgcfg prog -d Atlys -i 0 -f $(BUILD)/$(TOP).bit

clean:
	rm -rf $(BUILD)

.PHONY: all taps timing prog clean
