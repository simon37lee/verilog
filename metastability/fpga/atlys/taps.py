#!/usr/bin/env python3
# 타이밍 리포트(TS_tdc)에서 측정 회로별 탭 도착 시간을 뽑아 탭 지연과 예상 봉우리 위치를 보여준다.
import re, sys
t = open(sys.argv[1] if len(sys.argv) > 1 else 'build/meta_lab_atlys.twr').read()
sec = t[t.find('TS_tdc'):]
sec = sec[:sec.find('Derived Constraint') if 'Derived Constraint' in sec else len(sec)]
d = {}
for dst, dl in re.findall(r'Destination:\s+(\S+).*?Data Path Delay:\s+([\d.]+)ns', sec, re.S):
    m = re.search(r'u_det_(\w)/u_chain/taps_(\d+)', dst)
    if m: d[(m.group(1), int(m.group(2)))] = float(dl)
for c in 'ab':
    t0, t255 = d[(c, 0)], d[(c, 255)]
    tap = (t255 - t0) / 255
    print(f"chain {c.upper()}: tap0 {t0:.3f} ns  tap255 {t255:.3f} ns  -> TAP_X10_{c.upper()} = {round(tap * 1e4)}"
          f"  (expected peak bin at 4.0 ns, slow corner ~{255 - min(255, max(0, int((4.0 - t0) / tap)))})")
