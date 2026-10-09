# matrix

영화 매트릭스의 "디지털 레인" 화면 보호기를 Atlys 에서 1280x720 HDMI 로 출력한다.
화면 구조 (720p 타이밍, 글자 칸 RAM, 글꼴 ROM) 부터 만들고 단계별로 빗줄기 효과를 올린다.

```
rtl/common/   matrix_system (최상위), matrix_display (칸 RAM + 글꼴 -> 픽셀), glyph_rom (생성),
              video_timing, dpram, tmds_*
rtl/vN/       matrix_engine.v (셀 RAM 을 고치는 쪽, 버전마다 다름)
tools/        gen_font.py (글꼴 ROM + 시뮬레이션용 glyphs.h + 미리보기 생성)
sim/verilator/ 실시간 가상 모니터 + 검사
fpga/atlys/   보드 최상위 (PLL 74 MHz / 370 MHz), UCF, ISE Makefile
```

## 구조
- 화면 1280x720 을 16x24 칸 80x30 개로 나눈다. 칸 하나 = 셀 RAM 12 비트 `{밝기 6, 글자 번호 6}`
  - 밝기 0 = 빈 칸, 1~55 = 초록 (밝을수록 진함), 56~63 = 흰색에 가까움 (빗줄기 머리)
- 글꼴: Noto Sans CJK JP 의 반각 가타카나 54 개 (영화처럼 좌우 뒤집음) + 숫자 10 개 = 64 개.
  `tools/gen_font.py` 가 16x24 1 비트 비트맵으로 만든다 (`tools/font_preview.png`)
- 화면 파이프라인 4 단: 셀 주소 (y / 24 는 `y * 2731 >> 16`) -> 셀 RAM -> 글꼴 ROM -> 비트 + 팔레트
- 프레임버퍼가 없어서 BRAM 을 거의 안 쓴다 (셀 RAM 3 개 + 글꼴 ROM 2 개 정도)
- **엔진 규칙**: 셀 RAM 은 vblank (30 줄 = 49500 클럭) 에만 쓴다 -> 화면이 찢어지지 않고 검사가 프레임마다 정확

## 실행
```bash
cd sim/verilator
make run            # 가상 모니터 (720p 라 실시간보다 느림)
make check          # 4 프레임 동안 화면 전체를 셀 RAM 모델 + 글꼴 + 팔레트와 비교
make V=2 check      # 다른 버전

cd fpga/atlys
source ~/Xilinx/14.7/ISE_DS/settings64.sh
make && make timing && make util && make prog
```
- RESET (T15, active-low) 처음부터. LED: 0 PLL lock, 1 RESET, 2 픽셀 클럭 깜빡임, 3 vsync 32 번마다 토글

## 클럭
- 720p 규격 픽셀 클럭은 74.25 MHz 인데, Spartan-6 PLL 은 위상 비교 주파수가 19 MHz 이상이라
  100 MHz 에서 정확히 못 만든다. 100 / 5 x 37 = VCO 740 MHz -> 픽셀 74.0 MHz (59.8 Hz), 직렬화 370 MHz
- TMDS 직렬화는 만델브로와 같은 DDR 방식 (ODDR2, 클럭당 2 비트). 370 MHz 는 BUFG 한계 (400 MHz) 에 가깝다.
  처음엔 시프트 레지스터 -> ODDR2 배선이 3.3 ns 라서 실패 -> ODDR2 앞에 출력 레지스터를 한 단 두어 통과 (여유 0.06 ns).
  모니터에서 안 잡히거나 타이밍이 깨지면 OSERDES2 + BUFPLL 로 바꾼다

## 단계별 기록
| 단계 | 내용 |
|---|---|
| v1 | 정적인 글자 격자. 리셋 뒤 첫 vblank 에 2400 칸을 난수 (xorshift32) 글자 / 밝기로 채움. 타이밍 통과 (370 MHz 여유 0.06 ns), LUT 3 %, BRAM 3, DSP 1 |

## 다음 단계
- **v2**: 빗줄기. 열마다 머리 위치 / 속도 / 길이, 머리는 흰색, 꼬리로 갈수록 어두워짐
- **v3**: 글자 반짝임 (가끔 바뀜), 서서히 사라지는 잔상, 겹치는 빗줄기
