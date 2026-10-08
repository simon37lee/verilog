// ---------------------------------------------------------------------------
// vmon_mandel : mandel_system 실시간 가상 모니터 (Verilator + SDL2)
//
//   clk_core (기본 50 MHz) 와 clk_pix (25 MHz) 를 시간(ps) 기준으로 각각 돌리고,
//   픽셀 클럭마다 RGB / DE / VSYNC 를 받아 모니터처럼 화면을 복원한다.
//
//   기본은 자동 데모 (확대/축소 반복) + 더블 버퍼. --check 는 수동 모드로 처음 보기 영역을 검사한다.
//
//   검사 (--check): 리셋 직후 첫 렌더 프레임에서 프레임버퍼에 쓰는 값을 모두 가로채서
//   같은 고정소수점 연산을 하는 C++ 모델과 비트 단위로 비교한다 (W 는 빌드 때 -DMANDEL_W 로 맞춤).
//   렌더 시간, 평균 반복 횟수, 반복/초, 픽셀당 오버헤드 클럭도 보고한다.
//
//   옵션:
//     --scale N      창 확대 배율 (기본 1)
//     --no-limit     실시간(60 Hz) 제한 해제
//     --frames N     화면 N 프레임 후 종료
//     --renders N    렌더 N 프레임 완성 후 종료
//     --dump F.bmp   종료할 때 마지막 화면을 BMP 로 저장
//     --check        첫 렌더 프레임을 C++ 모델과 비교 (실패하면 종료 코드 1)
//     --core-mhz F   clk_core 주파수 (기본 1000 / CORE_DIV, RTL 의 CORE_HZ 와 같아야 렌더 시간이 맞다)
//     --manual       버튼 조작 모드로 시작 (보드의 SW7)
//     --single       단일 버퍼로 시작 (보드의 SW6)
//
//   조작:  M 자동 데모 / 수동 전환,  B 더블 / 단일 버퍼 전환
//          (수동) 화살표 이동 / Z 확대 / X 축소,  1~4 max_iter 255,127,63,31
//          SPACE 일시정지 / S 스크린샷 / ESC 종료
// ---------------------------------------------------------------------------
#include <SDL.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

#include "Vmandel_system.h"
#include "verilated.h"

// 빌드할 때 Makefile 이 rtl/vN/config.mk 값으로 넘겨 준다
#ifndef MANDEL_W
#define MANDEL_W 18
#endif
#ifndef MANDEL_VERSION
#define MANDEL_VERSION 1
#endif
#ifndef MANDEL_CORE_DIV
#define MANDEL_CORE_DIV 20
#endif

namespace {

constexpr int    MAX_W = 1920;
constexpr int    MAX_H = 1080;
constexpr double PIX_HZ = 25e6;
constexpr double REFRESH_HZ = PIX_HZ / (800.0 * 525.0);
constexpr int    FB_W = 320, FB_H = 240;

// ---- 고정소수점 기준 모델 (mandel_core / mandel_render 와 같은 연산) ----------
struct Model {
    static constexpr int W = MANDEL_W, FRAC = W - 4, CW = W + 8, CFRAC = FRAC + 8;

    static int64_t wrap(__int128 v, int bits) {     // 아래 bits 비트를 부호 확장
        const unsigned __int128 m = ((unsigned __int128)1 << bits) - 1;
        unsigned __int128 u = (unsigned __int128)v & m;
        if (u >> (bits - 1)) u |= ~m;
        return (int64_t)(__int128)u;
    }
    static int iterate(int64_t cr, int64_t ci, int max_iter) {
        int64_t zr = 0, zi = 0;
        const __int128 four = (__int128)4 << (2 * FRAC);
        for (int n = 0;; n++) {
            __int128 zr2 = (__int128)zr * zr, zi2 = (__int128)zi * zi, zri = (__int128)zr * zi;
            if (zr2 + zi2 > four || n == max_iter) return n;
            int64_t nr = wrap(wrap((zr2 - zi2) >> FRAC, W) + cr, W);
            int64_t ni = wrap(wrap(zri >> (FRAC - 1), W) + ci, W);
            zr = nr;
            zi = ni;
        }
    }
    // 리셋 직후 기본 보기 영역에서 (px, py) 의 반복 횟수 (프레임버퍼에 쓰는 값)
    static int pixel(int px, int py, int max_iter) {
        const int64_t step   = wrap(((__int128)7 << CFRAC) / 640, CW);
        const int64_t cen_re = -((int64_t)1 << (CFRAC - 1)), cen_im = 0;
        const int64_t x0  = wrap(cen_re - 160 * (__int128)step, CW);
        const int64_t top = wrap(cen_im + 120 * (__int128)step, CW);
        int64_t cr = wrap(x0 + (__int128)px * step, CW) >> 8;
        int64_t ci = wrap(top - (__int128)py * step, CW) >> 8;
        int n = iterate(cr, ci, max_iter);
        return n == max_iter ? 0 : n;
    }
};

// ---- 수신기 (모니터): 디지털 RGB + sync (640x480 은 sync 음극성) -------------
struct Monitor {
    std::vector<uint32_t> fb = std::vector<uint32_t>(MAX_W * MAX_H);
    int  px = 0, py = 0, width = 0, height = 0;
    bool prev_de = false, prev_vs_active = false, synced = false;

