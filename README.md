# verilog

Verilog 디지털 로직 실습 프로젝트. 화면 출력은 실제 모니터 대신 Verilator + SDL2 가상 모니터로 실시간 확인한다.

| 폴더 | 내용 |
|---|---|
| [`hdmi_checker/`](hdmi_checker) | 640x480 체크보드 + 0.1초마다 8방향으로 움직이는 빨간 공을 HDMI(TMDS)로 출력 |
| [`dma_display/`](dma_display) | 400x400 소스 버퍼를 DMA 로 33 MHz → 22 MHz 도메인에 복사. 타겟1 은 async FIFO(올바른 CDC), 타겟2 는 CDC 없이 직접 전달(의도적인 노이즈). 640x480 화면을 3등분해 동시에 표시 |
| [`nes_atlys/`](nes_atlys) | NES (패미컴) 를 Atlys 에서 HDMI 로 실행. [brianbennett/fpga_nes](https://github.com/brianbennett/fpga_nes) (Nexys3) 포팅, 맵퍼 0 게임 (슈퍼마리오 등) |
| [`metastability/`](metastability) | 메타스테빌리티 측정 실험. 비동기 신호(링 오실레이터)를 샘플링한 FF 의 출력 시각을 carry chain TDC 로 재서 로그 히스토그램으로 표시, 동기 신호 대조군과 비교 |

## 필요한 도구
- Icarus Verilog (`iverilog`, `vvp`) — 테스트벤치
- Verilator 4.x + SDL2 개발 헤더 — 실시간 가상 모니터
- Python 3 + pygame — `hdmi_checker` 의 PPM 프레임 뷰어
- (FPGA) Xilinx ISE 14.7 + Digilent Adept 2 — `dma_display` 를 Atlys 보드에 올릴 때

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

### Atlys 보드 (Spartan-6 XC6SLX45) 로 포팅
```bash
cd dma_display/fpga/atlys
source ~/Xilinx/14.7/ISE_DS/settings64.sh   # Spartan-6 는 Vivado 미지원 -> ISE 14.7
make          # build/dma_display_atlys.bit
make timing   # 타이밍 요약
make prog     # Adept 2 (djtgcfg) 로 다운로드
```
- HDMI OUT(J2) 에 모니터 연결

| 입력 | 아래 (0) | 위 (1) |
|---|---|---|
| SW0 (A10) | 일반 데모 (체크보드 스크롤) | 오류 누적 맵: 스크롤 멈춤 + 회색 무늬 + 타겟2 DMA 쉬지 않고 반복, 타겟1 과 달랐던 타겟2 픽셀을 빨간 점으로 남김 (내리면 지움) |
| SW4~SW1 (P12/P15/C14/D14) | 0: 추가 지연 없음 | 1~15: 도메인을 건너는 신호의 비트 간 지연 차이를 설계값 500~2000 ps 로 (carry chain 지연선, `fpga/atlys/bus_skew.v`). 타겟1 (async FIFO Gray 포인터 5+5 비트) 과 타겟2 (직결 버스 25 비트) 에 똑같이 적용 |
| RESET (T15) | - | 누르는 동안 리셋 (매뉴얼과 달리 active-low) |

- LED: 0/1 = PLL/DCM lock, 2 = RESET 눌림, 3/4/5 = src/tgt/pix 클럭 깜빡임, 6 = vsync, 7 = 타겟1 DMA 진행
- skew 실측 (타이밍 리포트, 가장 느린 조건): 배치 탓에 추가 지연 0 에서도 0.6~1.4 ns 이고 단계별로 고르지 않다
  (단계 0 / 1 / 8 / 15 에서 타겟2 1.37 / 1.64 / 1.97 / 2.44 ns). 정확히 맞추려면 비트별 고정 배치 + 보정이 필요
- 타겟1 은 skew 가 소스 주기(30 ns)보다 훨씬 작으므로 Gray code 덕분에 어느 단계에서도 깨지지 않아야 한다
- 도메인을 건너는 경로는 UCF 에서 5 ns 데이터 경로 상한 (느슨하면 지연선이 멀리 배치되어 skew 가 수 ns)
- 시뮬레이션: `--errmap` (SW0), `--tgt-mhz 40` (타겟 클럭), `--skew-ns` (하네스의 타겟2 skew 모델, FIFO 포인터는 직결)
- 클럭: PLL 에서 125 MHz(TMDS, ODDR2 DDR 출력) / 25 MHz(화면) / 33.33 MHz(소스),
  DCM_CLKGEN 에서 40 MHz(타겟). 타겟이 소스보다 빨라 타겟2 픽셀 누락이 없고, 남는 노이즈는 버스 skew/메타스테빌리티 때문
- Block RAM(약 2.1 Mbit) 에 400x400x3 버퍼(3.84 Mbit)가 들어가지 않아 버퍼를 200x200 으로 줄여 1:1 로 표시한다
  (`dma_display_core` 의 `W/H/AW` 파라미터. 시뮬레이션 기본값은 400x400 그대로)
- 타겟2 노이즈는 여기서는 시뮬레이션 모델이 아니라 실제 배선 지연/메타스테빌리티로 생긴다
- 테스트벤치: `iverilog -g2005 -o tb.vvp sim/tb_tmds_serializer_ddr.v rtl/tmds_serializer_ddr.v && vvp tb.vvp`

## metastability
```bash
cd metastability
# 시뮬레이션 (Verilator --timing, 메타스테빌리티는 sim/models.v 의 sample_ff 가 모델링) -> build/meta_lab.ppm
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-INITIALDLY -Wno-STMTDLY -Irtl --top-module tb_meta_lab \
  --Mdir build/vobj -o vtb sim/tb_meta_lab.v sim/models.v rtl/{meta_lab_core,meta_detector,histogram,hist_display,tau_engine,dpram,video_timing}.v
./build/vobj/vtb +ACC_US=20000            # 모델 tau = 40 ps -> 화면에 약 40 ps (+SWAP=1 로 입력 맞바꾸기)
# Atlys
cd fpga/atlys && source ~/Xilinx/14.7/ISE_DS/settings64.sh && make && make prog
```
- 같은 측정 회로 두 벌: 위 = 링 오실레이터(진짜 비동기) 샘플링, 아래 = 동기 신호(대조군, 메타스테빌리티 불가능)
- 샘플링 FF 출력을 256 탭 carry chain(탭당 약 25 ps)에 넣고, 위상을 늦춘 같은 주파수 클럭(`SAMPLE_PHASE`)으로
  탭을 샘플링해서 "FF 출력이 언제 바뀌었는지" 를 잰다. 오른쪽일수록 늦게 바뀐 것
- y 축은 log2(개수). 봉우리(클럭 지터 폭)는 둘 다 생기고, 위쪽에만 오른쪽으로 직선으로 떨어지는 꼬리가 있으면
  그것이 메타스테빌리티(결정 시간의 지수 분포). 기울기에서 시정수 tau 를 읽을 수 있다
- 각 그래프 오른쪽 위에 tau 표시 (`rtl/tau_engine.v`, 수직 귀선마다 계산): 봉우리의 1/1024 아래로 떨어진 곳부터의
  꼬리에서 평균 초과 지연으로 tau 를 구한다. 데이터가 부족하거나 꼬리가 없으면 `--.-`
- ps 환산은 타이밍 리포트의 탭 지연(가장 느린 조건, 24.0 ps)을 쓰므로 화면의 tau 는 상한값
- SW0 = 두 측정 회로의 입력 맞바꾸기 (봉우리 위치는 회로를, 꼬리는 비동기 신호를 따라가는지 확인)
- RESET 버튼 = 히스토그램 지우기. LED 0 = PLL lock, 1/2 = 회로 A/B 이벤트 진행, 3 = 지우는 중
- 지연선과 샘플링 FF 는 UCF 에서 위치를 고정했다 (두 회로가 같은 탭 지연이 되도록, 다시 빌드해도 그대로).
  위치를 바꾸면 `make taps` 로 탭 지연을 확인해서 `TAP_X10_A/B` 에 반영
- 봉우리가 맨 왼쪽/오른쪽에 붙으면 `meta_lab_atlys.v` 의 `SAMPLE_PHASE` 를 줄이거나/늘려서 다시 빌드


## nes_atlys
[brianbennett/fpga_nes](https://github.com/brianbennett/fpga_nes) (BSD, 커밋 26085d6) 를 Atlys + HDMI 로 옮긴 것.
6502 CPU / PPU / APU 는 원본 그대로이고, 맵퍼 0 (NROM: PRG 16/32KB + CHR 8KB) 만 지원한다.
슈퍼마리오 1, Excitebike, Donkey Kong, Balloon Fight, Ice Climber 같은 게임이 여기에 해당한다. 게임 ROM 은 직접 준비해야 한다.

```bash
# 가상 모니터 (Verilator + SDL2). 실시간의 약 3% (1.7 fps) 라 느리다
cd nes_atlys/sim/verilator
make run ROM=~/roms/smb.nes   # ROM 생략 시 roms/test/nestest.nes
make test                     # 창 없이 nestest 실행 -> obj_dir/test.bmp (CPU 명령어 테스트가 모두 OK 여야 함)
make uart-test                # 빈 ROM 으로 부팅 -> UART 로더로 ROM 교체 -> obj_blank/uart.bmp

# Atlys
cd nes_atlys/fpga/atlys       # ISE 환경은 Makefile 이 알아서 불러옴 (ISE_DIR=~/Xilinx/14.7/ISE_DS)
make ROM=~/roms/smb.nes       # ROM 을 BRAM 에 넣은 비트스트림
make prog                     # 다운로드하면 바로 게임 시작 (HDMI OUT J2)
make load ROM=다른게임.nes    # 실행 중에 USB-UART (J17, 115200 8O1) 로 ROM 교체 (PORT=/dev/ttyUSB0)
```
- 가상 모니터 키: 방향키, X = A, Z = B, Enter = Start, 오른쪽 Shift = Select, F1 = 콘솔 리셋, P = 일시정지, S = 화면 저장

| Atlys | NES |
|---|---|
| BTNU / BTND | SW0 내림 (게임 모드): A (점프) / B (대시, 파이어볼) · SW0 올림 (방향키 모드): 위 / 아래 |
| BTNL / BTNR | 왼쪽 / 오른쪽 |
| BTNC | Start |
| SW5 / SW6 (올리면 누름) | 게임 모드: 위 / 아래 (파이프) · 방향키 모드: A / B |
| SW7 | Select |
| RESET (T15) | 전체 리셋 (BRAM 의 ROM 으로 다시 시작) |

- LED: 0 = PLL lock, 1 = RESET 눌림, 2 = 100 MHz 클럭 깜빡임, 3 = vsync (약 1 Hz), 4 = UART 수신, 5 = 패드 버튼 눌림, 6 = AC97 코덱 준비, 7 = 소리
- 구조: `rtl/nes_atlys_core.v` 가 보드와 무관한 래퍼 (부트 리셋 펄스, 버튼으로 패드 4021 흉내, RGB332 -> 888).
  `fpga/atlys/nes_atlys.v` 는 PLL (100 / 25 / 125 MHz, 모두 같은 PLL) + TMDS 출력
- 원본에서 바꾼 곳은 `rtl/fpga_nes/` 안에 `[nes_atlys]` 주석으로 표시:
  PPU 의 DE 출력 (sync 와 1 클럭 정렬), 카트 BRAM 의 `$readmemh` 초기화, hci 의 보드레이트 / 시작 상태 / 카트 설정 기본값 파라미터
- 원본 CPU 는 rst 로 리셋 벡터를 읽지 않으므로 (원래는 PC 를 로더가 써 줌), 리셋 직후 /RES 를 잠깐 내려 `$FFFC` 부터 시작하게 한다
- 소리: APU 4채널 믹스 (펄스 2, 삼각파, 노이즈 - 원본에 DMC 없음) -> DC 차단 필터 -> AC97 코덱 (LM4550) 48 kHz.
  Atlys 의 HP OUT / LINE OUT 단자에 이어폰이나 스피커.
  볼륨 = {SW4,SW3,SW2,SW1} 4 비트: 모두 내림 (0) = 최대 +12 dB, 1 늘 때마다 -3 dB, 모두 올림 (15) = 음소거.
  LED 6 = 코덱 준비, LED 7 = 소리 나는 중. 컨트롤러 `rtl/ac97_out.v`, 테스트 `iverilog -g2005 -o tb_ac97.vvp sim/tb_ac97.v rtl/ac97_out.v && vvp tb_ac97.vvp`
