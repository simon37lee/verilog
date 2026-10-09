# v5: 800x600 (화면 1:1) + DDR2 프레임버퍼. 엔진은 v4 (W = 34) + 픽셀 생성 한계, 링 2 개
#   (링 3 개 이상은 보드 전원이 흔들려 DDR2 보정이 풀린다. rtl/v5/mandel_engine.v 머리말)
#   CORE_DIV : clk_core = 1000 MHz / CORE_DIV (7 = 142.9 MHz, v4 와 같은 이유)
#   PIX_DIV  : clk_pix = 1000 MHz / PIX_DIV (25 = 40 MHz, 800x600 @ 60 Hz)
#   화면 / DDR2 / 최상위가 v1~v4 와 달라서 공통 파일 몇 개를 이 폴더의 같은 이름 파일로 바꿔 쓴다
#   (mandel_render, mandel_system, mandel_display). rtl/v5/sim/ 은 시뮬레이션 전용 (DDR2 동작 모델)
CORE_DIV ?= 7
W        ?= 34
IW       ?= 10

# PAR : 클럭당 반복 수 (이론값, sim/model 뷰어가 FPGA 렌더 시간을 어림할 때 쓴다)
PAR      ?= 2

# 해상도 / 화면 타이밍 (C++ 모델과 가상 모니터용. RTL 은 v5 파일 안에 800x600 으로 들어 있다)
FB_W       ?= 800
FB_H       ?= 600
PIX_DIV    ?= 25
FRAME_CLKS ?= 663168

# 시뮬레이션 최상위 (DDR2 동작 모델 포함) / FPGA 최상위와 제약 (fpga/atlys/)
SIM_TOP   ?= mandel_system_sim
BOARD_TOP ?= mandel_atlys_ddr.v
BOARD_UCF ?= atlys_ddr.ucf
BOARD_SRC ?= $(wildcard mig/*.v)
