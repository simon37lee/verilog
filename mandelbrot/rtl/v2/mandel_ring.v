// ---------------------------------------------------------------------------
// mandel_ring (v2) : 4 단 파이프라인 링 - 픽셀 4 개를 돌려 가며 매 클럭 반복 1 회
//
//   반복 1 회를 4 단으로 나누고, 마지막 단의 출력을 첫 단으로 되돌린다 (링).
//   단마다 서로 다른 픽셀이 들어 있으므로 링 전체로는 매 클럭 반복 1 회를 한다.
//
//     E : 입력 레지스터   zr, zi (곱셈기 입력. XST 가 DSP48A1 의 A/B 레지스터로 넣는다)
//     M : 곱셈            zr^2, zi^2, zr*zi (2W 비트, DSP48A1 의 M 레지스터)
//     A : 덧셈            |z|^2 = zr^2 + zi^2,  zr^2 - zi^2,  2 zr zi (W 비트로 자름),  n == max_iter
//     F : 판정 / 다음 z   fin = |z|^2 > 4 또는 n == max_iter,  zr' = .. + cr,  zi' = .. + ci
//     F -> E : fin 이 아니면 (zr', zi', n + 1) 을 되돌리고,
//              fin 이면 결과를 내보내고 (out_valid) 그 자리에 새 픽셀을 넣는다 (in_ready)
//
//   계산은 v1 mandel_core 와 비트 단위로 같다 (반복 횟수 n 의 정의도 같음).
//
//   SLOTS : 링 안에 동시에 넣을 최대 픽셀 수 (1 ~ 4). 4 가 정상.
//           1 이면 "파이프라인만 하고 인터리브는 안 한" 구조 -> 반복 1 회가 4 클럭 (비교 실험용)
// ---------------------------------------------------------------------------
module mandel_ring #(
    parameter W     = 18,
    parameter FRAC  = W - 4,
    parameter IW    = 8,
    parameter PW    = 17,
    parameter SLOTS = 4
) (
    input  wire                clk,
    input  wire                rst,
    input  wire       [IW-1:0] max_iter,     // 프레임 동안 고정
    // 새 픽셀 넣기 (in_valid && in_ready 인 클럭에 들어간다)
    input  wire                in_valid,
    input  wire signed [W-1:0] in_re,
    input  wire signed [W-1:0] in_im,
    input  wire       [PW-1:0] in_idx,
    output wire                in_ready,
    // 결과 (1 클럭 펄스, 순서는 들어간 순서와 다를 수 있다)
    output wire                out_valid,
    output wire       [PW-1:0] out_idx,
    output wire       [IW-1:0] out_iter,
    output wire                busy          // 링에 픽셀이 하나라도 있음
);
    localparam [2*W:0] FOUR = {{(2*W-2*FRAC-2){1'b0}}, 1'b1, {(2*FRAC+2){1'b0}}};   // 4.0 (소수부 2*FRAC)

    // ---- E ------------------------------------------------------------------
    reg                 e_valid;
    reg  signed [W-1:0] e_zr, e_zi, e_cr, e_ci;
    reg        [IW-1:0] e_n;
    reg        [PW-1:0] e_idx;

    // ---- M ------------------------------------------------------------------
    reg                   m_valid;
    reg  signed [2*W-1:0] m_zr2, m_zi2, m_zri;
    reg  signed [W-1:0]   m_cr, m_ci;
    reg        [IW-1:0]   m_n;
    reg        [PW-1:0]   m_idx;

    always @(posedge clk) begin
        m_zr2 <= e_zr * e_zr;
        m_zi2 <= e_zi * e_zi;
        m_zri <= e_zr * e_zi;
        m_cr  <= e_cr;
        m_ci  <= e_ci;
        m_n   <= e_n;
        m_idx <= e_idx;
    end

    // ---- A ------------------------------------------------------------------
    reg                 a_valid, a_nmax;
    reg        [2*W:0]  a_mag;
    reg  signed [W-1:0] a_re, a_im, a_cr, a_ci;
    reg        [IW-1:0] a_n;
    reg        [PW-1:0] a_idx;

    wire signed [2*W-1:0] m_dre = m_zr2 - m_zi2;

    always @(posedge clk) begin
        a_mag  <= {1'b0, m_zr2} + {1'b0, m_zi2};       // 둘 다 0 이상
        a_re   <= m_dre[FRAC+W-1:FRAC];                 // (zr^2 - zi^2) >> FRAC
        a_im   <= m_zri[FRAC+W-2:FRAC-1];               // (2 zr zi) >> FRAC
        a_nmax <= (m_n == max_iter);
        a_cr   <= m_cr;
        a_ci   <= m_ci;
        a_n    <= m_n;
        a_idx  <= m_idx;
    end

    // ---- F ------------------------------------------------------------------
    reg                 f_valid, f_fin;
    reg  signed [W-1:0] f_zr, f_zi, f_cr, f_ci;
    reg        [IW-1:0] f_n;
    reg        [PW-1:0] f_idx;

    always @(posedge clk) begin
        f_fin <= (a_mag > FOUR) || a_nmax;
        f_zr  <= a_re + a_cr;
        f_zi  <= a_im + a_ci;
        f_cr  <= a_cr;
        f_ci  <= a_ci;
        f_n   <= a_n;
        f_idx <= a_idx;
    end

    // ---- F -> E : 되돌리기 또는 새 픽셀 -----------------------------------------
    wire again = f_valid && !f_fin;             // 아직 계산 중인 픽셀이 E 자리를 쓴다

    assign out_valid = f_valid && f_fin;
    assign out_idx   = f_idx;
    assign out_iter  = f_n;

    // 링 안 픽셀 수 (SLOTS 제한용). 이번 클럭에 나가는 픽셀은 빼고 센다
    reg  [2:0] inflight;
    wire [2:0] inflight_after = inflight - out_valid;
    assign in_ready = !again && (inflight_after < SLOTS);
    wire   inject   = in_valid && in_ready;
    assign busy     = (inflight != 0);

    always @(posedge clk) begin
        if (again) begin
            e_zr  <= f_zr;
            e_zi  <= f_zi;
            e_cr  <= f_cr;
            e_ci  <= f_ci;
            e_n   <= f_n + 1'b1;
            e_idx <= f_idx;
        end else begin
            e_zr  <= 0;
            e_zi  <= 0;
            e_cr  <= in_re;
            e_ci  <= in_im;
            e_n   <= 0;
            e_idx <= in_idx;
        end

        if (rst) begin
            e_valid  <= 1'b0;
            m_valid  <= 1'b0;
            a_valid  <= 1'b0;
            f_valid  <= 1'b0;
            inflight <= 0;
        end else begin
            e_valid  <= again || inject;
            m_valid  <= e_valid;
            a_valid  <= m_valid;
            f_valid  <= a_valid;
            inflight <= inflight_after + inject;
        end
    end
endmodule
