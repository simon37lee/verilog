# v1: 코어 1 개, 반복 1 회 / 클럭 (조합 회로), 픽셀 1 개씩
#   CORE_DIV : clk_core = 1000 MHz / CORE_DIV (PLL VCO 1000 MHz)
#   W        : 코어 고정소수점 비트 수 (소수부 W - 4)
CORE_DIV ?= 20
W        ?= 18
