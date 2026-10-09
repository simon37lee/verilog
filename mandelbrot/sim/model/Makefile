# ---------------------------------------------------------------------------
# C++ 기준 모델 실시간 뷰어 (SDL2, CPU 멀티스레드). RTL 시뮬레이션 없이 모델만 돌린다
#
#   make run            V=4 (기본) 의 W / IW / CORE_DIV / PAR 로 빌드 후 실행
#   make V=3 run        다른 버전 (W, IW 가 다르면 그림도 다르다: v1~v3 는 18 비트, 32 배까지)
#   make V=4 CORE_DIV=6 run   FPGA 속도 어림을 다른 클럭으로
#   make clean
# ---------------------------------------------------------------------------
SDL2_CONFIG ?= sdl2-config
CXX         ?= g++
V           ?= 4

RTL_DIR = ../../rtl
include $(RTL_DIR)/v$(V)/config.mk
IW  ?= 8
PAR ?= 1

BIN = obj/model_view_v$(V)_w$(W)_div$(CORE_DIV)

all: $(BIN)

$(BIN): model_view.cpp mandel_model.h $(RTL_DIR)/v$(V)/config.mk Makefile
	mkdir -p obj
	$(CXX) -std=c++14 -O3 -march=native -pthread -Wall \
	    -DMANDEL_W=$(W) -DMANDEL_IW=$(IW) -DMANDEL_VERSION=$(V) -DMANDEL_CORE_DIV=$(CORE_DIV) -DMANDEL_PAR=$(PAR) \
	    -DMANDEL_PALETTE='"$(abspath $(RTL_DIR)/common/palette_rom.v)"' \
	    $(shell $(SDL2_CONFIG) --cflags) -o $@ model_view.cpp $(shell $(SDL2_CONFIG) --libs)

run: $(BIN)
	./$(BIN) $(ARGS)

clean:
	rm -rf obj

.PHONY: all run clean
