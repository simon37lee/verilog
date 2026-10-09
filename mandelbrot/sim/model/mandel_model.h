// ---------------------------------------------------------------------------
// mandel_model.h : RTL 과 비트 단위로 같은 C++ 기준 모델 (검사 vmon_mandel 과 실시간 뷰어 model_view 가 같이 쓴다)
//
//   빌드할 때 -DMANDEL_W / -DMANDEL_IW 로 버전 (rtl/vN/config.mk) 에 맞춘다.
//
//   iterate() : 코어 (mandel_core / mandel_ring) 의 반복과 같은 연산
//               z = z^2 + c 를 W 비트 (소수부 FRAC) 로 자르고 넘치면 wrap, 탈출 판정은 곱 그대로 |z|^2 > 4
//   View      : mandel_render 의 보기 영역 (S_VIEW / S_FRAME) 과 같은 갱신
//               좌표는 CW = W + 8 비트, 코어에 넘길 때 아래 8 비트를 버린다
//   pixel()   : 엔진의 픽셀 생성기와 같은 좌표 -> 반복 횟수 (안쪽 = 0)
//   fold()    : 반복 횟수 -> 프레임버퍼 8 비트 (mandel_render 와 같음)
// ---------------------------------------------------------------------------
#pragma once
#include <cstdint>

#ifndef MANDEL_W
#define MANDEL_W 18
#endif
#ifndef MANDEL_IW
#define MANDEL_IW 8
#endif

namespace mandel {

constexpr int FB_W = 320, FB_H = 240;
constexpr int W = MANDEL_W, IW = MANDEL_IW, FRAC = W - 4, CW = W + 8, CFRAC = FRAC + 8;
static_assert(CW <= 63, "coordinates must fit in int64_t");

// 아래 bits 비트를 부호 확장 (bits <= 64)
inline int64_t wrap(int64_t v, int bits) {
    return (int64_t)((uint64_t)v << (64 - bits)) >> (64 - bits);
}
inline int64_t wrap(__int128 v, int bits) { return wrap((int64_t)v, bits); }   // 아래 64 비트만 쓰면 된다

inline int iterate(int64_t cr, int64_t ci, int max_iter) {
    int64_t zr = 0, zi = 0;
    const __int128 four = (__int128)4 << (2 * FRAC);
    for (int n = 0;; n++) {
        const __int128 zr2 = (__int128)zr * zr, zi2 = (__int128)zi * zi, zri = (__int128)zr * zi;
        if (zr2 + zi2 > four || n == max_iter) return n;
        const int64_t nr = wrap(wrap((zr2 - zi2) >> FRAC, W) + cr, W);
        const int64_t ni = wrap(wrap(zri >> (FRAC - 1), W) + ci, W);
        zr = nr;
        zi = ni;
    }
}

// 반복 횟수 -> 프레임버퍼 8 비트: 안쪽 0, 바깥인데 아래 8 비트가 0 이면 같은 색인 64
inline int fold(int n) { return (n != 0 && (n & 255) == 0) ? 64 : (n & 255); }

// (x0, top, step) 프레임의 (px, py) 반복 횟수, 안쪽 (max_iter 까지 탈출 안 함) = 0
inline int pixel(int64_t x0, int64_t top, int64_t step, int px, int py, int max_iter) {
    const int64_t cr = wrap(x0 + (__int128)px * step, CW) >> 8;
    const int64_t ci = wrap(top - (__int128)py * step, CW) >> 8;
    const int n = iterate(cr, ci, max_iter);
    return n == max_iter ? 0 : n;
}

// ---- mandel_render 의 보기 영역 -------------------------------------------------
struct View {
    static constexpr int ZOOM_LOG = (W <= 18) ? 5 : W - 15;
    static int64_t step0() { return wrap(((__int128)7 << CFRAC) / 640, CW); }
    static int64_t tgt(int64_t v48) {           // 소수부 48 비트 목표점 -> CFRAC 비트
        return wrap(CFRAC >= 48 ? (__int128)v48 << (CFRAC - 48) : (__int128)(v48 >> (48 - CFRAC)), CW);
    }

    int64_t cen_re = 0, cen_im = 0, step = 0;   // step 은 0 이상 (RTL 은 부호 없는 CW 비트)
    bool    zooming_in = true;

    View() { reset(); }

    void reset() {
        cen_re     = wrap(-((int64_t)1 << (CFRAC - 1)), CW);      // -0.5
        cen_im     = 0;
        step       = step0();
        zooming_in = true;
    }

    // S_VIEW 한 번 (렌더 프레임마다). 버튼은 그 순간 눌려 있는지
    void update(bool auto_mode, bool l, bool r, bool u, bool d, bool c, bool zoom_out) {
        const int64_t s = step;
        const int64_t step_min = step0() >> ZOOM_LOG, step_max = wrap(step0() << 2, CW);
        if (auto_mode) {
            if (zooming_in) {
                const int64_t tre = tgt(-209317145784806LL), tim = tgt(37105693316051LL);
                cen_re = wrap(cen_re + (wrap(tre - cen_re, CW) >> 4), CW);
                cen_im = wrap(cen_im + (wrap(tim - cen_im, CW) >> 4), CW);
                step   = s - (s >> 5);
                if (s <= step_min) zooming_in = false;
            } else {
                step = s + (s >> 5);
                if (s >= step0()) zooming_in = true;
            }
        } else {
            // RTL 은 non-blocking 이라 같은 레지스터에 두 번 쓰면 뒤의 것이 이긴다
            int64_t re = cen_re, im = cen_im;
            if (l) re = cen_re - (s << 2);
            if (r) re = cen_re + (s << 2);
            if (u) im = cen_im + (s << 2);
            if (d) im = cen_im - (s << 2);
            cen_re = wrap(re, CW);
            cen_im = wrap(im, CW);
            if (c) {
                if (!zoom_out && s > 16)             step = s - (s >> 4);
                else if (zoom_out && s < step_max)   step = s + (s >> 4);
            }
        }
    }

    // S_FRAME: 왼쪽 위 좌표 (160 = 128 + 32, 120 = 128 - 8)
    int64_t x0() const  { return wrap(cen_re - (step << 7) - (step << 5), CW); }
    int64_t top() const { return wrap(cen_im + (step << 7) - (step << 3), CW); }
};

}  // namespace mandel
