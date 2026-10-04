// ---------------------------------------------------------------------------
// sample_ff : 비동기 신호를 샘플링하는 플립플롭 하나 (메타스테빌리티가 생기는 곳)
//
//   계층을 유지해서(KEEP_HIERARCHY) UCF 에서 이름으로 찾을 수 있게 한다.
//   시뮬레이션에서는 sim/models.v 의 메타스테빌리티 모델로 바꿔 쓴다.
// ---------------------------------------------------------------------------
(* KEEP_HIERARCHY = "YES" *)
module sample_ff (
    input  wire clk,
    input  wire d,
    output reg  q
);
    always @(posedge clk) q <= d;
endmodule
