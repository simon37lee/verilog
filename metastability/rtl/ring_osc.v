// ---------------------------------------------------------------------------
// ring_osc : LUT 링 오실레이터 (Spartan-6). 보드의 어떤 클럭과도 무관한 진짜 비동기 신호.
//
//   NAND 1단 + 인버터 (STAGES-1) 단 = 홀수 번 반전 -> 스스로 발진한다.
//   주파수는 LUT/배선 지연, 온도, 전압에 따라 흔들린다 (그래서 비동기 테스트 신호로 좋다).
//   KEEP 이 없으면 합성/맵에서 체인이 지워진다. 시뮬레이션에서는 sim/models.v 모델 사용.
// ---------------------------------------------------------------------------
(* KEEP_HIERARCHY = "YES" *)
module ring_osc #(
    parameter STAGES = 31                 // 홀수
) (
    input  wire en,
    output wire out
);
    (* KEEP = "TRUE" *) wire [STAGES-1:0] n;

    LUT2 #(.INIT(4'b0111)) u_nand (.I0(n[STAGES-1]), .I1(en), .O(n[0]));   // ~(I0 & I1)

    genvar i;
    generate
        for (i = 1; i < STAGES; i = i + 1) begin : g_inv
            LUT1 #(.INIT(2'b01)) u_inv (.I0(n[i-1]), .O(n[i]));
        end
    endgenerate

    assign out = n[STAGES-1];
endmodule
