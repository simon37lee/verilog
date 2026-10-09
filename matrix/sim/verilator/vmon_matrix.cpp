// ---------------------------------------------------------------------------
// vmon_matrix : matrix_system 실시간 가상 모니터 (Verilator + SDL2)
//
//   픽셀 클럭 (74.0 MHz) 마다 RGB / DE / VSYNC 를 받아 모니터처럼 화면을 복원한다.
//
//   검사 (--check): 셀 RAM 쓰기 (cell_we / cell_waddr / cell_wdata) 를 가로채서 C++ 쪽에 같은 RAM 을 두고,
//   화면 한 장이 끝날 때마다 그 RAM + 글꼴 (glyphs.h) + 팔레트로 그린 그림과 화면 전체를 비교한다.
//   엔진이 화면 표시 중 (첫 DE ~ 마지막 줄 끝) 에 셀 RAM 을 쓰면 규칙 위반으로 센다 (vblank 에만 써야 함).
//
//   옵션:
//     --scale N      창 확대 배율 (기본 1)
//     --no-limit     실시간 (60 Hz) 제한 해제 (어차피 시뮬레이션이 실시간보다 느리다)
//     --frames N     화면 N 프레임 후 종료
//     --dump F.bmp   종료할 때 마지막 화면을 BMP 로 저장
//     --check        프레임마다 화면을 모델과 비교 (실패하면 종료 코드 1)
//
//   조작:  SPACE 일시정지 / S 스크린샷 / ESC 종료
// ---------------------------------------------------------------------------
#include <SDL.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

#include "Vmatrix_system.h"
#include "verilated.h"
#include "glyphs.h"

#ifndef MATRIX_VERSION
#define MATRIX_VERSION 1
#endif

namespace {

constexpr int    SCR_W = 1280, SCR_H = 720;
constexpr int    COLS = SCR_W / GLYPH_W, ROWS = SCR_H / GLYPH_H;     // 80 x 30
constexpr double PIX_HZ = 74.0e6;
constexpr double REFRESH_HZ = PIX_HZ / (1650.0 * 750.0);

// matrix_display.v 의 palette() 와 같다
uint32_t palette(int i) {
    const int w = i >= 56 ? ((i & 7) << 5) | 31 : i;
    const int r = i >= 56 ? w : 0, g = (i << 2) | 3, b = w;
    return (r << 16) | (g << 8) | b;
}

// ---- 수신기 (모니터): 디지털 RGB + sync (720p 는 sync 양극성) ----------------------
struct Monitor {
    std::vector<uint32_t> fb = std::vector<uint32_t>(SCR_W * SCR_H);
    int  px = 0, py = 0, width = 0, height = 0;
    bool prev_de = false, prev_vs = false, synced = false;
    bool active = false;        // 이번 프레임 첫 DE ~ 마지막 줄 끝

    // 반환: 1 = 이번 프레임 첫 DE, 2 = 프레임 끝 (vsync 시작)
    int push(uint8_t r, uint8_t g, uint8_t b, bool de, bool vs) {
        int ev = 0;
        if (de) {
            if (!active) { active = true; ev = 1; }
            if (synced && px < SCR_W && py < SCR_H)
                fb[py * SCR_W + px] = 0xFF000000u | (r << 16) | (g << 8) | b;
            px++;
        } else {
            if (prev_de) {
                width = px;
                px = 0;
                py++;
                if (py >= SCR_H) active = false;    // 마지막 줄이 끝나면 vblank
            }
            if (vs && !prev_vs) {
                if (synced && py > 0) {
                    height = py;
                    ev = 2;
                }
                synced = true;
                active = false;
                py = 0;
            }
        }
        prev_de = de;
        prev_vs = vs;
        return ev;
    }
};

void save_bmp(const Monitor& m, const char* name) {
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormatFrom(
        (void*)m.fb.data(), m.width, m.height, 32, SCR_W * 4, SDL_PIXELFORMAT_ARGB8888);
    SDL_SaveBMP(s, name);
    SDL_FreeSurface(s);
    printf("saved %s\n", name);
}

// ---- 검사기: 셀 RAM 거울 + 기대 화면 ---------------------------------------------------
struct Checker {
    std::vector<uint16_t> ram  = std::vector<uint16_t>(4096, 0);    // 하드웨어 BRAM 도 0 으로 시작
    std::vector<uint16_t> snap = std::vector<uint16_t>(4096, 0);    // 이번 프레임 첫 DE 때의 RAM
    long writes = 0, bad_writes = 0, frames = 0, bad_frames = 0, bad_pixels = 0, lit = 0;

    void observe(const Vmatrix_system* d, bool active) {
        if (!d->cell_we) return;
        writes++;
        if (active && bad_writes++ < 5) printf("  write during active video: addr %d\n", d->cell_waddr);
        ram[d->cell_waddr & 4095] = d->cell_wdata & 0xFFF;
    }
    void frame_start() { snap = ram; }

    uint32_t expect(int x, int y) const {
        const uint16_t c = snap[(y / GLYPH_H) * COLS + x / GLYPH_W];
        const int i = c >> 6, code = c & 63;
        const bool on = i != 0 && (GLYPHS[code][y % GLYPH_H] >> (15 - x % GLYPH_W) & 1);
        return on ? palette(i) : 0;
    }
    void frame_end(const Monitor& m) {
        frames++;
        long bad = 0;
        if (m.width != SCR_W || m.height != SCR_H) {
            printf("  frame %ld: size %dx%d\n", frames, m.width, m.height);
            bad = 1;
        } else {
            for (int y = 0; y < SCR_H; y++)
                for (int x = 0; x < SCR_W; x++) {
                    const uint32_t want = expect(x, y), got = m.fb[y * SCR_W + x] & 0xFFFFFF;
                    if (want) lit++;
                    if (want != got) {
                        if (bad < 5) printf("  frame %ld mismatch (%d,%d): got %06X want %06X\n", frames, x, y, got, want);
                        bad++;
                    }
                }
        }
        if (bad) bad_frames++;
        bad_pixels += bad;
    }
};

}  // namespace

