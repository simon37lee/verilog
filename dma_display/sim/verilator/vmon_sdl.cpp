// ---------------------------------------------------------------------------
// vmon_sdl : dma_display_core 실시간 가상 모니터 (Verilator + SDL2)
//
//   서로 비동기인 클럭 3개를 시간(ps) 기준으로 각각 토글하며 시뮬레이션한다.
//     clk_pix 25 MHz / clk_src 33 MHz / clk_tgt 22 MHz
//   픽셀 클럭마다 RGB / DE / HSYNC / VSYNC 를 받아 모니터처럼 화면을 복원한다.
//
//   타겟2 버스 배선 모델 (n2_* 출력 -> t2_* 입력):
//     RTL 시뮬레이션은 모든 비트를 이상적인 0/1 로 다루므로, 비동기 클럭으로
//     버스를 직접 샘플링할 때 생기는 문제(비트마다 다른 배선 지연 -> 옛 값/새 값이
//     섞임, 전이 순간 샘플링 -> 메타스테빌리티)를 스스로 재현할 수 없다.
//     그래서 하네스가 실제 배선처럼 연결한다:
//       - 비트마다 고정된 배선 지연 (0 ~ --skew-ns, 고정 시드로 무작위 배정)
//       - 22 MHz 에지가 어떤 비트의 도착 시각 ±--meta-ps 안이면 그 비트는 0/1 무작위
//       - 그 밖에는 도착 전이면 옛 값, 도착 후면 새 값
//     타겟1 경로(async FIFO)는 이 모델과 무관하다 (모델 내부 신호만 사용).
//
//   옵션:
//     --scale N      창 확대 배율 (기본 1)
//     --no-limit     실시간(60 Hz) 제한 해제 (최대 속도 측정용)
//     --frames N     N 프레임 후 종료
//     --dump F.bmp   종료할 때 마지막 프레임을 BMP 로 저장
//     --check        종료할 때 세 이미지를 기대한 체크보드와 비교 (SCROLL=0 빌드에서 사용)
//                    소스/타겟1 은 완전히 같아야 PASS, 타겟2 는 오류 픽셀 수만 보고
//     --skew-ns X    타겟2 버스 비트 간 최대 배선 지연 (기본 10, 0 이면 이상적인 배선)
//     --meta-ps X    메타스테빌리티 창 (기본 100)
//     --full-eval    모든 클럭 에지마다 eval() (최적화 전 기준 방식, 결과 비교용)
//     --tgt-mhz F    타겟 클럭 주파수 (기본 22). 33 MHz 보다 크면 타겟2 픽셀 누락이 없어진다
//     --errmap       스크롤을 멈추고 타겟2 오류 누적 맵(빨간 점)을 켠다 (보드의 SW0)
//
//   조작:  SPACE 일시정지 / S 스크린샷(BMP) / ESC 종료
//          ↑ / ↓  타겟2 배선 지연(skew) ±1 ns (0 ~ 15 ns, 0 이면 펄스 누락 효과만 남음)
// ---------------------------------------------------------------------------
#include <SDL.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

#include "Vdma_display_core.h"
#include "verilated.h"