    bool push(uint8_t r, uint8_t g, uint8_t b, bool de, bool vs) {
        bool vs_active = !vs;
        bool frame_done = false;
        if (de) {
            if (synced && px < MAX_W && py < MAX_H)
                fb[py * MAX_W + px] = 0xFF000000u | (r << 16) | (g << 8) | b;
            px++;
        } else {
            if (prev_de) {
                width = px;
                px = 0;
                py++;
            }
            if (vs_active && !prev_vs_active) {
                if (synced && py > 0) {
                    height = py;
                    frame_done = true;
                }
                synced = true;
                py = 0;
            }
        }
        prev_de = de;
        prev_vs_active = vs_active;
        return frame_done;
    }
};

void save_bmp(const Monitor& m, const char* name) {
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormatFrom(
        (void*)m.fb.data(), m.width, m.height, 32, MAX_W * 4, SDL_PIXELFORMAT_ARGB8888);
    SDL_SaveBMP(s, name);
    SDL_FreeSurface(s);
    printf("saved %s\n", name);
}

double bcd_ms(uint32_t bcd) {      // 10 us 단위 BCD 6 자리 -> ms
    double v = 0;
    for (int k = 5; k >= 0; k--) v = v * 10 + ((bcd >> (4 * k)) & 0xF);
    return v / 100.0;
}

// ---- 첫 렌더 프레임 검사 -----------------------------------------------------
struct Checker {
    std::vector<int> got = std::vector<int>(FB_W * FB_H, -1);
    long writes = 0, dup = 0;
    bool active = true;

    void observe(const Vmandel_system* d) {
        if (!active) return;
        if (d->frames != 0) active = false;     // 마지막 픽셀 쓰기와 frames 증가는 같은 에지
        if (!d->fb_we) return;
        writes++;
        const unsigned a = d->fb_waddr % (FB_W * FB_H);     // 버퍼 번호는 무시
        if (got[a] >= 0) dup++;
        got[a] = d->fb_wdata;
    }
    // 반환: 오류 수. iters = 모델 기준 총 반복 횟수 (탈출 판정 횟수)
    long compare(int max_iter, uint64_t& iters) const {
        long bad = 0;
        iters = 0;
        for (int py = 0; py < FB_H; py++)
            for (int px = 0; px < FB_W; px++) {
                int exp = Model::pixel(px, py, max_iter);
                iters += exp == 0 ? max_iter : exp;
                int g = got[py * FB_W + px];
                if (g != exp) {
                    if (bad < 10) printf("  mismatch (%d,%d): hw %d, model %d\n", px, py, g, exp);
                    bad++;
                }
            }
        return bad;
    }
};

}  // namespace

