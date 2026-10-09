// ---------------------------------------------------------------------------
// mandel_ring (v3) : 5 단 파이프라인 링 + 1 칸 입력 / 출력 버퍼
//
//   계산은 v2 와 같고, 링에 X 단을 하나 더 넣었다 (X -> E -> M -> A -> F -> X, 픽셀 5 개 인터리브).
//     X : F 에서 돌아온 값과 새 픽셀 중 고른 결과 (일반 레지스터)
//     E : X 를 그대로 받는 곱셈기 입력 (DSP48A1 A/B 레지스터)
//   v2 처럼 선택 회로가 바로 곱셈기 입력 레지스터로 가면, 선택 신호 하나가 100 비트 가까이 몰고 가서
//   링 19 개로 붐빌 때 배선이 길어진다 (166.7 MHz 에서 -1.6 ns). 단을 늘려도 링은 단 수만큼 픽셀을
//   담으므로 처리량은 그대로다.
//   cr / ci / n / idx 를 단마다 옮기는 레지스터 사슬은 SRL (LUT 시프트 레지스터) 로 바꾸지 않는다
//   (SRL 은 셋업이 길어서 같은 이유로 실패했다).
//   링을 여러 개 붙일 때 바깥 (생성기, 쓰기 중재기) 과 같은 클럭 안에서 주고받지 않도록
//   양쪽에 1 칸 버퍼를 둔다. in_ready / out_valid 가 모두 레지스터 출력이라서
//   바깥의 선택 회로가 링 안 경로와 이어지지 않는다.
//
//     입력 버퍼 : 비어 있으면 in_ready = 1. 바깥이 채워 두면 F 자리가 빌 때 링이 꺼내 넣는다
//     출력 버퍼 : F 에서 끝난 픽셀을 옮긴다. 바깥이 out_ready 로 가져가면 비워진다
//     주차      : 끝났는데 출력 버퍼가 차 있으면 결과 (n) 를 든 채로 링을 한 바퀴 더 돈다 (dn = 1).
//                 그 자리는 그동안 못 쓰지만 링은 멈추지 않는다
// ---------------------------------------------------------------------------
(* shreg_extract = "no" *)
module mandel_ring #(
    parameter W    = 18,
    parameter FRAC = W - 4,
    parameter IW   = 8,
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

    // ---- E ------------------------------------------------------------------
    reg                 e_valid, e_dn;
    reg  signed [W-1:0] e_zr, e_zi, e_cr, e_ci;
    reg        [IW-1:0] e_n;
    reg        [PW-1:0] e_idx;

    always @(posedge clk) begin
        e_zr  <= x_zr;
        e_zi  <= x_zi;
        e_cr  <= x_cr;
        e_ci  <= x_ci;
        e_n   <= x_n;
        e_idx <= x_idx;
        e_dn  <= x_dn;
    end

    // ---- M ------------------------------------------------------------------
    reg                   m_valid, m_dn;
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
        m_dn  <= e_dn;
    end

    // ---- A ------------------------------------------------------------------
    reg                 a_valid, a_nmax, a_dn;
    reg        [2*W:0]  a_mag;
    reg  signed [W-1:0] a_re, a_im, a_cr, a_ci;
    reg        [IW-1:0] a_n;
    reg        [PW-1:0] a_idx;

    wire signed [2*W-1:0] m_dre = m_zr2 - m_zi2;

    always @(posedge clk) begin
        a_mag  <= {1'b0, m_zr2} + {1'b0, m_zi2};
        a_re   <= m_dre[FRAC+W-1:FRAC];
        a_im   <= m_zri[FRAC+W-2:FRAC-1];
        a_nmax <= (m_n == max_iter);
        a_cr   <= m_cr;
        a_ci   <= m_ci;
        a_n    <= m_n;
        a_idx  <= m_idx;
        a_dn   <= m_dn;
    end

    // ---- F ------------------------------------------------------------------
    reg                 f_valid, f_fin, f_dn;
    reg  signed [W-1:0] f_zr, f_zi, f_cr, f_ci;
    reg        [IW-1:0] f_n;
    reg        [PW-1:0] f_idx;

    always @(posedge clk) begin
        f_fin <= a_dn || (a_mag > FOUR) || a_nmax;     // 주차 중이면 이미 끝난 픽셀
        f_zr  <= a_re + a_cr;
        f_zi  <= a_im + a_ci;
        f_cr  <= a_cr;
        f_ci  <= a_ci;
        f_n   <= a_n;
        f_idx <= a_idx;
        f_dn  <= a_dn;
    end

    // ---- F -> 출력 버퍼 / X ------------------------------------------------------
    wire fin     = f_valid && f_fin;
    wire to_out  = fin && !out_valid;           // 출력 버퍼가 비어 있으면 결과를 옮긴다
    wire park    = fin && out_valid;            // 차 있으면 결과를 든 채 한 바퀴 더
    wire again   = f_valid && !f_fin;           // 아직 계산 중
    wire free    = !f_valid || to_out;          // X 자리가 비는가
    wire inject  = free && ib_valid;

    reg [2:0] inflight;
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
            e_valid   <= 1'b0;
            m_valid   <= 1'b0;
            a_valid   <= 1'b0;
            f_valid   <= 1'b0;
            out_valid <= 1'b0;
            inflight  <= 0;
        end else begin
            ib_valid  <= (ib_valid && !inject) || (in_valid && in_ready);
            x_valid   <= again || park || inject;
            e_valid   <= x_valid;
            m_valid   <= e_valid;
            a_valid   <= m_valid;
            f_valid   <= a_valid;
            out_valid <= (out_valid && !out_ready) || to_out;
            inflight  <= inflight + inject - to_out;
        end
    end
endmodule
