// ---------------------------------------------------------------------------
// model_view : C++ 기준 모델 실시간 뷰어 (SDL2, CPU 멀티스레드)
//
//   Verilator 시뮬레이션 (sim/verilator) 은 클럭마다 회로 전체를 계산해서 느리다 (v4 는 실시간의 약 2 %).
//   이 뷰어는 같은 고정소수점 모델 (mandel_model.h) 로 픽셀 값만 계산하고, 보기 영역도 mandel_render 와
//   같은 순서로 갱신하므로 FPGA 와 프레임마다 같은 그림을 실시간으로 보여 준다.
//   (모델이 RTL 과 비트 단위로 같다는 것은 sim/verilator 의 make check 가 확인한다)
//
//   속도: 기본은 FPGA 이론 속도에 맞춘다. 렌더 1 프레임 = max(반복 수 / PAR, 76800) 클럭 @ CORE_HZ
//         (PAR = 클럭당 반복 수 = 링 수, rtl/vN/config.mk). 실제 FPGA 는 이보다 조금 느리다
//         (기본 화면에서 v3 +15 %, v4 +6 %). 화면은 FPGA 처럼 60 fps 가 상한 (더블 버퍼 + vsync)
//         --no-pace 면 CPU 가 계산할 수 있는 만큼 빨리
//
//   옵션: --scale N (기본 320x240 은 2, 그 이상은 1), --threads N, --no-pace, --manual, --sw-iter N,
//         --frames N (렌더 N 프레임 후 종료), --dump F.bmp (종료할 때 화면 저장)
//   조작: M 자동 데모 / 수동,  (수동) 화살표 이동 Z 확대 X 축소,  1~4 max_iter,
//         P 속도 맞춤 켜기/끄기, R 처음 화면, SPACE 일시정지, S 스크린샷, ESC 종료
// ---------------------------------------------------------------------------
#include <SDL.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

#include "mandel_model.h"

#ifndef MANDEL_VERSION
#define MANDEL_VERSION 4
#endif
#ifndef MANDEL_CORE_DIV
#define MANDEL_CORE_DIV 7
#endif
#ifndef MANDEL_PAR
#define MANDEL_PAR 1
#endif
#ifndef MANDEL_PALETTE
#define MANDEL_PALETTE "../../rtl/common/palette_rom.v"
#endif

using namespace mandel;
using Clock = std::chrono::steady_clock;

namespace {

// 한 프레임 계산: 줄 단위로 스레드에 나눠 준다. 반환 = 총 반복 (탈출 판정) 횟수
uint64_t render(const View& v, int max_iter, int nthreads, std::vector<uint8_t>& fb) {
    const int64_t x0 = v.x0(), top = v.top(), step = v.step;
    std::atomic<int>      next_row(0);
    std::atomic<uint64_t> total(0);
    auto work = [&]() {
        uint64_t iters = 0;
        for (int py; (py = next_row++) < FB_H;) {
            for (int px = 0; px < FB_W; px++) {
                const int n = pixel(x0, top, step, px, py, max_iter);
                iters += n == 0 ? max_iter : n;
                fb[py * FB_W + px] = (uint8_t)fold(n);
            }
        }
        total += iters;
    };
    std::vector<std::thread> pool;
    for (int i = 1; i < nthreads; i++) pool.emplace_back(work);
    work();
    for (auto& t : pool) t.join();
    return total;
}

}  // namespace

