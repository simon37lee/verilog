#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# gen_font.py : 매트릭스 글꼴 ROM 생성 (rtl/common/glyph_rom.v)
#
#   Noto Sans CJK JP 로 반각 가타카나 + 숫자 64 개를 그려서 1 비트 비트맵으로 만든다.
#   영화처럼 가타카나는 좌우를 뒤집는다 (숫자는 그대로).
#   글자 칸 16 x 24 (CELL_W x CELL_H), ROM 주소 = {글자 번호 6 비트, 줄 5 비트} (줄 24~31 은 0)
#   한 줄 = 16 비트, 비트 15 가 가장 왼쪽 픽셀.
#
#   python3 tools/gen_font.py   -> rtl/common/glyph_rom.v, sim/verilator/glyphs.h, tools/font_preview.png
# ---------------------------------------------------------------------------
import os
import sys
from PIL import Image, ImageDraw, ImageFont

CELL_W, CELL_H = 16, 24
FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
FONT_INDEX = 0          # ttc 안의 JP
PX = 22                 # 그릴 때 글자 크기 (픽셀)
THRESH = 110            # 회색 -> 1 비트 문턱값

# 반각 가타카나 U+FF66 ~ U+FF9D (56 개) 중 54 개 + 숫자 10 개 = 64
KATA = [chr(c) for c in range(0xFF66, 0xFF9E)]
KATA = [k for k in KATA if k not in "ｯｬ"]           # 작은 글자 두 개 빼기 (나머지와 겹침)
GLYPHS = [(k, True) for k in KATA] + [(d, False) for d in "0123456789"]
assert len(GLYPHS) == 64, len(GLYPHS)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def render(ch, mirror):
    font = ImageFont.truetype(FONT, PX, index=FONT_INDEX)
    img = Image.new("L", (CELL_W * 2, CELL_H * 2), 0)
    d = ImageDraw.Draw(img)
    # 글자 상자를 칸 가운데에 맞춘다
    l, t, r, b = d.textbbox((0, 0), ch, font=font)
    w, h = r - l, b - t
    ox = (CELL_W * 2 - w) // 2 - l
    oy = (CELL_H * 2 - h) // 2 - t
    d.text((ox, oy), ch, font=font, fill=255)
    img = img.crop((CELL_W // 2, CELL_H // 2, CELL_W // 2 + CELL_W, CELL_H // 2 + CELL_H))
    if mirror:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    rows = []
    for y in range(CELL_H):
        v = 0
        for x in range(CELL_W):
            if img.getpixel((x, y)) >= THRESH:
                v |= 1 << (CELL_W - 1 - x)
        rows.append(v)
    return rows


def main():
    glyphs = [render(c, m) for c, m in GLYPHS]

    out = os.path.join(ROOT, "rtl/common/glyph_rom.v")
    with open(out, "w") as f:
        f.write("// ---------------------------------------------------------------------------\n")
        f.write("// glyph_rom : 매트릭스 글꼴 (tools/gen_font.py 가 생성, 직접 고치지 말 것)\n")
        f.write("//   글자 64 개 (0~53 좌우 뒤집은 반각 가타카나, 54~63 숫자 0~9), 칸 %d x %d\n" % (CELL_W, CELL_H))
        f.write("//   addr = {글자 번호, 줄 (0~%d, 나머지는 0)}, bits[15] = 가장 왼쪽 픽셀. 읽기 지연 1 클럭\n" % (CELL_H - 1))
        f.write("// ---------------------------------------------------------------------------\n")
        f.write("module glyph_rom (\n")
        f.write("    input  wire        clk,\n")
        f.write("    input  wire [10:0] addr,\n")
        f.write("    output reg  [15:0] bits\n")
        f.write(");\n")
        f.write("    always @(posedge clk)\n")
        f.write("        case (addr)\n")
        for g, rows in enumerate(glyphs):
            for y, v in enumerate(rows):
                if v:
                    f.write("            11'd%d: bits <= 16'h%04X;\n" % (g * 32 + y, v))
        f.write("            default: bits <= 16'h0000;\n")
        f.write("        endcase\n")
        f.write("endmodule\n")
    print("wrote", out)

    # 시뮬레이션 검사기용 C 헤더 (sim/verilator/glyphs.h)
    h = os.path.join(ROOT, "sim/verilator/glyphs.h")
    with open(h, "w") as f:
        f.write("// tools/gen_font.py 가 생성 (rtl/common/glyph_rom.v 와 같은 데이터). 직접 고치지 말 것\n")
        f.write("#pragma once\n#include <cstdint>\n")
        f.write("constexpr int GLYPH_W = %d, GLYPH_H = %d, GLYPH_N = %d;\n" % (CELL_W, CELL_H, len(glyphs)))
        f.write("static const uint16_t GLYPHS[GLYPH_N][GLYPH_H] = {\n")
        for rows in glyphs:
            f.write("    {" + ", ".join("0x%04X" % v for v in rows) + "},\n")
        f.write("};\n")
    print("wrote", h)

    # 미리보기 (16 x 4 글자, 3 배 확대)
    cols = 16
    prev = Image.new("L", (cols * CELL_W, (64 // cols) * CELL_H), 0)
    for g, rows in enumerate(glyphs):
        gx, gy = (g % cols) * CELL_W, (g // cols) * CELL_H
        for y, v in enumerate(rows):
            for x in range(CELL_W):
                if v >> (CELL_W - 1 - x) & 1:
                    prev.putpixel((gx + x, gy + y), 255)
    prev = prev.resize((prev.width * 3, prev.height * 3), Image.NEAREST)
    p = os.path.join(ROOT, "tools/font_preview.png")
    prev.save(p)
    print("wrote", p)


if __name__ == "__main__":
    sys.exit(main())
