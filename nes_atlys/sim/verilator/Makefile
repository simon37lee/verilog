# ---------------------------------------------------------------------------
# nes_atlys_core 실시간 가상 모니터 (Verilator + SDL2)
#
#   make run [ROM=게임.nes]   ROM 을 BRAM 에 미리 넣고 실행 (기본: roms/test/nestest.nes)
#   make test                 창 없이 nestest 를 돌려 화면을 obj_dir/test.bmp 로 저장
#   make uart-test            빈 ROM 으로 부팅 -> nes_loader.py 패킷을 UART 로 보내 ROM 교체 -> obj_dir/uart.bmp
#   make clean
#
#   ROM 을 바꾸면 cart 설정 (iNES 헤더) 이 파라미터라서 다시 Verilate 한다.
#   시뮬레이션의 UART 는 1.5625 Mbaud (100 MHz / 16 / 4, 오차 0) 로 빠르게 돌린다. 보드는 115200.
# ---------------------------------------------------------------------------
VERILATOR   ?= verilator
SDL2_CONFIG ?= sdl2-config
PYTHON      ?= python3

TOP  = ../..
RTL  = $(TOP)/rtl
NES  = $(RTL)/fpga_nes
SRCS = $(RTL)/nes_atlys_core.v \
       $(NES)/nes_top.v $(NES)/wram.v $(NES)/vram.v $(NES)/cart/cart.v \
       $(wildcard $(NES)/cpu/*.v) $(wildcard $(NES)/cpu/apu/*.v) $(wildcard $(NES)/ppu/*.v) \
       $(NES)/hci/hci.v $(NES)/cmn/uart/uart.v $(NES)/cmn/vga_sync/vga_sync.v $(NES)/cmn/block_ram/block_ram.v

ROM       ?= $(TOP)/roms/test/nestest.nes
SIM_BAUD   = 1562500

# Verilator 기본값 OPT_FAST=-Os 가 CFLAGS 의 -O 옵션을 덮어쓰므로 직접 지정
OPT = OPT_FAST="-O3 -march=native" OPT_GLOBAL="-O3 -march=native"

# $(1) = 빌드 디렉터리, $(2) = ROM (또는 --blank)
define build
	mkdir -p $(1)
	$(PYTHON) $(TOP)/tools/nes2hex.py $(2) $(1)
	$(VERILATOR) --cc --exe -O3 --x-assign fast --x-initial fast \
	    -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
	    -I$(NES)/cmn/uart -I$(NES)/cmn/fifo +define+NES_SIM_FAST_DECODE \
	    --output-split-cfuncs 0 --output-split 0 \
	    --top-module nes_atlys_core \
	    -GPRG_INIT_FILE='"$(abspath $(1))/prg.hex"' -GCHR_INIT_FILE='"$(abspath $(1))/chr.hex"' \
	    -GCART_CFG_INIT=40\'h$$(sed -n "s/.*40'h\([0-9a-f]*\).*/\1/p" $(1)/rom_cfg.vh) \
	    -GUART_BAUD=$(SIM_BAUD) \
	    -CFLAGS "-std=c++14 -DUART_BAUD=$(SIM_BAUD) $(shell $(SDL2_CONFIG) --cflags)" \
	    -LDFLAGS "$(shell $(SDL2_CONFIG) --libs)" \
	    --Mdir $(1) $(SRCS) vmon_nes.cpp
	$(MAKE) -C $(1) -f Vnes_atlys_core.mk -j $(OPT)
endef

# ROM 경로가 바뀌면 다시 빌드
$(shell mkdir -p obj_dir; echo '$(abspath $(ROM))' | cmp -s - obj_dir/rom_name || echo '$(abspath $(ROM))' > obj_dir/rom_name)

BIN       = obj_dir/Vnes_atlys_core
BIN_BLANK = obj_blank/Vnes_atlys_core

all: $(BIN)

$(BIN): $(SRCS) vmon_nes.cpp Makefile $(TOP)/tools/nes2hex.py obj_dir/rom_name $(ROM)
	$(call build,obj_dir,$(ROM))

$(BIN_BLANK): $(SRCS) vmon_nes.cpp Makefile $(TOP)/tools/nes2hex.py
	$(call build,obj_blank,--blank)

run: $(BIN)
	./$(BIN)

# nestest: 메뉴가 뜬 뒤 Start 를 누르면 공식 명령어 테스트를 돌리고 결과를 "OK" 로 표시한다
test: $(BIN)
	SDL_VIDEODRIVER=dummy ./$(BIN) --no-limit --frames 150 --press 60:start:4 --dump obj_dir/test.bmp

uart-test: $(BIN_BLANK)
	$(PYTHON) $(TOP)/tools/nes_loader.py $(ROM) --dump obj_blank/packets.bin
	SDL_VIDEODRIVER=dummy ./$(BIN_BLANK) --no-limit --uart obj_blank/packets.bin --frames 150 \
	    --press 120:start:4 --dump obj_blank/uart.bmp

clean:
	rm -rf obj_dir obj_blank

.PHONY: all run test uart-test clean
