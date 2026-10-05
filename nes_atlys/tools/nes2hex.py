#!/usr/bin/env python3
"""iNES(.nes) 파일을 fpga_nes 카트리지 BRAM 초기값으로 변환한다.

  nes2hex.py game.nes  OUTDIR   -> OUTDIR/prg.hex (32KB), OUTDIR/chr.hex (8KB), OUTDIR/rom_cfg.vh
  nes2hex.py --blank   OUTDIR   -> ROM 없이 빌드할 때: $8000 에서 제자리 루프만 도는 더미

rom_cfg.vh 에는 iNES 헤더 4..8 바이트 (hci 의 CART_SET_CFG 와 같은 값) 와 hex 파일의 절대 경로가
localparam 으로 들어간다 (FPGA 최상위가 `include 한다).
fpga_nes 는 맵퍼 0 (NROM) 만 지원한다: PRG 16/32KB, CHR-ROM 8KB, 가로/세로 미러링.
"""
import argparse
import os
import sys


def parse_ines(data, name):
    if len(data) < 16 or data[0:4] != b"NES\x1a":
        sys.exit(f"{name}: iNES 헤더가 아닙니다")
    prg_banks, chr_banks, f6, f7 = data[4], data[5], data[6], data[7]
    mapper = (f6 >> 4) | (f7 & 0xF0)
    errs = []
    if mapper != 0:
        errs.append(f"맵퍼 {mapper} (NROM = 0 만 지원)")
    if prg_banks not in (1, 2):
        errs.append(f"PRG {prg_banks * 16}KB (16/32KB 만 지원)")
    if chr_banks != 1:
        errs.append(f"CHR-ROM {chr_banks * 8}KB (8KB 만 지원, CHR-RAM 미지원)")
    if f6 & 0x08:
        errs.append("4-screen 미러링 미지원")
    if errs:
        sys.exit(f"{name}: 지원하지 않는 ROM - " + ", ".join(errs))
    off = 16 + (512 if f6 & 0x04 else 0)          # trainer 가 있으면 건너뜀
    prg = data[off:off + prg_banks * 0x4000]
    chr_ = data[off + len(prg):off + len(prg) + 0x2000]
    if len(prg) != prg_banks * 0x4000 or len(chr_) != 0x2000:
        sys.exit(f"{name}: 파일 길이가 헤더와 맞지 않습니다")
    if prg_banks == 1:
        prg = prg + prg                             # 16KB 는 $C000 쪽에도 미러 (cart 는 A14 를 무시)
    cfg = bytes(data[4:9])
    return prg, chr_, cfg


def blank_rom():
    prg = bytearray(0x8000)
    prg[0:3] = b"\x4c\x00\x80"                     # $8000: JMP $8000
    prg[0x7FFA:0x8000] = b"\x00\x80" * 3           # NMI / RESET / IRQ -> $8000
    chr_ = bytes(0x2000)
    cfg = bytes([2, 1, 0, 0, 0])
    return bytes(prg), chr_, cfg


def write_hex(path, data):
    with open(path, "w") as f:
        f.write("\n".join(f"{b:02x}" for b in data))
        f.write("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rom", nargs="?", help=".nes 파일")
    ap.add_argument("outdir")
    ap.add_argument("--blank", action="store_true", help="ROM 없이 더미 생성")
    a = ap.parse_args()

    if a.blank:
        prg, chr_, cfg = blank_rom()
        label = "(blank)"
    else:
        if not a.rom:
            ap.error("ROM 파일이나 --blank 를 지정하세요")
        with open(a.rom, "rb") as f:
            prg, chr_, cfg = parse_ines(f.read(), a.rom)
        label = os.path.basename(a.rom)

    os.makedirs(a.outdir, exist_ok=True)
    write_hex(os.path.join(a.outdir, "prg.hex"), prg)
    write_hex(os.path.join(a.outdir, "chr.hex"), chr_)
    cfg_hex = cfg.hex()
    with open(os.path.join(a.outdir, "rom_cfg.vh"), "w") as f:
        f.write(f"// nes2hex.py 가 생성: {label}\n")
        f.write(f"localparam [39:0] ROM_CART_CFG = 40'h{cfg_hex};\n")
        f.write(f'localparam ROM_PRG_FILE = "{os.path.abspath(os.path.join(a.outdir, "prg.hex"))}";\n')
        f.write(f'localparam ROM_CHR_FILE = "{os.path.abspath(os.path.join(a.outdir, "chr.hex"))}";\n')
    reset = prg[0x7FFC] | (prg[0x7FFD] << 8)
    print(f"{label}: PRG {cfg[0] * 16}KB, CHR 8KB, "
          f"{'세로' if cfg[2] & 1 else '가로'} 미러링, RESET=${reset:04X}, cfg=40'h{cfg_hex}")


if __name__ == "__main__":
    main()
