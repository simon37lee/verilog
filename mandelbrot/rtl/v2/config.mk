# v2: 4 단 파이프라인 링 1 개, 픽셀 4 개 인터리브 (매 클럭 반복 1 회, 픽셀 오버헤드 없음)
#   CORE_DIV : clk_core = 1000 MHz / CORE_DIV (PLL VCO 1000 MHz)
#   W        : 코어 고정소수점 비트 수 (소수부 W - 4)
CORE_DIV ?= 6
W        ?= 18
