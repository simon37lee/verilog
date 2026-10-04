// ---------------------------------------------------------------------------
// tau_engine : 히스토그램 꼬리에서 메타스테빌리티 시정수 tau 를 계산한다 (clk_pix 도메인)
//
//   start 펄스 (수직 귀선 시작) 마다 두 히스토그램을 읽기 포트로 훑는다 (화면을 그리지 않는 동안).
//     1. 봉우리 칸 p (최댓값) 를 찾는다. 양 끝 칸 (0, 255) 은 범위 밖 값이 몰리는 곳이라 뺀다.
//     2. p 오른쪽에서 개수가 봉우리의 1/65536 이하로 처음 떨어지는 칸의 다음 칸 b0 부터를 꼬리로 한다.
//        클럭 지터로 퍼진 봉우리 몸통(가우시안)은 지수 꼬리보다 훨씬 빨리 줄어드므로 충분히 내려간
//        뒤부터 세야 몸통이 섞이지 않는다 (1/1024 로 하면 지터 1 칸에서도 tau 가 절반으로 나왔다).
//     3. 꼬리의 평균 초과 칸 수 m = sum((b - b0) * c) / sum(c)  (b >= b0)
//     4. 지수 분포 (칸마다 비율 r) 이면 m = r / (1 - r), tau(칸) = -1 / ln r = 1 / ln(1 + 1/m)
//        (m < 16 칸은 표 tau_lut.vh, 그 이상은 m + 0.5 로 근사). tau(0.1 ps) = tau(칸) * 탭 지연.
//   상태: 0 = 정상, 1 = WAIT (봉우리 < 2^14 또는 꼬리 개수 < 256, 256 개면 통계 오차 약 6%),
//         2 = EDGE (가장 많은 칸이 양 끝 칸 = 봉우리가 측정 범위 밖, SAMPLE_PHASE 조정 필요)
//   측정 원리상 지터 폭이 tau 보다 크면 꼬리가 몸통에 묻혀 tau 가 작게 나온다.
//
//   읽기: addr 를 내고 2 클럭 뒤에 데이터 (hist_display 의 hist_addr 레지스터 1 + RAM 출력 레지스터 1).
// ---------------------------------------------------------------------------
module tau_engine #(
    parameter TAP_X10_A = 250,            // 측정 회로 A 탭 지연 (0.1 ps 단위)
    parameter TAP_X10_B = 250,
    parameter TAIL_SHIFT = 16             // 꼬리 시작 = 봉우리 / 2^TAIL_SHIFT 아래 (WAIT 가 풀리려면 봉우리 약 2^(TAIL_SHIFT+8))
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg         active,            // 1 이면 히스토그램 읽기 포트를 이 모듈이 쓴다
    output reg  [7:0]  addr,
    input  wire [31:0] hist_a,
    input  wire [31:0] hist_b,
    output reg  [1:0]  status_a,          // 0: 정상, 1: WAIT, 2: EDGE
    output reg  [1:0]  status_b,
    output reg  [7:0]  peak_a,            // 봉우리 칸 (화면 확대 기준)
    output reg  [7:0]  peak_b,
    output reg  [15:0] bcd_a,             // tau 십진 4 자리 (백, 십, 일, 소수 첫째) 0.1 ps 단위
    output reg  [15:0] bcd_b
);
    `include "tau_lut.vh"

    localparam S_IDLE = 4'd0, S_PEAK = 4'd1, S_TAIL = 4'd2, S_DIV = 4'd3, S_MUL = 4'd4,
               S_BCD = 4'd5, S_DONE = 4'd6;
    reg [3:0] state;

    // ---- 읽기 파이프라인: 이번 클럭 데이터가 어느 칸인지 ------------------------
    reg       rd, rd_q1, rd_q;
    reg [7:0] bin_q1, bin_q;
    always @(posedge clk) begin
        rd_q1  <= rd;    bin_q1 <= addr;
        rd_q   <= rd_q1; bin_q  <= bin_q1;
    end
    wire last_q = rd_q && bin_q == 8'd255;

    // ---- 칸별 처리 (두 회로 동시에) -------------------------------------------
    reg [31:0] pk_a, pk_b, edge_a, edge_b;   // edge: 양 끝 칸 중 큰 값
    reg [7:0]  p_a, p_b, b0_a, b0_b;
    reg        f_a, f_b;                  // 꼬리 시작을 찾았음
    reg [47:0] s0_a, s0_b, s1_a, s1_b;

    wire inner = (bin_q != 8'd0) && (bin_q != 8'd255);
    wire hit_a = !f_a && bin_q > p_a && hist_a <= (pk_a >> TAIL_SHIFT);
    wire hit_b = !f_b && bin_q > p_b && hist_b <= (pk_b >> TAIL_SHIFT);
    wire [7:0] k_a = bin_q - b0_a;
    wire [7:0] k_b = bin_q - b0_b;

    // ---- 나눗셈 (복원형, 52 단계): q = (s1 << 4) / s0 ----------------------------
    reg        sel_b;                     // 0: A 계산 중, 1: B 계산 중
    reg [51:0] num;
    reg [47:0] den;
    reg [48:0] rem;
    reg [51:0] quo;
    reg [5:0]  step;
    wire [48:0] rem_sh  = {rem[47:0], num[51]};
    wire        rem_ge  = rem_sh >= {1'b0, den};

    // ---- tau(0.1 ps) = tau16 * TAP / 16 -> 십진 4 자리 ---------------------------
    wire [9:0]  tap   = sel_b ? TAP_X10_B : TAP_X10_A;
    wire [51:0] tau16 = (quo < 52'd256) ? {40'd0, tau16_lut(quo[7:0])} : quo + 52'd8;
    wire [63:0] prod  = {12'd0, tau16} * tap;
    wire [59:0] tau_x10 = prod[63:4];
    reg  [15:0] bcd;
    reg  [1:0]  dig;                      // 0: 백 ps, 1: 십 ps, 2: 일 ps, 3: 0.1 ps
    reg  [13:0] rest;
    wire [13:0] pow10 = (dig == 2'd0) ? 14'd1000 : (dig == 2'd1) ? 14'd100 : 14'd10;

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            active  <= 1'b0;
            rd      <= 1'b0;
            status_a <= 2'd1;
            status_b <= 2'd1;
            peak_a   <= 0;
            peak_b   <= 0;
            bcd_a   <= 0;
            bcd_b   <= 0;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    active <= 1'b1;
                    rd     <= 1'b1;
                    addr   <= 0;
                    pk_a <= 0; pk_b <= 0; p_a <= 0; p_b <= 0; edge_a <= 0; edge_b <= 0;
                    state  <= S_PEAK;
                end

                // 1 단계: 봉우리
                S_PEAK: begin
                    if (rd) addr <= addr + 1'b1;
                    if (rd && addr == 8'd255) rd <= 1'b0;
                    if (rd_q && inner) begin
                        if (hist_a > pk_a) begin pk_a <= hist_a; p_a <= bin_q; end
                        if (hist_b > pk_b) begin pk_b <= hist_b; p_b <= bin_q; end
                    end
                    if (rd_q && !inner) begin
                        if (hist_a > edge_a) edge_a <= hist_a;
                        if (hist_b > edge_b) edge_b <= hist_b;
                    end
                    if (last_q) begin
                        rd    <= 1'b1;
                        addr  <= 0;
                        f_a <= 0; f_b <= 0;
                        s0_a <= 0; s1_a <= 0; s0_b <= 0; s1_b <= 0;
                        state <= S_TAIL;
                    end
                end

                // 2, 3 단계: 꼬리 시작 + 합
                S_TAIL: begin
                    if (rd) addr <= addr + 1'b1;
                    if (rd && addr == 8'd255) rd <= 1'b0;
                    if (rd_q && inner) begin
                        // 기준 아래로 처음 떨어진 칸은 빼고 다음 칸부터 (몸통이 제일 많이 섞인 칸)
                        if (hit_a) begin f_a <= 1'b1; b0_a <= bin_q + 1'b1; end
                        if (hit_b) begin f_b <= 1'b1; b0_b <= bin_q + 1'b1; end
                        if (f_a) begin s0_a <= s0_a + hist_a; s1_a <= s1_a + k_a * hist_a; end
                        if (f_b) begin s0_b <= s0_b + hist_b; s1_b <= s1_b + k_b * hist_b; end
                    end
                    if (last_q) begin
                        active <= 1'b0;
                        sel_b  <= 1'b0;
                        num    <= {s1_a, 4'b0000};
                        den    <= s0_a;
                        rem    <= 0;
                        step   <= 0;
                        state  <= S_DIV;
                    end
                end

                S_DIV: begin
                    rem  <= rem_ge ? rem_sh - {1'b0, den} : rem_sh;
                    quo  <= {quo[50:0], rem_ge};
                    num  <= {num[50:0], 1'b0};
                    step <= step + 1'b1;
                    if (step == 6'd51) state <= S_MUL;
                end

                S_MUL: begin
                    rest  <= (tau_x10 > 60'd9999) ? 14'd9999 : tau_x10[13:0];   // 999.9 ps 에서 포화
                    bcd   <= 0;
                    dig   <= 0;
                    state <= S_BCD;
                end

                S_BCD: begin                       // 자리마다 빼기 (한 클럭에 한 번, 최대 9 번)
                    if (dig == 2'd3) begin
                        bcd[3:0] <= rest[3:0];
                        state    <= S_DONE;
                    end else if (rest >= pow10) begin
                        rest <= rest - pow10;
                        bcd  <= bcd + (16'h1 << (4 * (3 - dig)));
                    end else begin
                        dig <= dig + 1'b1;
                    end
                end

                S_DONE: begin
                    if (!sel_b) begin
                        bcd_a    <= bcd;
                        peak_a   <= p_a;
                        status_a <= (edge_a > pk_a) ? 2'd2 :
                                    ((pk_a >= 32'h4000) && f_a && (s0_a >= 256)) ? 2'd0 : 2'd1;
                        sel_b   <= 1'b1;
                        num     <= {s1_b, 4'b0000};
                        den     <= s0_b;
                        rem     <= 0;
                        step    <= 0;
                        state   <= S_DIV;
                    end else begin
                        bcd_b    <= bcd;
                        peak_b   <= p_b;
                        status_b <= (edge_b > pk_b) ? 2'd2 :
                                    ((pk_b >= 32'h4000) && f_b && (s0_b >= 256)) ? 2'd0 : 2'd1;
                        state   <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
