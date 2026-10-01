# verilog

Verilog 디지털 로직 실습 프로젝트. 화면 출력은 실제 모니터 대신 Verilator + SDL2 가상 모니터로 실시간 확인한다.

| 폴더 | 내용 |
|---|---|
| [`hdmi_checker/`](hdmi_checker) | 640x480 체크보드 + 0.1초마다 8방향으로 움직이는 빨간 공을 HDMI(TMDS)로 출력 |
| [`dma_display/`](dma_display) | 400x400 소스 버퍼를 DMA 로 33 MHz → 22 MHz 도메인에 복사. 타겟1 은 async FIFO(올바른 CDC), 타겟2 는 CDC 없이 직접 전달(의도적인 노이즈). 640x480 화면을 3등분해 동시에 표시 |

## 필요한 도구
- Icarus Verilog (`iverilog`, `vvp`) — 테스트벤치
- Verilator 4.x + SDL2 개발 헤더 — 실시간 가상 모니터
- Python 3 + pygame — `hdmi_checker` 의 PPM 프레임 뷰어

## hdmi_checker
```bash
cd hdmi_checker
# 테스트벤치 (TMDS 인코더 / 전체 HDMI 경로)
iverilog -g2005 -o tb.vvp sim/tb_hdmi.v rtl/{video_timing,checkerboard,tmds_encoder,ball_mover,hdmi_core,tmds_serializer}.v && vvp tb.vvp
# 실시간 가상 모니터
cd sim/verilator && make run
```
- `rtl/` : 비디오 타이밍, 체크보드+공, TMDS 8b/10b 인코더, 10:1 직렬화기, Xilinx 7-series 최상위(MMCM/OBUFDS)
- `sim/` : iverilog 테스트벤치, iverilog 가상 모니터(PPM 저장), Verilator+SDL 실시간 모니터
- `constraints/` : XDC 템플릿 (핀 번호는 보드에 맞게 채워야 함)

## dma_display
```bash
cd dma_display/sim/verilator
make run      # 실시간 표시 (↑/↓ 로 타겟2 배선 skew 조절)
make check    # 소스/타겟1 이 체크보드와 정확히 같은지 자동 검사, 타겟2 오류 수 보고
```
- 클럭 도메인: 소스 33 MHz / 타겟 22 MHz / 화면 25 MHz (서로 비동기)
- `rtl/dma_display_core.v` 가 전체 구조, `rtl/dma_display_top.v` 는 합성용 최상위
- RTL 시뮬레이션은 메타스테빌리티를 재현하지 못하므로, 타겟2 버스의 비트별 배선 지연과
  메타스테빌리티는 C++ 테스트벤치(`sim/verilator/vmon_sdl.cpp` 의 `BusWire`)가 모델링한다
