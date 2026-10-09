# v4: W = 34 비트 (깊은 확대) + 제곱 3 개로 줄인 링 6 개 (링당 DSP48A1 9 개, 합 54 개), max_iter 최대 1023
#   CORE_DIV : clk_core = 1000 MHz / CORE_DIV (PLL VCO 1000 MHz)
#   W        : 코어 고정소수점 비트 수 (소수부 W - 4). 이 링은 18 ~ 34 만 된다
#   IW       : 반복 횟수 비트 수 (max_iter = (2^IW - 1) >> sw_iter)
#   링 개수는 DEFS=RINGS=N 으로 바꿀 수 있다 (기본 6)
CORE_DIV ?= 6
W        ?= 34
IW       ?= 10
