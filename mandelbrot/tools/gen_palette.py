#!/usr/bin/env python3
"""rtl/common/palette_rom.v 생성: 반복 횟수 (8 비트) -> RGB888 팔레트 ROM

  0       : 집합 안쪽 (검정)
  1..255  : 주기 PERIOD 로 반복되는 그라데이션 (Ultra Fractal 기본 팔레트 비슷한 색)

  python3 tools/gen_palette.py > rtl/common/palette_rom.v
"""
PERIOD = 64

# (위치 0~1, R, G, B) - 순환
STOPS = [
    (0.0,    0,   7, 100),
    (0.16,  32, 107, 203),
    (0.42, 237, 255, 255),
    (0.6425, 255, 170, 0),
    (0.8575,  0,   2,   0),
    (1.0,    0,   7, 100),
]


def grad(t):
    for (p0, *c0), (p1, *c1) in zip(STOPS, STOPS[1:]):
        if p0 <= t <= p1:
            f = (t - p0) / (p1 - p0)
            return [round(a + (b - a) * f) for a, b in zip(c0, c1)]
    return STOPS[0][1:]


print("""// ---------------------------------------------------------------------------
// palette_rom : 반복 횟수 -> RGB888 (tools/gen_palette.py 가 생성, 직접 고치지 말 것)
//   0 = 집합 안쪽 (검정), 1..255 = 주기 %d 그라데이션. 읽기 지연 1 클럭.
// ---------------------------------------------------------------------------
module palette_rom (
    input  wire        clk,
    input  wire [7:0]  idx,
    output reg  [23:0] rgb
);
    always @(posedge clk)
        case (idx)""" % PERIOD)
for i in range(256):
    r, g, b = (0, 0, 0) if i == 0 else grad(((i - 1) % PERIOD) / PERIOD)
    print("            8'd%d: rgb <= 24'h%02X%02X%02X;" % (i, r, g, b))
print("""        endcase
endmodule""")