int main(int argc, char** argv) {
    int  scale = 1;
    bool limit = true, check = false;
    long max_frames = -1;
    const char* dump = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--scale") && i + 1 < argc)       scale = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-limit"))               limit = false;
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) max_frames = atol(argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc)   dump = argv[++i];
        else if (!strcmp(argv[i], "--check"))                  check = true;
    }
    Verilated::commandArgs(argc, argv);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window*   win = nullptr;
    SDL_Renderer* ren = nullptr;
    SDL_Texture*  tex = nullptr;
    int tex_w = 0, tex_h = 0;

    auto dut = std::make_unique<Vmatrix_system>();
    Monitor mon;
    Checker chk;

    auto tick = [&]() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    };

    dut->clk = 0;
    dut->rst = 1;
    dut->eval();
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;

    const uint64_t perf_freq   = SDL_GetPerformanceFrequency();
    const double   frame_ticks = perf_freq / REFRESH_HZ;
    uint64_t next_frame  = SDL_GetPerformanceCounter();
    uint64_t stat_start  = next_frame;
    long     stat_frames = 0, frames = 0;
    bool     running = true, paused = false;

    while (running) {
        if (!paused) {
            for (;;) {
                tick();
                if (check) chk.observe(dut.get(), mon.active);
                const int ev = mon.push(dut->r, dut->g, dut->b, dut->de, dut->vsync);
                if (ev == 1 && check) chk.frame_start();
                if (ev == 2) break;
            }
            if (check) chk.frame_end(mon);
            frames++;
            stat_frames++;

            if (mon.width != tex_w || mon.height != tex_h) {
                tex_w = mon.width;
                tex_h = mon.height;
                if (tex) SDL_DestroyTexture(tex);
                if (!win) {
                    win = SDL_CreateWindow("Matrix Virtual Monitor", SDL_WINDOWPOS_CENTERED,
                                           SDL_WINDOWPOS_CENTERED, tex_w * scale, tex_h * scale,
                                           SDL_WINDOW_RESIZABLE);
                    ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
                    if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
                } else {
                    SDL_SetWindowSize(win, tex_w * scale, tex_h * scale);
                }
                SDL_RenderSetLogicalSize(ren, tex_w, tex_h);
                tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, tex_w, tex_h);
                printf("[virtual monitor] signal detected: %dx%d\n", tex_w, tex_h);
            }
            SDL_UpdateTexture(tex, nullptr, mon.fb.data(), SCR_W * sizeof(uint32_t));
        }

        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, nullptr, nullptr);
        SDL_RenderPresent(ren);

        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = false;
            else if (e.type == SDL_KEYDOWN) {
                switch (e.key.keysym.sym) {
                    case SDLK_ESCAPE: running = false; break;
                    case SDLK_SPACE:  paused = !paused; break;
                    case SDLK_s: {
                        char name[64];
                        snprintf(name, sizeof name, "vmon_%ld.bmp", frames);
                        save_bmp(mon, name);
                        break;
                    }
                }
            }
        }

        if (max_frames > 0 && frames >= max_frames) running = false;

        uint64_t now = SDL_GetPerformanceCounter();
        if (limit) {
            next_frame += (uint64_t)frame_ticks;
            if (now < next_frame)
                SDL_Delay((uint32_t)((next_frame - now) * 1000 / perf_freq));
            else
                next_frame = now;
        }

        double elapsed = (double)(now - stat_start) / perf_freq;
        if (elapsed >= 1.0) {
            double fps = stat_frames / elapsed;
            char title[200];
            snprintf(title, sizeof title, "Matrix v%d  |  %.1f fps (%.0f%% of real-time)  |  frame %u%s",
                     MATRIX_VERSION, fps, 100.0 * fps / REFRESH_HZ, (unsigned)dut->frames,
                     paused ? "  [PAUSED]" : "");
            SDL_SetWindowTitle(win, title);
            if (max_frames > 0) printf("%s\n", title);
            stat_start  = now;
            stat_frames = 0;
        }
    }

    if (dump && tex_w > 0) save_bmp(mon, dump);

    int rc = 0;
    if (check) {
        const bool ok = chk.bad_frames == 0 && chk.bad_writes == 0 && chk.writes > 0;
        printf("CHECK %s: %ld frames compared, %ld bad frames (%ld pixels), %ld cell writes (%ld during active video), %.1f%% lit\n",
               ok ? "PASS" : "FAIL", chk.frames, chk.bad_frames, chk.bad_pixels, chk.writes, chk.bad_writes,
               chk.frames ? 100.0 * chk.lit / (chk.frames * (double)SCR_W * SCR_H) : 0.0);
        printf("RESULT v%d: %s\n", MATRIX_VERSION, ok ? "PASS" : "FAIL");
        rc = ok ? 0 : 1;
    }
    if (ren) SDL_DestroyRenderer(ren);
    if (win) SDL_DestroyWindow(win);
    SDL_Quit();
    dut->final();
    return rc;
}
