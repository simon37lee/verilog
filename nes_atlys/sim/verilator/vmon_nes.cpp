// ---------------------------------------------------------------------------
// nes_atlys_core 실시간 가상 모니터 (Verilator + SDL2)
//
//   코어 클럭 100 MHz 하나. 영상은 4 클럭마다 한 픽셀 (25 MHz), 640x480@60.
//   상승 에지마다 eval 하고, de 구간에서 4 클럭에 한 번 (픽셀 가운데) 샘플링한다.
//
//   키보드 -> 1P 패드:  방향키 = 십자키,  X = A (점프),  Z = B (대시/파이어),
//                       Enter = Start,  RShift = Select,  F1 = 콘솔 RESET,  P = 일시정지,
//                       S = 화면 저장 (BMP),  Esc = 종료
//
//   옵션
//     --frames N           N 프레임 후 종료
//     --no-limit           실시간 제한 없이 최대 속도 (어차피 실시간보다 느리다)
//     --dump FILE.bmp      종료할 때 마지막 프레임 저장
//     --press F:BTNS:N     F 번째 프레임부터 N 프레임 동안 버튼 누름 (예: 90:start:5, 200:right+b:60)
//     --uart FILE          FILE 의 바이트를 디버그 UART 로 보낸다 (nes_loader.py --dump 결과).
//                          8O1, UART_BAUD 파라미터와 같은 속도여야 함 (Makefile 은 1.5625 Mbaud)
//     --uart-at F          UART 전송을 시작할 프레임 (기본 2)
// ---------------------------------------------------------------------------
#include <SDL.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Vnes_atlys_core.h"
#include "verilated.h"

#ifndef UART_BAUD
#define UART_BAUD 1562500
#endif

static const int    MAX_W = 1024, MAX_H = 1024;
static const double REFRESH_HZ = 100e6 / (800.0 * 525 * 4);   // 59.52 Hz (25 MHz 픽셀 클럭)

enum { PAD_A = 1, PAD_B = 2, PAD_SELECT = 4, PAD_START = 8,
       PAD_UP = 16, PAD_DOWN = 32, PAD_LEFT = 64, PAD_RIGHT = 128 };

struct Monitor {
    std::vector<uint32_t> fb = std::vector<uint32_t>(MAX_W * MAX_H);
    int  px = 0, py = 0, width = 0, height = 0, de_clk = 0;
    bool prev_de = false, prev_vs_active = false, synced = false;

    // 100 MHz 클럭마다 호출. 프레임이 끝나면 true
    bool push(uint8_t r, uint8_t g, uint8_t b, bool de, bool vs) {
        bool vs_active = !vs;   // active-low
        bool frame_done = false;
        if (de) {
            if (!prev_de) de_clk = 0;
            if ((de_clk & 3) == 2) {            // 픽셀 가운데에서 샘플
                if (synced && px < MAX_W && py < MAX_H)
                    fb[py * MAX_W + px] = 0xFF000000u | (r << 16) | (g << 8) | b;
                px++;
            }
            de_clk++;
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

// 8O1 UART 송신기 (호스트 -> FPGA rx)
struct UartTx {
    std::vector<uint8_t> data;
    size_t   idx = 0;
    int      bit = -1;          // -1: 대기, 0: start, 1..8: data, 9: parity, 10: stop
    double   clk_per_bit = 100e6 / UART_BAUD, acc = 0;
    bool     active = false;

    bool line() const {
        if (!active || bit < 0) return true;
        uint8_t v = data[idx];
        if (bit == 0) return false;
        if (bit <= 8) return (v >> (bit - 1)) & 1;
        if (bit == 9) return !__builtin_parity(v);   // 홀수 패리티: 1 의 총 개수가 홀수
        return true;
    }
    void tick() {                  // 100 MHz 클럭마다
        if (!active || idx >= data.size()) { active = false; return; }
        if (bit < 0) { bit = 0; acc = 0; return; }
        if (++acc >= clk_per_bit) {
            acc -= clk_per_bit;
            if (++bit > 10) { bit = -1; idx++; }
        }
    }
};

static uint8_t parse_buttons(const char* s) {
    uint8_t m = 0;
    std::string str(s);
    size_t pos = 0;
    while (pos <= str.size()) {
        size_t e = str.find('+', pos);
        std::string k = str.substr(pos, e == std::string::npos ? std::string::npos : e - pos);
        if      (k == "a")      m |= PAD_A;
        else if (k == "b")      m |= PAD_B;
        else if (k == "select") m |= PAD_SELECT;
        else if (k == "start")  m |= PAD_START;
        else if (k == "up")     m |= PAD_UP;
        else if (k == "down")   m |= PAD_DOWN;
        else if (k == "left")   m |= PAD_LEFT;
        else if (k == "right")  m |= PAD_RIGHT;
        else { fprintf(stderr, "unknown button '%s'\n", k.c_str()); exit(2); }
        if (e == std::string::npos) break;
        pos = e + 1;
    }
    return m;
}

static void save_bmp(const Monitor& m, const char* name) {
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormatFrom(
        (void*)m.fb.data(), m.width, m.height, 32, MAX_W * 4, SDL_PIXELFORMAT_ARGB8888);
    SDL_SaveBMP(s, name);
    SDL_FreeSurface(s);
    printf("saved %s (%dx%d)\n", name, m.width, m.height);
}

struct Press { long frame, len; uint8_t btns; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    bool   limit = true;
    long   max_frames = 0, uart_at = 2;
    const char* dump = nullptr;
    std::vector<Press> presses;
    UartTx uart;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--no-limit"))                   limit = false;
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) max_frames = atol(argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc)   dump = argv[++i];
        else if (!strcmp(argv[i], "--uart-at") && i + 1 < argc) uart_at = atol(argv[++i]);
        else if (!strcmp(argv[i], "--uart") && i + 1 < argc) {
            FILE* f = fopen(argv[++i], "rb");
            if (!f) { perror(argv[i]); return 2; }
            int c;
            while ((c = fgetc(f)) != EOF) uart.data.push_back((uint8_t)c);
            fclose(f);
        } else if (!strcmp(argv[i], "--press") && i + 1 < argc) {
            char buf[128];
            Press p{};
            if (sscanf(argv[++i], "%ld:%127[^:]:%ld", &p.frame, buf, &p.len) != 3) {
                fprintf(stderr, "--press FRAME:BTN[+BTN]:FRAMES\n");
                return 2;
            }
            p.btns = parse_buttons(buf);
            presses.push_back(p);
        } else if (argv[i][0] == '+') {
            // Verilator 플러스 인자
        } else {
            fprintf(stderr, "unknown option %s\n", argv[i]);
            return 2;
        }
    }

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window*   win = nullptr;
    SDL_Renderer* ren = nullptr;
    SDL_Texture*  tex = nullptr;
    int tex_w = 0, tex_h = 0;

    auto dut = std::make_unique<Vnes_atlys_core>();
    Monitor mon;
    uint64_t cycles = 0;

    dut->clk = 0;
    dut->rst = 1;
    dut->console_reset = 0;
    dut->pad = 0;
    dut->mute = 0;
    dut->uart_rx = 1;
    dut->eval();

    // 한 클럭: 0 을 관측시킨 뒤 상승 에지 (설계에 negedge 로직 없음)
    auto cycle = [&]() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
        cycles++;
    };
    for (int i = 0; i < 16; i++) cycle();
    dut->rst = 0;

