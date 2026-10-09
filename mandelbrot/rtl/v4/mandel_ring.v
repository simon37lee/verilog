// ---------------------------------------------------------------------------
// mandel_ring (v4) : W 비트 (기본 34) 8 단 파이프라인 링 + 1 칸 입력 / 출력 버퍼
//
//   W 가 18 을 넘으면 곱셈 하나가 DSP48A1 1 개로 안 된다. 그대로 쪼개면 일반 곱셈 3 개 x 4 = DSP 12 개.
//   zr*zi 를 제곱으로 바꾸면 제곱 3 개 x 3 = 9 개로 줄어든다 (mandel_sq.v):
//     s = zr + zi  ->  2 zr zi = s^2 - zr^2 - zi^2 = s^2 - |z|^2
//   정수 연산으로 정확히 같은 값이라 v3 (와 C++ 모델) 의 zr*zi 결과와 비트 단위로 같다.
//   s 가 W + 1 비트라서 18 x 18 곱셈기 3 개로 제곱하려면 W + 1 <= 35, 즉 W <= 34.
//
//   단 (X -> S -> E -> M -> Q -> A -> B -> F -> X, 픽셀 8 개 인터리브):
//     X : F 에서 돌아온 값과 새 픽셀 중 고른 결과 (v3 와 같음)
//     S : s = zr + zi
//     E/M/Q : zr^2, zi^2, s^2 (mandel_sq 3 개, 지연 3)
//     A : |z|^2 = zr^2 + zi^2,  re = zr^2 - zi^2
//     B : im = s^2 - |z|^2,  탈출 판정 |z|^2 > 4
//     F : z' = (re, im) + c,  끝났는지
//   덧셈이 70 비트 가까이 길어서 v3 의 A 단 (덧셈 3 개 동시) 을 A / B 로 나눴다.
//   입력 / 출력 버퍼와 주차는 v3 와 같다.
// ---------------------------------------------------------------------------
(* shreg_extract = "no" *)
module mandel_ring #(
    parameter W    = 34,
    parameter FRAC = W - 4,
    parameter IW   = 10,
    parameter PW   = 17
) (
    input  wire                clk,
    input  wire                rst,
    input  wire       [IW-1:0] max_iter,     // 프레임 동안 고정
    // 입력 버퍼 (in_valid && in_ready 인 클럭에 채워진다)
    input  wire                in_valid,
    input  wire signed [W-1:0] in_re,
    input  wire signed [W-1:0] in_im,
    input  wire       [PW-1:0] in_idx,
    output wire                in_ready,
    // 출력 버퍼 (out_valid && out_ready 인 클럭에 비워진다)
    output reg                 out_valid,
    output reg        [PW-1:0] out_idx,
    output reg        [IW-1:0] out_iter,
    input  wire                out_ready,
    output wire                busy
);
    localparam [2*W:0] FOUR = {{(2*W-2*FRAC-2){1'b0}}, 1'b1, {(2*FRAC+2){1'b0}}};   // 4.0 (소수부 2*FRAC)
    localparam TW = FRAC + W;               // re / im 은 곱의 [TW-1:FRAC] 만 쓰므로 아래 TW 비트만 계산

    // ---- 입력 버퍼 -------------------------------------------------------------
    reg                 ib_valid;
    reg  signed [W-1:0] ib_re, ib_im;
    reg        [PW-1:0] ib_idx;
    assign in_ready = !ib_valid;

    // ---- X ------------------------------------------------------------------
    reg                 x_valid, x_dn;
    reg  signed [W-1:0] x_zr, x_zi, x_cr, x_ci;
    reg        [IW-1:0] x_n;
    reg        [PW-1:0] x_idx;

    // ---- S : s = zr + zi ------------------------------------------------------
    reg                 s_valid, s_dn;
    reg  signed [W:0]   s_zr, s_zi, s_s;    // 제곱기 입력 (W + 1 비트)
    reg  signed [W-1:0] s_cr, s_ci;
    reg        [IW-1:0] s_n;
    reg        [PW-1:0] s_idx;

    always @(posedge clk) begin
        s_zr  <= x_zr;
        s_zi  <= x_zi;
        s_s   <= x_zr + x_zi;
        s_cr  <= x_cr;
        s_ci  <= x_ci;
        s_n   <= x_n;
        s_idx <= x_idx;
        s_dn  <= x_dn;
    end

    // ---- E / M / Q : 제곱 3 개 (지연 3) ------------------------------------------
    wire signed [2*W+1:0] q_zr2, q_zi2, q_s2;
    mandel_sq #(.N(W + 1)) u_sq_r (.clk(clk), .a(s_zr), .p(q_zr2));
    mandel_sq #(.N(W + 1)) u_sq_i (.clk(clk), .a(s_zi), .p(q_zi2));
    mandel_sq #(.N(W + 1)) u_sq_s (.clk(clk), .a(s_s),  .p(q_s2));

    // 나머지 값은 3 클럭 늦춰서 같이 간다
    reg                 e_valid, m_valid, q_valid;
    reg                 e_dn, m_dn, q_dn;
    reg  signed [W-1:0] e_cr, e_ci, m_cr, m_ci, q_cr, q_ci;
    reg        [IW-1:0] e_n, m_n, q_n;
    reg        [PW-1:0] e_idx, m_idx, q_idx;

    always @(posedge clk) begin
        e_cr <= s_cr;  m_cr <= e_cr;  q_cr <= m_cr;
        e_ci <= s_ci;  m_ci <= e_ci;  q_ci <= m_ci;
        e_n  <= s_n;   m_n  <= e_n;   q_n  <= m_n;
        e_idx <= s_idx; m_idx <= e_idx; q_idx <= m_idx;
        e_dn <= s_dn;  m_dn <= e_dn;  q_dn <= m_dn;
    end

    // ---- A : |z|^2, re ----------------------------------------------------------
    reg                 a_valid, a_nmax, a_dn;
    reg        [2*W:0]  a_mag;
    reg        [TW-1:0] a_s2;
    reg  signed [W-1:0] a_re, a_cr, a_ci;
    reg        [IW-1:0] a_n;
    reg        [PW-1:0] a_idx;

    wire signed [TW-1:0] q_dre = q_zr2[TW-1:0] - q_zi2[TW-1:0];

    always @(posedge clk) begin
        a_mag  <= q_zr2[2*W:0] + q_zi2[2*W:0];     // 둘 다 0 이상, 합 < 2^(2W)
        a_re   <= q_dre[TW-1:FRAC];
        a_s2   <= q_s2[TW-1:0];
        a_nmax <= (q_n == max_iter);
        a_cr   <= q_cr;
        a_ci   <= q_ci;
        a_n    <= q_n;
        a_idx  <= q_idx;
        a_dn   <= q_dn;
    end

    // ---- B : im = s^2 - |z|^2, 탈출 판정 ------------------------------------------
    reg                 b_valid, b_esc, b_nmax, b_dn;
    reg  signed [W-1:0] b_re, b_im, b_cr, b_ci;
    reg        [IW-1:0] b_n;
    reg        [PW-1:0] b_idx;

    wire [TW-1:0] a_2ri = a_s2 - a_mag[TW-1:0];     // 2 zr zi (아래 TW 비트)

    always @(posedge clk) begin
        b_esc  <= (a_mag > FOUR);
        b_im   <= a_2ri[TW-1:FRAC];
        b_re   <= a_re;
        b_nmax <= a_nmax;
        b_cr   <= a_cr;
        b_ci   <= a_ci;
        b_n    <= a_n;
        b_idx  <= a_idx;
        b_dn   <= a_dn;
    end

    // ---- F ------------------------------------------------------------------
    reg                 f_valid, f_fin, f_dn;
    reg  signed [W-1:0] f_zr, f_zi, f_cr, f_ci;
    reg        [IW-1:0] f_n;
    reg        [PW-1:0] f_idx;

    always @(posedge clk) begin
        f_fin <= b_dn || b_esc || b_nmax;           // 주차 중이면 이미 끝난 픽셀
        f_zr  <= b_re + b_cr;
        f_zi  <= b_im + b_ci;
        f_cr  <= b_cr;
        f_ci  <= b_ci;
        f_n   <= b_n;
        f_idx <= b_idx;
        f_dn  <= b_dn;
    end

    // ---- F -> 출력 버퍼 / X (v3 와 같음) -------------------------------------------
    wire fin     = f_valid && f_fin;
    wire to_out  = fin && !out_valid;           // 출력 버퍼가 비어 있으면 결과를 옮긴다
    wire park    = fin && out_valid;            // 차 있으면 결과를 든 채 한 바퀴 더
    wire again   = f_valid && !f_fin;           // 아직 계산 중
    wire free    = !f_valid || to_out;          // X 자리가 비는가
    wire inject  = free && ib_valid;

    reg [3:0] inflight;                         // 링 안 픽셀 수 (최대 8)
    assign busy = (inflight != 0) || ib_valid || out_valid;

    always @(posedge clk) begin
        // X 자리: 계산 계속 / 주차 / 새 픽셀
        if (again || park) begin
            x_zr  <= f_zr;
            x_zi  <= f_zi;
            x_cr  <= f_cr;
            x_ci  <= f_ci;
            x_n   <= park ? f_n : f_n + 1'b1;
            x_idx <= f_idx;
            x_dn  <= park;
        end else begin
            x_zr  <= 0;
            x_zi  <= 0;
            x_cr  <= ib_re;
            x_ci  <= ib_im;
            x_n   <= 0;
            x_idx <= ib_idx;
            x_dn  <= 1'b0;
        end

        // 입력 버퍼
        if (in_valid && in_ready) begin
            ib_re  <= in_re;
            ib_im  <= in_im;
            ib_idx <= in_idx;
        end

        // 출력 버퍼
        if (to_out) begin
            out_idx  <= f_idx;
            out_iter <= f_n;
        end

        if (rst) begin
            ib_valid  <= 1'b0;
            x_valid   <= 1'b0;
            s_valid   <= 1'b0;
            e_valid   <= 1'b0;
            m_valid   <= 1'b0;
            q_valid   <= 1'b0;
            a_valid   <= 1'b0;
            b_valid   <= 1'b0;
            f_valid   <= 1'b0;
            out_valid <= 1'b0;
            inflight  <= 0;
        end else begin
            ib_valid  <= (ib_valid && !inject) || (in_valid && in_ready);
            x_valid   <= again || park || inject;
            s_valid   <= x_valid;
            e_valid   <= s_valid;
            m_valid   <= e_valid;
            q_valid   <= m_valid;
            a_valid   <= q_valid;
            b_valid   <= a_valid;
            f_valid   <= b_valid;
            out_valid <= (out_valid && !out_ready) || to_out;
            inflight  <= inflight + inject - to_out;
        end
    end
endmodule
