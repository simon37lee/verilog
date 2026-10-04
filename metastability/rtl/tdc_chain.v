// ---------------------------------------------------------------------------
// tdc_chain : carry chain 지연선 TDC (Spartan-6 CARRY4, 탭당 수십 ps)
//
//   din 의 변화가 carry chain 을 따라 전파되고, clk_s 에지에서 모든 탭을 동시에 샘플링한다.
//   -> taps 에서 "새 값" 이 된 탭 수 = din 이 바뀐 뒤 clk_s 까지 흐른 시간 / 탭 지연
//   din 이 늦게 바뀔수록 (메타스테빌리티로 결정이 늦어질수록) 새 값인 탭 수가 줄어든다.
//
//   S = 1111, DI = 0000 이면 CARRY4 는 carry 입력을 그대로 넘기는 지연선이 된다.
//   din -> taps 경로는 타이밍을 맞추는 경로가 아니다 (UCF 에서 TIG).
//   시뮬레이션에서는 sim/models.v 의 동작 모델로 바꿔 쓴다.
// ---------------------------------------------------------------------------
(* KEEP_HIERARCHY = "YES" *)
module tdc_chain #(
    parameter N4 = 64                     // CARRY4 개수 (탭 수 = 4 * N4)
) (
    input  wire              clk_s,
    input  wire              din,
    output reg  [4*N4-1:0]   taps
);
    wire [4*N4-1:0] co;

    genvar i;
    generate
        for (i = 0; i < N4; i = i + 1) begin : g_c4
            if (i == 0) begin : g_first
                CARRY4 u_c4 (
                    .CO(co[3:0]), .O(), .CI(1'b0), .CYINIT(din),
                    .DI(4'b0000), .S(4'b1111)
                );
            end else begin : g_next
                CARRY4 u_c4 (
                    .CO(co[4*i+3:4*i]), .O(), .CI(co[4*i-1]), .CYINIT(1'b0),
                    .DI(4'b0000), .S(4'b1111)
                );
            end
        end
    endgenerate

    always @(posedge clk_s) taps <= co;
endmodule
