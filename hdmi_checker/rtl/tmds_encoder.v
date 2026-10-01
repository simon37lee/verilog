// ---------------------------------------------------------------------------
// tmds_encoder : DVI 1.0 규격 TMDS 8b/10b 인코더
//
//   1단계: 천이(transition) 최소화  - XOR 또는 XNOR 체인으로 9비트 q_m 생성
//   2단계: DC 밸런스             - 누적 불균형(cnt)에 따라 비트 반전 여부 결정
//   de = 0 구간에서는 {c1, c0} 에 해당하는 컨트롤 토큰을 출력한다.
//   출력 q_out[0] 이 가장 먼저 전송되는 비트이다.
// ---------------------------------------------------------------------------
module tmds_encoder (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] d,
    input  wire       c0,
    input  wire       c1,
    input  wire       de,
    output reg  [9:0] q_out
);
    // 1 의 개수 (루프 대신 덧셈식으로 써야 Verilator 시뮬레이션이 빠르다)
    function [3:0] popcount8;
        input [7:0] v;
        popcount8 = {3'b0, v[0]} + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
    endfunction

    // ---- 1단계: 천이 최소화 ------------------------------------------------
    wire [3:0] n1_d      = popcount8(d);
    wire       use_xnor  = (n1_d > 4) || (n1_d == 4 && d[0] == 1'b0);

    // XOR 체인: q_m[i] = d[0] ^ d[1] ^ ... ^ d[i]  (prefix XOR)
    // XNOR 체인: 단계마다 반전이 한 번씩 더해지므로 홀수 비트만 반전 (^ 8'b10101010)
    // 비트 단위 체인 대신 벡터 연산 3번으로 계산 (Verilator 시뮬레이션이 훨씬 빠르다)
    wire [7:0] px1  = d   ^ {d[6:0],   1'b0};
    wire [7:0] px2  = px1 ^ {px1[5:0], 2'b0};
    wire [7:0] pxor = px2 ^ {px2[3:0], 4'b0};
    wire [8:0] q_m  = {~use_xnor, pxor ^ (use_xnor ? 8'hAA : 8'h00)};

    // ---- 2단계: DC 밸런스 --------------------------------------------------
    wire [3:0] n1_q = popcount8(q_m[7:0]);
    wire [3:0] n0_q = 4'd8 - n1_q;
    // (n1 - n0), (n0 - n1) 을 부호 있는 5비트로
    wire signed [4:0] diff_1_0 = $signed({1'b0, n1_q}) - $signed({1'b0, n0_q});
    wire signed [4:0] diff_0_1 = -diff_1_0;

    reg signed [4:0] cnt;   // 누적 불균형 (1의 개수 - 0의 개수)

    always @(posedge clk) begin
        if (rst) begin
            q_out <= 10'd0;
            cnt   <= 5'sd0;
        end else if (!de) begin
            cnt <= 5'sd0;
            case ({c1, c0})
                2'b00: q_out <= 10'b1101010100;
                2'b01: q_out <= 10'b0010101011;
                2'b10: q_out <= 10'b0101010100;
                2'b11: q_out <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || n1_q == n0_q) begin
            q_out <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            cnt   <= q_m[8] ? cnt + diff_1_0 : cnt + diff_0_1;
        end else if ((cnt > 0 && n1_q > n0_q) || (cnt < 0 && n0_q > n1_q)) begin
            q_out <= {1'b1, q_m[8], ~q_m[7:0]};
            cnt   <= cnt + (q_m[8] ? 5'sd2 : 5'sd0) + diff_0_1;
        end else begin
            q_out <= {1'b0, q_m[8], q_m[7:0]};
            cnt   <= cnt - (q_m[8] ? 5'sd0 : 5'sd2) + diff_1_0;
        end
    end
endmodule
