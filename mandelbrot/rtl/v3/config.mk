# v3: 5 단 파이프라인 링 19 개 (DSP48A1 57 개) + 입력 / 출력 버퍼 + 2 단계 라운드로빈 쓰기 중재기
#   CORE_DIV : clk_core = 1000 MHz / CORE_DIV (PLL VCO 1000 MHz)
#   W        : 코어 고정소수점 비트 수 (소수부 W - 4)
#   링 개수는 DEFS=RINGS=N 으로 바꿀 수 있다 (기본 19)
CORE_DIV ?= 6
W        ?= 18

# PAR : 클럭당 반복 수 (이론값, sim/model 뷰어가 FPGA 렌더 시간을 어림할 때 쓴다)
PAR      ?= 19
