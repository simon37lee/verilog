// ---------------------------------------------------------------------------
// bus_skew : 버스 비트마다 일부러 다른 지연을 넣는다 (Spartan-6 CARRY4 지연선, 탭당 약 24 ps)
//
//   level 0      : 추가 지연 없음 (배선 툴이 만든 자연스러운 skew 만 남음)
//   level 1 ~ 15 : 비트 간 최대 지연 차이 D = 500 ps + (level - 1) * 1500 / 14 ps  (500 ~ 2000 ps)
//   비트 i 의 추가 지연 = D * f_i,  f_i = (((i * 7) mod W) + 1) / (W - 1)
//     (1/(W-1) ~ W/(W-1): 비트 간 최대 차이가 D. 0 인 비트가 없어야 그 비트의 선택 회로가
//      상수로 지워지지 않는다 - 지워지면 그 비트만 선택 회로/배선 지연이 빠져 skew 가 된다)
//   -> 탭 = BASE + round(추가 지연 / TAP_PS). 탭 위치는 합성할 때 정해지고, level 로 16 개 중 하나를 고른다.
//   모든 비트가 모든 단계에서 지연선을 BASE 탭 이상 지나간다: 지연선 입구/출구 배선 (약 1 ns) 이
//   모든 비트에 공통으로 들어가야 skew 에서 빠진다 (지연선을 건너뛰는 비트가 있으면 그만큼 skew 가 된다).
//
//   carry chain 은 S = 1111, DI = 0000 이면 carry 입력을 그대로 넘기는 지연선이 된다
//   (metastability 실험의 TDC 와 같은 구조). TAP_PS 는 타이밍 리포트의 가장 느린 조건 값이라
//   실제 칩에서는 지연이 이보다 짧다. 실제 값은 타이밍 리포트로 확인한다 (README 참고).
// ---------------------------------------------------------------------------
module bus_skew #(
    parameter W      = 25,
    parameter TAP_PS = 24,
    parameter BASE   = 4                  // 모든 비트/단계 공통 기본 탭
) (
    input  wire [3:0]   level,
    input  wire [W-1:0] din,
    output wire [W-1:0] dout
);
    // 비트당 CARRY4 수: 가장 긴 탭 BASE + 2000 * W / (W-1) / TAP_PS 을 덮도록
    localparam integer N4 = (BASE + (2000 * W) / ((W - 1) * TAP_PS) + 4) / 4 + 1;

    genvar i, j, L;
    generate
        for (i = 0; i < W; i = i + 1) begin : g_bit
            // ---- 지연선 ----
            wire [4*N4-1:0] co;
            for (j = 0; j < N4; j = j + 1) begin : g_c4
                if (j == 0) begin : g_first
                    CARRY4 u_c4 (.CO(co[3:0]), .O(), .CI(1'b0), .CYINIT(din[i]),
                                 .DI(4'b0000), .S(4'b1111));
                end else begin : g_next
                    CARRY4 u_c4 (.CO(co[4*j+3:4*j]), .O(), .CI(co[4*j-1]), .CYINIT(1'b0),
                                 .DI(4'b0000), .S(4'b1111));
                end
            end

            // ---- 단계별 탭: BASE + round(D(L) * f_i / TAP_PS) ----
            //   D(L) * f_i = (500*14 + (L-1)*1500) / 14 * (((i*7) mod W) + 1) / (W-1),  level 0 은 D = 0
            wire [15:0] cand;
            for (L = 0; L < 16; L = L + 1) begin : g_lv
                localparam integer NUM = (L == 0) ? 0 : (500 * 14 + (L - 1) * 1500) * ((i * 7) % W + 1);
                localparam integer DEN = 14 * (W - 1) * TAP_PS;
                localparam integer T   = BASE + (2 * NUM + DEN) / (2 * DEN);   // 반올림
                assign cand[L] = co[T - 1];
            end
            assign dout[i] = cand[level];
        end
    endgenerate
endmodule