    const uint64_t perf_freq   = SDL_GetPerformanceFrequency();
    const double   frame_ticks = perf_freq / REFRESH_HZ;
    uint64_t next_frame  = SDL_GetPerformanceCounter();
    uint64_t stat_start  = next_frame;
    long     stat_frames = 0, frames = 0;
    bool     running = true, paused = false;
    uint8_t  kbd = 0;
    bool     kbd_reset = false;

    while (running) {
        if (!paused) {
            uint8_t script = 0;
            for (const auto& p : presses)
                if (frames >= p.frame && frames < p.frame + p.len) script |= p.btns;
            dut->pad = kbd | script;
            dut->console_reset = kbd_reset;
            if (frames == uart_at && !uart.data.empty() && !uart.active && uart.idx == 0) {
                uart.active = true;
                printf("[uart] sending %zu bytes at %d baud\n", uart.data.size(), UART_BAUD);
            }

            bool done = false;
            while (!done) {
                uart.tick();
                dut->uart_rx = uart.line();
                cycle();
                done = mon.push(dut->r, dut->g, dut->b, dut->de, dut->vsync);
            }
            if (!uart.data.empty() && uart.idx == uart.data.size()) {
                printf("[uart] done at frame %ld\n", frames);
                uart.data.clear();
            }
            frames++;
            stat_frames++;

            if (mon.width != tex_w || mon.height != tex_h) {
                tex_w = mon.width;
                tex_h = mon.height;
                if (tex) SDL_DestroyTexture(tex);
                if (!win) {
                    win = SDL_CreateWindow("NES Virtual Monitor", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                           tex_w, tex_h, SDL_WINDOW_RESIZABLE);
                    ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
                    if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
                } else {
                    SDL_SetWindowSize(win, tex_w, tex_h);
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
            else if (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP) {
                bool down = e.type == SDL_KEYDOWN;
                uint8_t bit = 0;
                switch (e.key.keysym.sym) {
                    case SDLK_x:      bit = PAD_A; break;
                    case SDLK_z:      bit = PAD_B; break;
                    case SDLK_RSHIFT: bit = PAD_SELECT; break;
                    case SDLK_RETURN: bit = PAD_START; break;
                    case SDLK_UP:     bit = PAD_UP; break;
                    case SDLK_DOWN:   bit = PAD_DOWN; break;
                    case SDLK_LEFT:   bit = PAD_LEFT; break;
                    case SDLK_RIGHT:  bit = PAD_RIGHT; break;
                    case SDLK_F1:     kbd_reset = down; break;
                    case SDLK_ESCAPE: if (down) running = false; break;
                    case SDLK_p:      if (down) paused = !paused; break;
                    case SDLK_s:
                        if (down) {
                            char name[64];
                            snprintf(name, sizeof name, "vmon_%ld.bmp", frames);
                            save_bmp(mon, name);
                        }
                        break;
                }
                if (bit) kbd = down ? (kbd | bit) : (kbd & ~bit);
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
            snprintf(title, sizeof title, "NES Virtual Monitor  |  frame %ld  |  %.1f fps (%.0f%% of real-time)%s",
                     frames, fps, 100.0 * fps / REFRESH_HZ, paused ? "  [PAUSED]" : "");
            if (win) SDL_SetWindowTitle(win, title);
            if (max_frames > 0) printf("%s\n", title + 21);
            stat_start  = now;
            stat_frames = 0;
        }
    }

    printf("simulated %ld frames (%.3f s of hardware time)\n", frames, cycles / 100e6);
    if (dump && tex_w > 0) save_bmp(mon, dump);

    dut->final();
    if (tex) SDL_DestroyTexture(tex);
    if (ren) SDL_DestroyRenderer(ren);
    if (win) SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
