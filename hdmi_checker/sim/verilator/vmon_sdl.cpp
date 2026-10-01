// ---------------------------------------------------------------------------
// vmon_sdl : Verilator + SDL2 실시간 가상 모니터
//
//   hdmi_core (Verilator 가 C++ 로 변환) 를 픽셀 클럭 단위로 돌리면서
//   매 클럭 나오는 TMDS 10비트 워드 3채널을 실제 모니터처럼 디코딩한다.
//     TMDS 디코딩 -> hsync/vsync/DE 로 화면 위치 복원 -> 프레임 버퍼 -> SDL 창
//   해상도는 신호에서 자동으로 측정한다.
//
//   250 MHz 직렬화기는 시뮬레이션하지 않는다 (속도를 위해, tb_hdmi 에서 검증됨).
//
//   옵션:
//     --scale N      창 확대 배율 (기본 2)
//     --no-limit     60 fps 제한 해제 (시뮬레이션 최대 속도 측정용)
//     --frames N     N 프레임 후 종료 (기본: 창을 닫을 때까지)
//     --dump F.bmp   종료할 때 마지막 프레임을 BMP 로 저장
//
//   조작:  SPACE 일시정지 / S 스크린샷(BMP) / ESC 종료
// ---------------------------------------------------------------------------
#include <SDL.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

#include "Vhdmi_core.h"
#include "verilated.h"

namespace {

constexpr int MAX_W = 1920;
constexpr int MAX_H = 1080;
constexpr double REFRESH_HZ = 25e6 / (800.0 * 525.0);   // 실제 하드웨어 리프레시 (약 59.5 Hz)

// ---- TMDS 디코딩 표 (10비트 워드 -> 데이터 또는 컨트롤) ---------------------
struct TmdsSym {
    bool    ctrl;   // 컨트롤 토큰이면 true
    uint8_t value;  // 데이터 바이트, 컨트롤이면 {c1, c0}
};

TmdsSym g_tmds[1024];

void build_tmds_table() {
    for (int q = 0; q < 1024; q++) {
        TmdsSym s{false, 0};
        switch (q) {
            case 0b1101010100: s = {true, 0}; break;
            case 0b0010101011: s = {true, 1}; break;
            case 0b0101010100: s = {true, 2}; break;
            case 0b1010101011: s = {true, 3}; break;
            default: {
                uint8_t d = (q & 0x200) ? ~q & 0xFF : q & 0xFF;
                bool xor_mode = q & 0x100;
                uint8_t out = d & 1;
                for (int k = 1; k < 8; k++) {
                    int b = ((d >> k) ^ (d >> (k - 1))) & 1;
                    if (!xor_mode) b ^= 1;
                    out |= b << k;
                }
                s.value = out;
            }
        }
        g_tmds[q] = s;
    }
}

// ---- 수신기 (모니터) ------------------------------------------------------
struct Monitor {
    std::vector<uint32_t> fb = std::vector<uint32_t>(MAX_W * MAX_H);
    int  px = 0, py = 0, width = 0, height = 0;
    bool prev_de = false, prev_vs = true, synced = false;
    bool decode_error = false;

    // 픽셀 한 개 입력. 프레임이 완성되면 true
    bool push(uint16_t ch0, uint16_t ch1, uint16_t ch2) {
        const TmdsSym& b = g_tmds[ch0 & 0x3FF];
        const TmdsSym& g = g_tmds[ch1 & 0x3FF];
        const TmdsSym& r = g_tmds[ch2 & 0x3FF];
        bool de = !b.ctrl;
        bool frame_done = false;

        if (de) {
            if (g.ctrl || r.ctrl) decode_error = true;
            if (synced && px < MAX_W && py < MAX_H)
                fb[py * MAX_W + px] = 0xFF000000u | (r.value << 16) | (g.value << 8) | b.value;
            px++;
        } else {
            bool vs = b.value & 2;   // c1 = vsync (active-low)
            if (prev_de) {           // 라인 끝
                width = px;
                px = 0;
                py++;
            }
            if (!vs && prev_vs) {    // vsync 시작 = 프레임 끝
                if (synced && py > 0) {
                    height = py;
                    frame_done = true;
                }
                synced = true;
                py = 0;
            }
            prev_vs = vs;
        }
        prev_de = de;
        return frame_done;
    }
};

}  // namespace