namespace {

constexpr int    MAX_W = 1920;
constexpr int    MAX_H = 1080;
constexpr double PIX_HZ = 25e6;
constexpr double REFRESH_HZ = PIX_HZ / (800.0 * 525.0);   // 640x480 전체 타이밍 (약 59.5 Hz)

// 화면 배치 (tri_display.v 와 같아야 함)
constexpr int IMG_X[3] = {6, 220, 434};
constexpr int IMG_TOP = 140, IMG = 200, BORDER = 2;

// ---- 비동기 클럭 ----------------------------------------------------------
struct Clock {
    uint64_t half_ps;     // 반주기
    uint64_t next_ps;     // 다음 토글 시각 (full-eval 방식용)
    CData*   sig;
};

// ---- 결정적 난수 (xorshift64) -----------------------------------------------
struct Rng {
    uint64_t s;
    uint64_t next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
};

// ---- 타겟2 버스 배선 모델 ---------------------------------------------------
//   비트 배치: [0] valid, [18:1] addr, [26:19] data
struct BusWire {
    static constexpr int BITS = 27;
    double   frac[BITS];                    // 비트별 배선 지연 비율 (0~1, 고정 시드)
    int64_t  skew_ps[BITS];
    int64_t  max_skew = 0, meta_ps = 0, meta_base_ps = 0;
    double   skew_ns = 0;
    uint32_t old_val = 0, new_val = 0;      // 마지막 변화 전/후 값
    int64_t  t_change = -1000000;           // 마지막 변화 시각 (소스 에지)
    Rng      rng{0x9E3779B97F4A7C15ull};
    uint64_t samples = 0, mixed = 0;        // 통계: 샘플 수, 옛/새 값이 섞인 샘플 수

    void init(double ns, double meta) {
        meta_base_ps = (int64_t)meta;
        for (int i = 0; i < BITS; i++)
            frac[i] = (rng.next() % 1000001) / 1e6;
        set_skew(ns);
    }
    // 최대 배선 지연 변경 (비트 간 상대 순서는 유지). 0 이면 이상적인 배선
    void set_skew(double ns) {
        skew_ns  = ns;
        meta_ps  = ns > 0 ? meta_base_ps : 0;
        max_skew = 0;
        for (int i = 0; i < BITS; i++) {
            skew_ps[i] = (int64_t)(frac[i] * ns * 1000);
            if (skew_ps[i] > max_skew) max_skew = skew_ps[i];
        }
    }
    static uint32_t pack(const Vdma_display_core* d) {
        return (d->n2_valid & 1u) | ((d->n2_addr & 0x3FFFFu) << 1) | ((uint32_t)d->n2_data << 19);
    }
    // 소스 쪽 레지스터가 바뀌었으면 기록 (eval 직후 호출)
    void observe(const Vdma_display_core* d, int64_t t) {
        uint32_t cur = pack(d);
        if (cur != new_val) {
            old_val  = new_val;
            new_val  = cur;
            t_change = t;
        }
    }
    // 타겟 클럭 에지 시각 t 에 수신 쪽 플립플롭 입력에 보이는 값
    uint32_t sample(int64_t t) {
        samples++;
        if (t >= t_change + max_skew + meta_ps) return new_val;   // 이미 모두 도착
        uint32_t diff = old_val ^ new_val, v = old_val & ~diff;
        bool from_old = false, from_new = false;
        for (int i = 0; i < BITS; i++) {
            uint32_t m = 1u << i;
            if (!(diff & m)) continue;
            int64_t arrive = t_change + skew_ps[i];
            bool bit;
            if (t >= arrive + meta_ps)      { bit = true;  from_new = true; }
            else if (t < arrive - meta_ps)  { bit = false; from_old = true; }
            else                            { bit = rng.next() & 1; from_new = from_old = true; }
            if (bit) v |= new_val & m; else v |= old_val & m;
        }
        if (from_old && from_new) mixed++;
        return v;
    }
    void drive(Vdma_display_core* d, int64_t t) {
        uint32_t v = sample(t);
        d->t2_valid = v & 1;
        d->t2_addr  = (v >> 1) & 0x3FFFF;
        d->t2_data  = (v >> 19) & 0xFF;
    }
};

// ---- 수신기 (모니터): 디지털 RGB + sync (640x480 은 sync 음극성) -------------
struct Monitor {
    std::vector<uint32_t> fb = std::vector<uint32_t>(MAX_W * MAX_H);
    int  px = 0, py = 0, width = 0, height = 0;
    bool prev_de = false, prev_vs_active = false, synced = false;

