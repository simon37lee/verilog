# ---------------------------------------------------------------------------
# matrix_system 실시간 가상 모니터 (Verilator + SDL2)
#
#   make run            V 버전 빌드 후 실행 (기본 V=1)
#   make V=2 run        rtl/common + rtl/v2 로 빌드 (obj_v2/ 에 따로 빌드)
#   make check          화면 프레임마다 셀 RAM 모델과 비교 (CHECK_FRAMES 장, 기본 4)
#   make check-all      rtl/v*/ 의 모든 버전 검사
#   make clean
#
#   글꼴을 바꾸면 먼저 python3 ../../tools/gen_font.py (glyph_rom.v 와 glyphs.h 를 같이 만든다)
# ---------------------------------------------------------------------------
VERILATOR   ?= verilator
SDL2_CONFIG ?= sdl2-config
V           ?= 1
CHECK_FRAMES ?= 4

RTL_DIR  = ../../rtl
VERSIONS = $(shell ls -d $(RTL_DIR)/v*/ | sed 's|.*/v\([0-9]*\)/|\1|' | sort -n)

# 버전 폴더에 공통 파일과 같은 이름이 있으면 그것으로 바꾼다
VER_RTL = $(wildcard $(RTL_DIR)/v$(V)/*.v)
RTL = $(filter-out $(addprefix $(RTL_DIR)/common/,$(notdir $(VER_RTL))),$(wildcard $(RTL_DIR)/common/*.v)) $(VER_RTL)

MDIR = obj_v$(V)
BIN  = $(MDIR)/Vmatrix_system

OPT = OPT_FAST="-O3 -march=native" OPT_GLOBAL="-O3 -march=native"

all: $(BIN)

$(BIN): $(RTL) vmon_matrix.cpp glyphs.h Makefile
	$(VERILATOR) --cc --exe -O3 --x-assign fast --x-initial 0 \
	    -Wno-fatal -Wno-WIDTH \
	    --top-module matrix_system \
	    -CFLAGS "-std=c++14 -DMATRIX_VERSION=$(V) $(shell $(SDL2_CONFIG) --cflags)" \
	    -LDFLAGS "$(shell $(SDL2_CONFIG) --libs)" \
	    --Mdir $(MDIR) $(RTL) vmon_matrix.cpp
	$(MAKE) -C $(MDIR) -f Vmatrix_system.mk -j $(OPT)

run: $(BIN)
	./$(BIN)

check: $(BIN)
	SDL_VIDEODRIVER=dummy ./$(BIN) --no-limit --frames $(CHECK_FRAMES) --check --dump $(MDIR)/check.bmp

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