int main(int argc, char** argv) {
    int    scale = 1;
    bool   limit = true, check = false, manual = false, single = false;
    long   max_frames = -1, max_renders = -1;
    double core_mhz = 1000.0 / MANDEL_CORE_DIV;
    const char* dump = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--scale") && i + 1 < argc)         scale = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-limit"))                 limit = false;
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc)   max_frames = atol(argv[++i]);
        else if (!strcmp(argv[i], "--renders") && i + 1 < argc)  max_renders = atol(argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc)     dump = argv[++i];
        else if (!strcmp(argv[i], "--check"))                    check = true;
        else if (!strcmp(argv[i], "--core-mhz") && i + 1 < argc) core_mhz = atof(argv[++i]);
        else if (!strcmp(argv[i], "--manual"))                   manual = true;
        else if (!strcmp(argv[i], "--single"))                   single = true;
    }
    if (check) manual = true;      // 검사는 처음 보기 영역 그대로
    Verilated::commandArgs(argc, argv);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window*   win = nullptr;
    SDL_Renderer* ren = nullptr;
    SDL_Texture*  tex = nullptr;
    int tex_w = 0, tex_h = 0;

    auto dut = std::make_unique<Vmandel_system>();
    Monitor mon;
    Checker chk;

    // ---- 클럭: 상승 에지만 이벤트로 처리 (설계에 negedge 로직 없음) ---------------
    //   Verilator 는 직전 eval() 에서 본 값과 비교해 에지를 찾으므로, 어떤 클럭이 다시
    //   올라가기 전에 그 클럭의 0 이 한 번은 eval() 로 관측되어야 한다 (dma_display 와 같은 방식).
    enum { PIX = 0, CORE = 1, NCLK = 2 };
    CData*  sig[NCLK]  = {&dut->clk_pix, &dut->clk_core};
    int64_t half[NCLK] = {20000, (int64_t)(5e5 / core_mhz + 0.5)};
    int64_t rise_ps[NCLK], last_rise_ps[NCLK], last_eval_ps = 0, now_ps = 0;
    for (int i = 0; i < NCLK; i++) {
        rise_ps[i]      = half[i];
        last_rise_ps[i] = -2 * half[i];
    }

    auto step = [&]() -> bool {
        int64_t t = rise_ps[0] < rise_ps[1] ? rise_ps[0] : rise_ps[1];
        now_ps = t;
        bool need_low_eval = false;
        for (int i = 0; i < NCLK; i++) {
            if (rise_ps[i] == t) {
                *sig[i] = 0;
                if (last_eval_ps < t - half[i]) need_low_eval = true;
            } else {
                *sig[i] = (t < last_rise_ps[i] + half[i]);
            }
        }
        if (need_low_eval) dut->eval();
        bool rise[NCLK];
        for (int i = 0; i < NCLK; i++) {
            rise[i] = (rise_ps[i] == t);
            if (rise[i]) {
                *sig[i]         = 1;
                last_rise_ps[i] = t;
                rise_ps[i]     += 2 * half[i];
            }
        }
        dut->eval();
        last_eval_ps = t;
        if (rise[CORE] && check) chk.observe(dut.get());
        return rise[PIX];
    };

    dut->clk_pix = dut->clk_core = 0;
    dut->rst = 1;
    dut->btn_l = dut->btn_r = dut->btn_u = dut->btn_d = dut->btn_c = 0;
    dut->sw_zoom_out = 0;
    dut->sw_iter = 0;
    dut->sw_manual = manual;
    dut->sw_single = single;
    dut->eval();
    while (now_ps < 1000000) step();
    dut->rst = 0;

    const uint64_t perf_freq   = SDL_GetPerformanceFrequency();
    const double   frame_ticks = perf_freq / REFRESH_HZ;
    uint64_t next_frame  = SDL_GetPerformanceCounter();
    uint64_t stat_start  = next_frame;
    long     stat_frames = 0, frames = 0;
    bool     running = true, paused = false;

    while (running) {
        if (!paused) {
            bool done = false;
            while (!done) {
                if (step())
                    done = mon.push(dut->r, dut->g, dut->b, dut->de, dut->vsync);
            }
            frames++;
            stat_frames++;

            if (mon.width != tex_w || mon.height != tex_h) {
                tex_w = mon.width;
                tex_h = mon.height;
                if (tex) SDL_DestroyTexture(tex);
                if (!win) {
                    win = SDL_CreateWindow("Mandelbrot Virtual Monitor", SDL_WINDOWPOS_CENTERED,
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
            SDL_UpdateTexture(tex, nullptr, mon.fb.data(), MAX_W * sizeof(uint32_t));
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
                    case SDLK_1: case SDLK_2: case SDLK_3: case SDLK_4:
                        dut->sw_iter = e.key.keysym.sym - SDLK_1;
                        printf("max_iter = %d\n", 255 >> dut->sw_iter);
                        break;
                    case SDLK_m:
                        dut->sw_manual ^= 1;
                        printf("%s\n", dut->sw_manual ? "manual (buttons)" : "auto demo");
                        break;
                    case SDLK_b:
                        dut->sw_single ^= 1;
                        printf("%s buffer\n", dut->sw_single ? "single" : "double");
                        break;
                    case SDLK_s: {
                        char name[64];
                        snprintf(name, sizeof name, "vmon_%ld.bmp", frames);
                        save_bmp(mon, name);
                        break;
                    }
                }
            }
        }
        // 버튼은 누르고 있는 동안 1 (보드처럼)
        const Uint8* ks = SDL_GetKeyboardState(nullptr);
        dut->btn_l = ks[SDL_SCANCODE_LEFT];
        dut->btn_r = ks[SDL_SCANCODE_RIGHT];
        dut->btn_u = ks[SDL_SCANCODE_UP];
        dut->btn_d = ks[SDL_SCANCODE_DOWN];
        dut->btn_c = ks[SDL_SCANCODE_Z] || ks[SDL_SCANCODE_X];
        dut->sw_zoom_out = ks[SDL_SCANCODE_X];

        if (max_frames > 0 && frames >= max_frames) running = false;
        if (max_renders > 0 && dut->frames >= max_renders) running = false;

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
            char title[260];
            snprintf(title, sizeof title,
                     "Mandelbrot v%d  |  %.1f fps (%.0f%% of real-time)  |  render %.2f ms  |  %u frames rendered  |  %s, %s buffer%s",
                     MANDEL_VERSION, fps, 100.0 * fps / REFRESH_HZ, bcd_ms(dut->perf_bcd), (unsigned)dut->frames,
                     dut->sw_manual ? "manual" : "auto", dut->sw_single ? "single" : "double",
                     paused ? "  [PAUSED]" : "");
            SDL_SetWindowTitle(win, title);
            if (max_frames > 0 || max_renders > 0) printf("%s\n", title);
            stat_start  = now;
            stat_frames = 0;
        }
    }

    printf("simulated %.3f s of hardware time, %u frames rendered, last render %.2f ms\n",
           now_ps / 1e12, (unsigned)dut->frames, bcd_ms(dut->perf_bcd));
    if (dump && tex_w > 0) save_bmp(mon, dump);

    int rc = 0;
    if (check) {
        if (dut->frames < 1) {
            printf("CHECK FAIL: first render frame did not finish\n");
            rc = 1;
        } else {
            uint64_t iters;
            long bad = chk.compare(255, iters);
            const double npix = FB_W * FB_H;
            // 첫 프레임 렌더 시간은 perf_bcd 가 다음 프레임 끝까지 유지되므로, frames == 1 일 때 읽은 값이
            // 아니라도 같은 보기 영역 (버튼 안 누름) 이면 같은 값이다
            const double ms     = bcd_ms(dut->perf_bcd);
            const double cycles = ms * 1e-3 * core_mhz * 1e6;
            printf("model: %llu iterations, avg %.1f per pixel\n", (unsigned long long)iters, iters / npix);
            printf("hw   : %.2f ms @ %.0f MHz = %.0f cycles -> %.2f M iter/s, %.2f cycles/pixel overhead\n",
                   ms, core_mhz, cycles, ms > 0 ? iters / (ms * 1e3) : 0.0, (cycles - iters) / npix);
            const bool ok = !bad && chk.writes == FB_W * FB_H && !chk.dup;
            // check-all 이 모으는 한 줄 요약
            printf("RESULT v%d: %s  W=%d  clk_core %.1f MHz  render %.2f ms  %.2f M iter/s  %.2f cycles/iter\n",
                   MANDEL_VERSION, ok ? "PASS" : "FAIL", MANDEL_W, core_mhz, ms,
                   ms > 0 ? iters / (ms * 1e3) : 0.0, iters ? cycles / iters : 0.0);
            if (!ok) {
                printf("CHECK FAIL: %ld mismatches, %ld writes (expected %d), %ld duplicate addresses\n",
                       bad, chk.writes, FB_W * FB_H, chk.dup);
                rc = 1;
            } else {
                printf("CHECK PASS: all %d pixels match the fixed-point model (W=%d)\n", FB_W * FB_H, MANDEL_W);
            }
        }
    }

    dut->final();
    if (tex) SDL_DestroyTexture(tex);
    if (ren) SDL_DestroyRenderer(ren);
    if (win) SDL_DestroyWindow(win);
    SDL_Quit();
    return rc;
}