    bool push(uint8_t r, uint8_t g, uint8_t b, bool de, bool vs) {
        bool vs_active = !vs;   // active-low
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
    uint32_t at(int col, int lx, int ly) const {
        return fb[(IMG_TOP + ly) * MAX_W + IMG_X[col] + lx];
    }
};

// ---- 검사: SCROLL=0 이면 세 이미지 모두 offset 0 체크보드여야 한다 -------------
//   화면 (lx, ly) = 버퍼 (2lx, 2ly), 칸 50px -> 화면에서 25px
void check_frame(const Monitor& m, int errs[3]) {
    for (int col = 0; col < 3; col++) {
        errs[col] = 0;
        for (int ly = BORDER; ly < IMG - BORDER; ly++)
            for (int lx = BORDER; lx < IMG - BORDER; lx++) {
                bool dark = ((lx / 25) ^ (ly / 25)) & 1;
                uint32_t expect = dark ? 0xFF000000u : 0xFFFFFFFFu;
                if (m.at(col, lx, ly) != expect) errs[col]++;
            }
    }
}

// 타겟1 과 타겟2 이미지가 다른 픽셀 비율 (실시간 표시용)
double diff_t1_t2(const Monitor& m) {
    int diff = 0, total = 0;
    for (int ly = BORDER; ly < IMG - BORDER; ly++)
        for (int lx = BORDER; lx < IMG - BORDER; lx++, total++)
            diff += m.at(1, lx, ly) != m.at(2, lx, ly);
    return 100.0 * diff / total;
}

void save_bmp(const Monitor& m, const char* name) {
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormatFrom(
        (void*)m.fb.data(), m.width, m.height, 32, MAX_W * 4, SDL_PIXELFORMAT_ARGB8888);
    SDL_SaveBMP(s, name);
    SDL_FreeSurface(s);
    printf("saved %s\n", name);
}

}  // namespace

int main(int argc, char** argv) {
    int    scale = 1;
    bool   limit = true, check = false, full_eval = false, errmap = false;
    long   max_frames = -1;
    double skew_ns = 10.0, meta_ps = 100.0, tgt_mhz = 0.0;
    const char* dump = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--scale") && i + 1 < argc)        scale = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-limit"))                limit = false;
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc)  max_frames = atol(argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc)    dump = argv[++i];
        else if (!strcmp(argv[i], "--check"))                   check = true;
        else if (!strcmp(argv[i], "--full-eval"))               full_eval = true;
        else if (!strcmp(argv[i], "--skew-ns") && i + 1 < argc) skew_ns = atof(argv[++i]);
        else if (!strcmp(argv[i], "--meta-ps") && i + 1 < argc) meta_ps = atof(argv[++i]);
        else if (!strcmp(argv[i], "--tgt-mhz") && i + 1 < argc) tgt_mhz = atof(argv[++i]);
        else if (!strcmp(argv[i], "--errmap"))                  errmap = true;
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

    auto dut = std::make_unique<Vdma_display_core>();
    Monitor mon;
    BusWire wire;
    wire.init(skew_ns, meta_ps);

    // 반주기(ps): 25 MHz = 20000, 33 MHz = 15151.5 -> 15152, 22 MHz = 22727.3 -> 22727
    // 정수로 맞아떨어지지 않으므로 세 클럭의 위상 관계가 계속 변한다 (비동기)
    enum { PIX = 0, SRC = 1, TGT = 2 };
    Clock clocks[3] = {
        {20000, 20000, &dut->clk_pix},
        {15152, 15152, &dut->clk_src},
        {22727, 22727, &dut->clk_tgt},
    };
    if (tgt_mhz > 0) {
        const uint64_t half = (uint64_t)(5e5 / tgt_mhz + 0.5);
        clocks[TGT].half_ps = clocks[TGT].next_ps = half;
    }
    int64_t now_ps = 0;
    bool    any_rise = false;   // 마지막 step 에 상승 에지가 있었는지

    dut->clk_pix = dut->clk_src = dut->clk_tgt = 0;
    dut->rst = 1;
    dut->errmap_mode = errmap;
    dut->eval();

    // ---- 기준 방식: 모든 에지(상승/하강)마다 eval. 결과 비교용 -----------------
    auto step_full = [&]() -> bool {
        uint64_t t = clocks[0].next_ps;
        for (auto& c : clocks) if (c.next_ps < t) t = c.next_ps;
        now_ps = t;
        bool rise[3] = {false, false, false};
        for (int i = 0; i < 3; i++) {
            Clock& c = clocks[i];
            if (c.next_ps != t) continue;
            c.next_ps += c.half_ps;
            *c.sig ^= 1;
            rise[i] = *c.sig;
        }
        any_rise = rise[0] || rise[1] || rise[2];
        if (rise[TGT]) wire.drive(dut.get(), now_ps);
        dut->f_wgray_s = dut->f_wgray_x;   // 타겟1 FIFO Gray 포인터: 그대로 연결 (에지 직전 값)
        dut->f_rgray_s = dut->f_rgray_x;
        dut->eval();
        if (rise[SRC]) wire.observe(dut.get(), now_ps);
        return rise[PIX];
    };

    // ---- 빠른 방식: 상승 에지만 이벤트로 처리 ---------------------------------
    // 설계에 negedge 로직이 없으므로 하강 에지에서는 eval() 할 필요가 없다.
    // 단, Verilator 는 "직전 eval() 에서 본 값"과 비교해 에지를 찾으므로, 어떤 클럭이
    // 다시 올라가기 전에 그 클럭의 0 이 적어도 한 번은 eval() 로 관측되어야 한다.
    //   -> 마지막 eval 시각이 그 클럭의 하강 시각보다 이르면, 올리기 전에 eval() 한 번 더.
    // 각 클럭의 현재 값은 시각으로 계산: 상승 후 반주기 동안만 1.
    // last_rise 를 음수로 두어 첫 상승 전에는 값이 0 으로 계산되게 한다.
    int64_t rise_ps[3], last_rise_ps[3], last_eval_ps = 0;   // t=0 에 이미 eval 함
    for (int i = 0; i < 3; i++) {
        rise_ps[i]      = clocks[i].half_ps;
        last_rise_ps[i] = -2 * (int64_t)clocks[i].half_ps;
    }

    auto step_fast = [&]() -> bool {
        int64_t t = rise_ps[0];
        if (rise_ps[1] < t) t = rise_ps[1];
        if (rise_ps[2] < t) t = rise_ps[2];
        now_ps = t;

        bool need_low_eval = false;
        for (int i = 0; i < 3; i++) {
            const int64_t half = clocks[i].half_ps;
            if (rise_ps[i] == t) {
                *clocks[i].sig = 0;                                  // 상승 직전 값
                if (last_eval_ps < t - half) need_low_eval = true;   // 하강 이후 eval 없었음
            } else {
                *clocks[i].sig = (t < last_rise_ps[i] + half);       // 상승 후 반주기 동안 1
            }
        }
        if (need_low_eval) dut->eval();    // 0 을 관측시킨다 (에지 없음 -> 아주 싸다)

        bool rise[3];
        for (int i = 0; i < 3; i++) {
            rise[i] = (rise_ps[i] == t);
            if (rise[i]) {
                *clocks[i].sig  = 1;
                last_rise_ps[i] = t;
                rise_ps[i]     += 2 * (int64_t)clocks[i].half_ps;
            }
        }
        any_rise = true;
        if (rise[TGT]) wire.drive(dut.get(), t);
        dut->f_wgray_s = dut->f_wgray_x;   // 타겟1 FIFO Gray 포인터: 그대로 연결 (에지 직전 값)
        dut->f_rgray_s = dut->f_rgray_x;
        dut->eval();
        if (rise[SRC]) wire.observe(dut.get(), t);
        last_eval_ps = t;
        return rise[PIX];
    };

    auto step = [&]() -> bool { return full_eval ? step_full() : step_fast(); };

    // 리셋: 모든 클럭을 돌리면서 1 us 동안 유지.
    // 해제 시점은 "1 us 이후 첫 상승 에지 직후"로 고정한다 (두 step 방식에서 같은 시점이 되도록:
    // 기준 방식은 하강 에지도 step 이라, 단순히 now_ps >= 1us 로 끊으면 해제 시점이 달라진다)
    do step(); while (!(now_ps >= 1000000 && any_rise));
    dut->rst = 0;

    const uint64_t perf_freq   = SDL_GetPerformanceFrequency();
    const double   frame_ticks = perf_freq / REFRESH_HZ;
    uint64_t next_frame  = SDL_GetPerformanceCounter();
    uint64_t stat_start  = next_frame;
    long     stat_frames = 0, frames = 0;
    unsigned stat_copies = dut->tgt_frames;
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
                    win = SDL_CreateWindow("DMA Virtual Monitor", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
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
                    case SDLK_UP:
                    case SDLK_DOWN: {
                        double ns = wire.skew_ns + (e.key.keysym.sym == SDLK_UP ? 1 : -1);
                        if (ns < 0) ns = 0;
                        if (ns > 15) ns = 15;
                        wire.set_skew(ns);
                        printf("target2 bus skew: %.0f ns\n", ns);
                        break;
                    }
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

        // 1초마다: 화면 fps, 실시간 대비 %, DMA 복사 속도, 타겟1/타겟2 차이
        double elapsed = (double)(now - stat_start) / perf_freq;
        if (elapsed >= 1.0) {
            double fps = stat_frames / elapsed;
            double sim_sec = stat_frames / REFRESH_HZ;
            unsigned copies = (uint16_t)(dut->tgt_frames - stat_copies);
            char title[260];
            snprintf(title, sizeof title,
                     "DMA Virtual Monitor  |  %.1f fps (%.0f%% of real-time)  |  DMA %.1f frames/s  |  "
                     "TGT2 skew %.0f ns (up/down)  TGT2 != TGT1: %.1f%%%s",
                     fps, 100.0 * fps / REFRESH_HZ, sim_sec > 0 ? copies / sim_sec : 0.0,
                     wire.skew_ns, diff_t1_t2(mon), paused ? "  [PAUSED]" : "");
            SDL_SetWindowTitle(win, title);
            if (max_frames > 0) printf("%s\n", title + 21);
            stat_start  = now;
            stat_frames = 0;
            stat_copies = dut->tgt_frames;
        }
    }

    printf("simulated %ld frames (%.3f s of hardware time), DMA copied %u frames\n",
           frames, now_ps / 1e12, (unsigned)dut->tgt_frames);
    printf("target2 bus: %llu samples, %llu mixed old/new (%.2f%%)  [skew %.1f ns, meta window %.0f ps]\n",
           (unsigned long long)wire.samples, (unsigned long long)wire.mixed,
           wire.samples ? 100.0 * wire.mixed / wire.samples : 0.0, wire.skew_ns, (double)wire.meta_ps);
    if (dump && tex_w > 0) save_bmp(mon, dump);
    int rc = 0;
    if (check) {
        int errs[3];
        check_frame(mon, errs);
        const int total = (IMG - 2 * BORDER) * (IMG - 2 * BORDER);
        printf("check: source %d, target1 %d, target2 %d wrong pixels (of %d)\n", errs[0], errs[1], errs[2], total);
        if (errs[0] || errs[1]) {
            printf("CHECK FAIL: source/target1 must match the checkerboard exactly\n");
            rc = 1;
        } else {
            printf("CHECK PASS: source == target1 == checkerboard; target2 has %.2f%% wrong pixels\n",
                   100.0 * errs[2] / total);
        }
    }

    dut->final();
    if (tex) SDL_DestroyTexture(tex);
    if (ren) SDL_DestroyRenderer(ren);
    if (win) SDL_DestroyWindow(win);
    SDL_Quit();
    return rc;
}