int main(int argc, char** argv) {
    int   scale = FB_W >= 640 ? 1 : 2, nthreads = (int)std::max(1u, std::thread::hardware_concurrency());
    bool  pace = true, manual = false;
    int   sw_iter = 0;
    long  max_frames = -1;
    const char* dump = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--scale") && i + 1 < argc)         scale = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc)  nthreads = std::max(1, atoi(argv[++i]));
        else if (!strcmp(argv[i], "--no-pace"))                  pace = false;
        else if (!strcmp(argv[i], "--manual"))                   manual = true;
        else if (!strcmp(argv[i], "--sw-iter") && i + 1 < argc)  sw_iter = atoi(argv[++i]) & 3;
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc)   max_frames = atol(argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc)     dump = argv[++i];
    }

    uint32_t pal[256];
    if (!load_palette(MANDEL_PALETTE, pal)) {
        fprintf(stderr, "cannot read palette %s\n", MANDEL_PALETTE);
        return 1;
    }

    const double core_hz = 1e9 / MANDEL_CORE_DIV;
    printf("model_view v%d: W=%d IW=%d, FPGA %d iter/clock @ %.1f MHz, %d threads\n",
           MANDEL_VERSION, W, IW, MANDEL_PAR, core_hz / 1e6, nthreads);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window*   win = SDL_CreateWindow("model_view", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                         FB_W * scale, FB_H * scale, 0);
    SDL_Renderer* ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_PRESENTVSYNC);
    SDL_Texture*  tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, FB_W, FB_H);
    if (!win || !ren || !tex) {
        fprintf(stderr, "SDL: %s\n", SDL_GetError());
        return 1;
    }

    View v;
    std::vector<uint8_t>  fb(FB_W * FB_H);
    std::vector<uint32_t> rgb(FB_W * FB_H);
    bool   running = true, paused = false;
    long   frames = 0, win_frames = 0;
    double cpu_ms = 0, fpga_ms = 0;
    auto   win_start = Clock::now();
    auto   next_frame = Clock::now();

    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = false;
            else if (e.type == SDL_KEYDOWN) {
                switch (e.key.keysym.sym) {
                    case SDLK_ESCAPE: running = false; break;
                    case SDLK_SPACE:  paused = !paused; break;
                    case SDLK_m:
                        manual = !manual;
                        printf("%s\n", manual ? "manual (buttons)" : "auto demo");
                        break;
                    case SDLK_p:
                        pace = !pace;
                        printf("pace to FPGA: %s\n", pace ? "on" : "off");
                        break;
                    case SDLK_r: v.reset(); break;
                    case SDLK_1: case SDLK_2: case SDLK_3: case SDLK_4:
                        sw_iter = e.key.keysym.sym - SDLK_1;
                        printf("max_iter = %d\n", ((1 << IW) - 1) >> sw_iter);
                        break;
                    case SDLK_s: {
                        char name[64];
                        snprintf(name, sizeof name, "model_%ld.bmp", frames);
                        SDL_Surface* s = SDL_CreateRGBSurfaceWithFormatFrom(
                            rgb.data(), FB_W, FB_H, 32, FB_W * 4, SDL_PIXELFORMAT_ARGB8888);
                        SDL_SaveBMP(s, name);
                        SDL_FreeSurface(s);
                        printf("saved %s\n", name);
                        break;
                    }
                    default: break;
                }
            }
        }

        if (!paused) {
            // 보드처럼: 버튼은 렌더 프레임마다 한 번 (S_VIEW) 본다
            const Uint8* ks = SDL_GetKeyboardState(nullptr);
            v.update(!manual, ks[SDL_SCANCODE_LEFT], ks[SDL_SCANCODE_RIGHT], ks[SDL_SCANCODE_UP],
                     ks[SDL_SCANCODE_DOWN], ks[SDL_SCANCODE_Z] || ks[SDL_SCANCODE_X], ks[SDL_SCANCODE_X]);

            const int  max_iter = ((1 << IW) - 1) >> sw_iter;
            const auto t0 = Clock::now();
            const uint64_t iters = render(v, max_iter, nthreads, fb);
            cpu_ms  = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
            fpga_ms = std::max((double)iters / MANDEL_PAR, (double)(FB_W * FB_H)) / core_hz * 1e3;
            for (int i = 0; i < FB_W * FB_H; i++) rgb[i] = pal[fb[i]];
            frames++;
            win_frames++;

            // FPGA 가 이 프레임을 그리는 데 걸릴 시간만큼 기다린다 (60 fps 상한은 vsync 가 맡음)
            if (pace) {
                next_frame += std::chrono::microseconds((long)(fpga_ms * 1e3));
                const auto now = Clock::now();
                if (next_frame > now) std::this_thread::sleep_until(next_frame);
                else next_frame = now;      // CPU 가 못 따라가면 밀린 만큼 버린다
            } else {
                next_frame = Clock::now();
            }
        }

        SDL_UpdateTexture(tex, nullptr, rgb.data(), FB_W * sizeof(uint32_t));
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, nullptr, nullptr);
        SDL_RenderPresent(ren);

        const double el = std::chrono::duration<double>(Clock::now() - win_start).count();
        if (el >= 0.5) {
            char title[256];
            snprintf(title, sizeof title,
                     "model v%d | %.0f fps | FPGA ~%.2f ms | CPU %.2f ms | zoom x%.0f | max_iter %d | %s%s",
                     MANDEL_VERSION, win_frames / el, fpga_ms, cpu_ms, (double)View::step0() / v.step,
                     ((1 << IW) - 1) >> sw_iter, manual ? "manual" : "auto",
                     pace ? "" : " | no pace");
            SDL_SetWindowTitle(win, title);
            win_frames = 0;
            win_start  = Clock::now();
        }
        if (max_frames >= 0 && frames >= max_frames) running = false;
    }

    if (dump) {
        SDL_Surface* s = SDL_CreateRGBSurfaceWithFormatFrom(rgb.data(), FB_W, FB_H, 32, FB_W * 4,
                                                            SDL_PIXELFORMAT_ARGB8888);
        SDL_SaveBMP(s, dump);
        SDL_FreeSurface(s);
        printf("saved %s\n", dump);
    }
    printf("%ld frames, last: FPGA ~%.2f ms, CPU %.2f ms, zoom x%.0f\n", frames, fpga_ms, cpu_ms,
           (double)View::step0() / v.step);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
