// ---------------------------------------------------------------------------
// mandel_sq (v4) : N 비트 부호 있는 수의 제곱을 DSP48A1 (18 x 18 부호 있는 곱셈기) 3 개로 (지연 3 클럭)
//
//   a = h * 2^L + l      h = 위 18 비트 (부호 있음), l = 아래 L = N - 18 비트 (부호 없음, L <= 17)
//   a^2 = h^2 * 2^2L + 2 h l * 2^L + l^2
//       = {h^2, l^2} + (h l << (L + 1))      l^2 < 2^2L 라서 앞의 두 항은 이어 붙이기만 하면 된다
//
//     E : h, l 을 레지스터에 (DSP A / B 입력 레지스터)
//     M : h*h, h*l, l*l (DSP M 레지스터)
//     Q : 위 식의 덧셈 하나 (아래 L + 1 비트는 덧셈 없이 그대로)
//   일반 곱셈 (a * b) 은 h*h, h*l, l*h, l*l 4 개가 필요하지만 제곱은 h*l 이 두 번 나와서 3 개다.
// ---------------------------------------------------------------------------
module mandel_sq #(
    parameter N = 35                        // 19 ~ 35
) (
    input  wire                 clk,
    input  wire signed [N-1:0]  a,
    output reg  signed [2*N-1:0] p
);
    localparam L = N - 18;

    reg  signed [17:0]  e_h;
    reg         [L-1:0] e_l;
    reg  signed [35:0]  m_hh, m_hl;
    reg       [2*L-1:0] m_ll;

    always @(posedge clk) begin
        e_h  <= a[N-1:L];
        e_l  <= a[L-1:0];
        m_hh <= e_h * e_h;
        m_hl <= e_h * $signed({1'b0, e_l});
        m_ll <= e_l * e_l;
        p    <= $signed({m_hh, m_ll}) + ($signed(m_hl) <<< (L + 1));
    end
endmodule
