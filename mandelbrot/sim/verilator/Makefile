# ---------------------------------------------------------------------------
# mandel_system 실시간 가상 모니터 (Verilator + SDL2)
#
#   make run            V 버전 빌드 후 실시간 실행 (기본 V=1)
#   make V=2 run        rtl/common + rtl/v2 로 빌드 (obj_v2/ 에 따로 빌드)
#   make check          첫 렌더 프레임을 C++ 고정소수점 모델과 비교 + 렌더 시간 / 반복 속도 보고
#   make check-all      rtl/v*/ 의 모든 버전을 검사하고 결과를 표로
#   make clean
#
#   버전별 설정 (clk_core 분주비 CORE_DIV, 비트 폭 W) 은 rtl/vN/config.mk.
#   명령행에서 덮어쓸 수 있다: make V=2 W=24 check  (빌드 디렉터리는 obj_v2_w24/)
# ---------------------------------------------------------------------------
VERILATOR   ?= verilator
SDL2_CONFIG ?= sdl2-config
V           ?= 1

RTL_DIR = ../../rtl
include $(RTL_DIR)/v$(V)/config.mk

CORE_HZ  = $(shell echo $$((1000000000 / $(CORE_DIV))))
VERSIONS = $(shell ls -d $(RTL_DIR)/v*/ | sed 's|.*/v\([0-9]*\)/|\1|' | sort -n)

RTL = $(wildcard $(RTL_DIR)/common/*.v) $(wildcard $(RTL_DIR)/v$(V)/*.v)

# W 를 덮어쓰면 다른 디렉터리에 빌드 (기본 W 결과와 섞이지 않게)
DEFAULT_W := $(shell sed -n 's/^W *?= *//p' $(RTL_DIR)/v$(V)/config.mk)
MDIR = obj_v$(V)$(if $(filter-out $(DEFAULT_W),$(W)),_w$(W))
BIN  = $(MDIR)/Vmandel_system

OPT = OPT_FAST="-O3 -march=native" OPT_GLOBAL="-O3 -march=native"

all: $(BIN)

$(BIN): $(RTL) $(RTL_DIR)/v$(V)/config.mk vmon_mandel.cpp Makefile
	$(VERILATOR) --cc --exe -O3 --x-assign fast --x-initial fast \
	    -Wno-fatal -Wno-WIDTH \
	    --top-module mandel_system -GW=$(W) -GCORE_HZ=$(CORE_HZ) -GVERSION=$(V) \
	    --clk clk_pix --clk clk_core \
	    -CFLAGS "-std=c++14 -DMANDEL_W=$(W) -DMANDEL_VERSION=$(V) -DMANDEL_CORE_DIV=$(CORE_DIV) $(shell $(SDL2_CONFIG) --cflags)" \
	    -LDFLAGS "$(shell $(SDL2_CONFIG) --libs)" \
	    --Mdir $(MDIR) $(RTL) vmon_mandel.cpp
	$(MAKE) -C $(MDIR) -f Vmandel_system.mk -j $(OPT)

run: $(BIN)
	./$(BIN)

check: $(BIN)
	SDL_VIDEODRIVER=dummy ./$(BIN) --no-limit --renders 2 --check --dump $(MDIR)/check.bmp

# 버전마다 빌드 + 검사, 마지막에 RESULT 줄만 모아서 보여 준다
check-all:
	@rm -f check_all.log; fail=0; \
	for v in $(VERSIONS); do \
	    echo "=== v$$v ==="; \
	    $(MAKE) --no-print-directory V=$$v check > check_v$$v.log 2>&1 || fail=1; \
	    grep -E "^(CHECK|RESULT)" check_v$$v.log; \
	    grep "^RESULT" check_v$$v.log >> check_all.log || echo "RESULT v$$v: build or run failed" >> check_all.log; \
	done; \
	echo; echo "--- summary ---"; cat check_all.log; exit $$fail

clean:
	rm -rf obj_v* check_v*.log check_all.log

.PHONY: all run check check-all clean
