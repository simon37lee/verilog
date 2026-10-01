"""
가상 모니터 화면 뷰어

tb_virtual_monitor 가 저장한 PPM 프레임을 창에 띄운다.

사용법:
    python3 tools/view_frames.py frame_0.ppm [frame_1.ppm ...]
    python3 tools/view_frames.py --png out.png frame_0.ppm   # 창 없이 PNG 로 저장

조작:
    SPACE   : 재생 / 일시정지 (0.1 s 간격, 여러 프레임일 때 자동 재생)
    ← / →   : 이전 / 다음 프레임
    1 / 2   : 1배 / 2배 확대
    S       : 현재 프레임을 PNG 로 저장
    ESC     : 종료
"""
import os
import sys

import pygame

BEZEL = 24
INFO_H = 28


def load_ppm(path):
    """P3(텍스트) / P6(바이너리) PPM 을 pygame Surface 로 읽는다."""
    with open(path, "rb") as f:
        data = f.read()

    tokens, pos = [], 0
    while len(tokens) < 4:   # magic, width, height, maxval
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos)
            continue
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        tokens.append(data[start:pos])
    magic, w, h, maxval = tokens[0], int(tokens[1]), int(tokens[2]), int(tokens[3])

    if magic == b"P6":
        rgb = data[pos + 1:pos + 1 + w * h * 3]
    elif magic == b"P3":
        rgb = bytes(int(v) * 255 // maxval for v in data[pos:].split()[: w * h * 3])
    else:
        raise ValueError(f"{path}: unsupported PPM type {magic!r}")
    return pygame.image.frombuffer(rgb, (w, h), "RGB").copy()


def main():
    args = sys.argv[1:]
    png_out = None
    if args[:1] == ["--png"]:
        png_out, args = args[1], args[2:]
    if not args:
        print(__doc__)
        sys.exit(1)

    if png_out:
        pygame.image.save(load_ppm(args[0]), png_out)
        print(f"saved {png_out}")
        return

    pygame.init()
    frames = [load_ppm(p) for p in args]
    font = pygame.font.SysFont("consolas", 16, bold=True)
    idx, scale = 0, 1
    playing = len(frames) > 1
    PLAY_EVENT = pygame.USEREVENT + 1
    pygame.time.set_timer(PLAY_EVENT, 100)   # 0.1 s

    def make_window():
        w, h = frames[idx].get_size()
        return pygame.display.set_mode((w * scale + BEZEL * 2, h * scale + BEZEL * 2 + INFO_H))

    screen = make_window()
    clock = pygame.time.Clock()
    running = True
    while running:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                running = False
            elif e.type == PLAY_EVENT and playing:
                idx = (idx + 1) % len(frames)
            elif e.type == pygame.KEYDOWN:
                if e.key == pygame.K_ESCAPE:
                    running = False
                elif e.key == pygame.K_SPACE:
                    playing = not playing
                elif e.key == pygame.K_RIGHT:
                    idx = (idx + 1) % len(frames)
                    screen = make_window()
                elif e.key == pygame.K_LEFT:
                    idx = (idx - 1) % len(frames)
                    screen = make_window()
                elif e.key in (pygame.K_1, pygame.K_2):
                    scale = 1 if e.key == pygame.K_1 else 2
                    screen = make_window()
                elif e.key == pygame.K_s:
                    out = os.path.splitext(args[idx])[0] + ".png"
                    pygame.image.save(frames[idx], out)
                    print(f"saved {out}")

        img = frames[idx]
        w, h = img.get_size()
        pygame.display.set_caption(f"Virtual Monitor - {os.path.basename(args[idx])}")

        # 모니터 베젤 + 화면 + 상태 표시줄
        screen.fill((40, 40, 45))
        pygame.draw.rect(screen, (15, 15, 15), (BEZEL - 4, BEZEL - 4, w * scale + 8, h * scale + 8))
        screen.blit(pygame.transform.scale(img, (w * scale, h * scale)), (BEZEL, BEZEL))
        state = "PLAY" if playing else "PAUSE"
        info = f"{w}x{h}   frame {idx + 1}/{len(frames)}   x{scale}   {state}"
        screen.blit(font.render(info, True, (120, 220, 120)), (BEZEL, h * scale + BEZEL + 8))
        pygame.draw.circle(screen, (60, 220, 90), (w * scale + BEZEL - 8, h * scale + BEZEL + 16), 5)

        pygame.display.flip()
        clock.tick(30)
    pygame.quit()


if __name__ == "__main__":
    main()
