// ---------------------------------------------------------------------------
// models : 시뮬레이션 전용 동작 모델 (rtl/ 의 Spartan-6 전용 모듈 대신 쓴다)
//
//   sample_ff : 메타스테빌리티 모델. 데이터가 클럭 에지 직전 T0_PS 안에 바뀌었으면
//               출력이 TCO_PS + (지수 분포, 평균 TAU_PS) 만큼 늦게 결정되고 값은 무작위.
//               (RTL 시뮬레이션은 이것을 스스로 재현하지 못하므로 직접 모델링한다)
//   tdc_chain : 지연선 모델. din 이 마지막으로 바뀐 시각부터 clk_s 까지
//               (시간 - ROUTE_PS) / TAP_PS 개의 탭이 새 값.
//   ring_osc  : 반주기에 무작위 지터가 섞인 비동기 클럭.
// ---------------------------------------------------------------------------
`timescale 1ps / 1ps

module sample_ff #(
    parameter real TCO_PS = 400.0,
    parameter real T0_PS  = 300.0,
    parameter real TAU_PS = 40.0
) (
    input  wire clk,
    input  wire d,
    output reg  q
);
    integer t0 = T0_PS;                   // 테스트벤치가 바꿀 수 있다
    time t_d = 0;
    always @(posedge d or negedge d) t_d = $time;   // (Verilator 는 @(d) 를 조합 논리로 본다)

    // 지연은 정수 변수로 계산해서 쓴다 (Verilator --timing 은 지연 자리의 수식/실수를 잘못 다룬다)
    real    u;
    integer dly;
    reg     v;
    initial q = 1'b0;
    always @(posedge clk) begin
        if ($time - t_d < t0) begin
            u   = (($random & 32'h7FFFFFFF) + 1.0) / 2147483649.0;
            dly = $rtoi(TCO_PS - TAU_PS * $ln(u));
            v   = $random;
        end else begin
            dly = $rtoi(TCO_PS);
            v   = d;
        end
        q <= #(dly) v;
    end
endmodule

module tdc_chain #(
    parameter N4       = 64,
    parameter ROUTE_PS = 800,
    parameter TAP_PS   = 20
) (
    input  wire            clk_s,
    input  wire            din,
    output reg [4*N4-1:0]  taps
);
    localparam NT = 4 * N4;
    integer route = ROUTE_PS;             // 테스트벤치가 회로마다 다르게 바꿀 수 있다
    time t_chg = 0;
    reg  cur   = 1'b0;
    always @(posedge din or negedge din) begin
        t_chg = $time;
        cur   = din;
    end

    integer       n;
    reg [NT-1:0]  mask;
    always @(posedge clk_s) begin
        if ($time < t_chg + route) n = 0;
        else                       n = ($time - t_chg - route) / TAP_PS;
        if (n > NT) n = NT;
        mask = (n == 0) ? {NT{1'b0}} : ({NT{1'b1}} >> (NT - n));
        taps <= cur ? mask : ~mask;
    end
endmodule

module ring_osc #(
    parameter STAGES  = 31,
    parameter HALF_PS = 23000
) (
    input  wire en,
    output reg  out
);
    integer half;
    initial out = 1'b0;
    always begin
        half = HALF_PS + ($random % 400);
        #(half);
        if (en) out = ~out;
    end
endmodule
