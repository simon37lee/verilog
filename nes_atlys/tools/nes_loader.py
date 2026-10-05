#!/usr/bin/env python3
"""fpga_nes 디버그 UART(hci) 로 .nes ROM 을 올리고 실행한다 (원래 Windows 용 NesDbg 의 LoadRom 과 같은 순서).

  nes_loader.py game.nes [-p /dev/ttyUSB0] [-b 115200]
  nes_loader.py --ping        연결만 확인 (ECHO 패킷)
  nes_loader.py game.nes --dump pk.bin   보낼 바이트열을 파일로 (Verilator 가상 모니터 --uart 용)

순서: DBG_BRK -> PPU_DISABLE -> CART_SET_CFG -> CPU_MEM_WR($8000~) -> PPU_MEM_WR($0000~)
      -> PC 를 리셋 벡터로 -> DBG_RUN
UART 형식: 8 데이터 비트, 홀수 패리티, 스톱 1 비트. 16 비트 값은 리틀 엔디언.
"""
import argparse
import struct
import sys
import time

OP_ECHO, OP_CPU_MEM_WR, OP_DBG_BRK, OP_DBG_RUN = 0x00, 0x02, 0x03, 0x04
OP_CPU_REG_WR, OP_QUERY_DBG_BRK, OP_PPU_MEM_WR = 0x06, 0x07, 0x0A
OP_PPU_DISABLE, OP_CART_SET_CFG = 0x0B, 0x0C
REG_PCL, REG_PCH = 0x00, 0x01
BLOCK = 0x400


def packets_for_rom(data):
    """ROM 을 올리는 패킷 바이트열 목록 (테스트벤치에서도 쓴다)."""
    from nes2hex import parse_ines
    prg, chr_, cfg = parse_ines(data, "rom")
    if data[4] == 1:
        prg = prg[:0x4000]                         # 16KB 는 한 번만 보낸다 (cart 가 미러링)
    pk = [bytes([OP_DBG_BRK]), bytes([OP_PPU_DISABLE]), bytes([OP_CART_SET_CFG]) + cfg]
    for off in range(0, len(prg), BLOCK):
        pk.append(struct.pack("<BHH", OP_CPU_MEM_WR, 0x8000 + off, BLOCK) + prg[off:off + BLOCK])
    for off in range(0, len(chr_), BLOCK):
        pk.append(struct.pack("<BHH", OP_PPU_MEM_WR, off, BLOCK) + chr_[off:off + BLOCK])
    reset = prg[len(prg) - 4:len(prg) - 2]
    pk.append(bytes([OP_CPU_REG_WR, REG_PCL, reset[0]]))
    pk.append(bytes([OP_CPU_REG_WR, REG_PCH, reset[1]]))
    pk.append(bytes([OP_DBG_RUN]))
    return pk


def open_port(port, baud):
    try:
        import serial
    except ImportError:
        sys.exit("pyserial 이 필요합니다: pip install pyserial")
    try:
        return serial.Serial(port, baud, bytesize=8, parity=serial.PARITY_ODD, stopbits=1, timeout=1.0)
    except serial.SerialException as e:
        sys.exit(f"{port} 를 열 수 없습니다: {e}\n"
                 "  (권한 문제면: sudo usermod -aG dialout $USER 후 다시 로그인)")


def ping(ser):
    msg = b"NES!"
    ser.reset_input_buffer()
    ser.write(struct.pack("<BH", OP_ECHO, len(msg)) + msg)
    got = ser.read(len(msg))
    return got == msg, got


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rom", nargs="?")
    ap.add_argument("-p", "--port", default="/dev/ttyUSB0")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("--ping", action="store_true", help="ECHO 로 연결만 확인")
    ap.add_argument("--dump", metavar="FILE", help="시리얼 대신 패킷 바이트열을 파일로 저장")
    a = ap.parse_args()

    if a.dump:
        if not a.rom:
            ap.error("--dump 에는 ROM 파일이 필요합니다")
        with open(a.rom, "rb") as f:
            pk = packets_for_rom(f.read())
        with open(a.dump, "wb") as f:
            f.write(b"".join(pk))
        print(f"{a.dump}: {sum(len(p) for p in pk)} B, {len(pk)} 패킷")
        return

    ser = open_port(a.port, a.baud)
    # CPU 가 실행 중이면 hci 는 DBG_BRK 만 받는다 -> 먼저 멈추고 ECHO 로 확인
    ser.write(bytes([OP_DBG_BRK]))
    time.sleep(0.05)
    ok, got = ping(ser)
    print(f"ECHO {'OK' if ok else 'FAIL'} ({got!r})")
    if a.ping or not a.rom:
        ser.write(bytes([OP_DBG_RUN]))
        sys.exit(0 if ok else 1)
    if not ok:
        sys.exit("보드가 응답하지 않습니다 (포트/보드레이트/비트스트림 확인)")

    with open(a.rom, "rb") as f:
        pk = packets_for_rom(f.read())
    total = sum(len(p) for p in pk)
    t0, sent = time.time(), 0
    for p in pk:
        ser.write(p)
        sent += len(p)
        print(f"\r전송 {sent * 100 // total:3d}% ({sent}/{total} B)", end="", flush=True)
    ser.flush()
    print(f"\n완료: {time.time() - t0:.1f} 초, 게임 시작")


if __name__ == "__main__":
    main()