int main(int argc, char** argv) {
    int  scale = 2;
    bool limit = true;
    long max_frames = -1;
    const char* dump = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--scale") && i + 1 < argc)       scale = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-limit"))               limit = false;
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) max_frames = atol(argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc)   dump = argv[++i];
    }

    Verilated::commandArgs(argc, argv);
    build_tmds_table();

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window*   win = nullptr;
    SDL_Renderer* ren = nullptr;
    SDL_Texture*  tex = nullptr;
    int tex_w = 0, tex_h = 0;

    auto dut = std::make_unique<Vhdmi_core>();
    Monitor mon;

    // 리셋
    dut->rst = 1;
    for (int i = 0; i < 8; i++) {
        dut->clk_pix = 0; dut->eval();
        dut->clk_pix = 1; dut->eval();
    }
    dut->rst = 0;

    const uint64_t perf_freq   = SDL_GetPerformanceFrequency();
    const double   frame_ticks = perf_freq / REFRESH_HZ;
    uint64_t next_frame  = SDL_GetPerformanceCounter();
    uint64_t stat_start  = next_frame;
    long     stat_frames = 0, frames = 0;
    double   sim_fps     = 0;
    bool     running = true, paused = false;

    while (running) {
        // ---- 한 프레임이 완성될 때까지 픽셀 클럭을 돌린다 --------------------
        if (!paused) {
            bool done = false;
            while (!done) {
                dut->clk_pix = 0; dut->eval();
                dut->clk_pix = 1; dut->eval();
                done = mon.push(dut->tmds_ch0, dut->tmds_ch1, dut->tmds_ch2);
            }
            frames++;
            stat_frames++;
            if (mon.decode_error) {
                fprintf(stderr, "TMDS decode error: data/control mismatch between channels\n");
                mon.decode_error = false;
            }

            // 해상도가 정해지거나 바뀌면 창/텍스처 생성
            if (mon.width != tex_w || mon.height != tex_h) {
                tex_w = mon.width;
                tex_h = mon.height;
                if (tex) SDL_DestroyTexture(tex);
                if (!win) {
                    win = SDL_CreateWindow("Virtual Monitor", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                           tex_w * scale, tex_h * scale, SDL_WINDOW_RESIZABLE);
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

        // ---- 화면 표시 ---------------------------------------------------------
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, nullptr, nullptr);
        SDL_RenderPresent(ren);

        // ---- 이벤트 -----------------------------------------------------------
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
                        SDL_Surface* s = SDL_CreateRGBSurfaceWithFormatFrom(
                            mon.fb.data(), tex_w, tex_h, 32, MAX_W * 4, SDL_PIXELFORMAT_ARGB8888);
                        SDL_SaveBMP(s, name);
                        SDL_FreeSurface(s);
                        printf("saved %s\n", name);
                        break;
                    }
                }
            }
        }
        if (max_frames > 0 && frames >= max_frames) running = false;

        // ---- 실제 하드웨어 속도(약 59.5 Hz)에 맞춤 ------------------------------
        uint64_t now = SDL_GetPerformanceCounter();
        if (limit) {
            next_frame += (uint64_t)frame_ticks;
            if (now < next_frame)
                SDL_Delay((uint32_t)((next_frame - now) * 1000 / perf_freq));
            else
                next_frame = now;   // 따라가지 못하면 밀린 시간을 버린다
        }

        // ---- 1초마다 속도 표시 -------------------------------------------------
        double elapsed = (double)(now - stat_start) / perf_freq;
        if (elapsed >= 1.0) {
            sim_fps = stat_frames / elapsed;
            char title[160];
            snprintf(title, sizeof title, "Virtual Monitor - %dx%d  |  %.1f fps  (%.0f%% of real-time)%s",
                     tex_w, tex_h, sim_fps, 100.0 * sim_fps / REFRESH_HZ, paused ? "  [PAUSED]" : "");
            SDL_SetWindowTitle(win, title);
            if (max_frames > 0) printf("%.1f fps (%.0f%% of real-time)\n", sim_fps, 100.0 * sim_fps / REFRESH_HZ);
            stat_start = now;
            stat_frames = 0;
        }
    }

    if (dump && tex_w > 0) {
        SDL_Surface* s = SDL_CreateRGBSurfaceWithFormatFrom(
            mon.fb.data(), tex_w, tex_h, 32, MAX_W * 4, SDL_PIXELFORMAT_ARGB8888);
        SDL_SaveBMP(s, dump);
        SDL_FreeSurface(s);
        printf("saved %s\n", dump);
    }
    printf("simulated %ld frames\n", frames);

    dut->final();
    if (tex) SDL_DestroyTexture(tex);
    if (ren) SDL_DestroyRenderer(ren);
    if (win) SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
