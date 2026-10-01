# ---------------------------------------------------------------------------
# Verilator + SDL2 실시간 가상 모니터
#
#   make            빌드
#   make run        빌드 후 실행 (창을 닫을 때까지 실시간 표시)
#   make bench      60 fps 제한 없이 300 프레임 돌려 최대 속도 측정 (창 없음)
#   make clean
#
#   MOVE_CYCLES=... 로 공 이동 주기를 바꿀 수 있다 (기본: 실제 하드웨어와 같은 0.1 s)
# ---------------------------------------------------------------------------
VERILATOR   ?= verilator
SDL2_CONFIG ?= sdl2-config
# 주의: Verilator 기본값 OPT_FAST=-Os 가 CFLAGS 의 -O 옵션을 덮어쓰므로 여기서 직접 지정
MOVE_CYCLES ?= 2500000

RTL_DIR = ../../rtl
RTL     = $(RTL_DIR)/video_timing.v $(RTL_DIR)/checkerboard.v $(RTL_DIR)/ball_mover.v \
          $(RTL_DIR)/tmds_encoder.v $(RTL_DIR)/hdmi_core.v

OBJ_DIR = obj_dir
BIN     = $(OBJ_DIR)/Vhdmi_core

all: $(BIN)

$(BIN): $(RTL) vmon_sdl.cpp Makefile
	$(VERILATOR) --cc --exe -O3 --x-assign fast --x-initial fast \
	    -Wno-fatal -Wno-WIDTH \
	    --top-module hdmi_core -GMOVE_CYCLES=$(MOVE_CYCLES) \
	    -CFLAGS "-std=c++14 $(shell $(SDL2_CONFIG) --cflags)" \
	    -LDFLAGS "$(shell $(SDL2_CONFIG) --libs)" \
	    --Mdir $(OBJ_DIR) $(RTL) vmon_sdl.cpp
	$(MAKE) -C $(OBJ_DIR) -f Vhdmi_core.mk -j \
	    OPT_FAST="-O3 -march=native" OPT_GLOBAL="-O3 -march=native"

run: $(BIN)
	./$(BIN)

bench: $(BIN)
	SDL_VIDEODRIVER=dummy ./$(BIN) --no-limit --frames 300 --dump $(OBJ_DIR)/bench.bmp

clean:
	rm -rf $(OBJ_DIR)

.PHONY: all run bench clean
