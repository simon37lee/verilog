// ---------------------------------------------------------------------------
// rr_arb : 라운드로빈 중재기 (조합 회로 grant + 우선순위 마스크 레지스터)
//
//   mask = 마지막으로 고른 요청보다 번호가 큰 쪽. 그중 요청이 있으면 가장 낮은 번호,
//   없으면 전체에서 가장 낮은 번호를 고른다 (x & -x = 가장 낮은 1 비트).
//   고른 것이 있으면 다음 클럭부터 그 다음 번호가 가장 높은 우선순위가 된다.
// ---------------------------------------------------------------------------
module rr_arb #(
    parameter N = 4
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [N-1:0] req,
    output wire [N-1:0] gnt        // one-hot (요청이 없으면 0)
);
    reg  [N-1:0] mask;
    wire [N-1:0] req_hi = req & mask;
    wire [N-1:0] pick   = (req_hi != 0) ? req_hi : req;
    assign gnt = pick & (~pick + 1'b1);

    always @(posedge clk) begin
        if (rst)           mask <= {N{1'b1}};
        else if (gnt != 0) mask <= ~((gnt << 1) - 1'b1);
    end
endmodule
