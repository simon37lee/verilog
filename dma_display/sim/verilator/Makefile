# ---------------------------------------------------------------------------
# dma_display_core 실시간 가상 모니터 (Verilator + SDL2): 소스 / 타겟1(FIFO) / 타겟2(CDC 없음)
#
#   make run        빌드 후 실시간 실행 (체크보드가 대각선으로 스크롤)
#   make check      SCROLL=0 으로 빌드해서 소스/타겟1 이 체크보드와 정확히 같은지 검사, 타겟2 오류 수 보고
#   make bench      실시간 제한 없이 최대 속도 측정 (창 없음)
#   make clean
# ---------------------------------------------------------------------------
VERILATOR   ?= verilator
SDL2_CONFIG ?= sdl2-config

RTL_DIR = ../../rtl
RTL     = $(RTL_DIR)/video_timing.v $(RTL_DIR)/dpram.v $(RTL_DIR)/async_fifo.v \
          $(RTL_DIR)/checker_writer.v $(RTL_DIR)/dma_reader.v $(RTL_DIR)/dma_writer.v $(RTL_DIR)/dma_naive_tx.v \
          $(RTL_DIR)/tri_display.v $(RTL_DIR)/dma_display_core.v

# Verilator 기본값 OPT_FAST=-Os 가 CFLAGS 의 -O 옵션을 덮어쓰므로 직접 지정
OPT = OPT_FAST="-O3 -march=native" OPT_GLOBAL="-O3 -march=native"

define build
	$(VERILATOR) --cc --exe -O3 --x-assign fast --x-initial fast \
	    -Wno-fatal -Wno-WIDTH \
	    --top-module dma_display_core $(2) --clk clk_pix --clk clk_src --clk clk_tgt \
	    -CFLAGS "-std=c++14 $(shell $(SDL2_CONFIG) --cflags)" \
	    -LDFLAGS "$(shell $(SDL2_CONFIG) --libs)" \
	    --Mdir $(1) $(RTL) vmon_sdl.cpp
	$(MAKE) -C $(1) -f Vdma_display_core.mk -j $(OPT)
endef

BIN       = obj_dir/Vdma_display_core
BIN_CHECK = obj_check/Vdma_display_core

all: $(BIN)

$(BIN): $(RTL) vmon_sdl.cpp Makefile
	$(call build,obj_dir,)

$(BIN_CHECK): $(RTL) vmon_sdl.cpp Makefile
	$(call build,obj_check,-GSCROLL=0)

run: $(BIN)
	./$(BIN)

check: $(BIN_CHECK)
	SDL_VIDEODRIVER=dummy ./$(BIN_CHECK) --no-limit --frames 30 --check --dump obj_check/check.bmp

bench: $(BIN)
	SDL_VIDEODRIVER=dummy ./$(BIN) --no-limit --frames 180 --dump obj_dir/bench.bmp

clean:
	rm -rf obj_dir obj_check

.PHONY: all run check bench clean
