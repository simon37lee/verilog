// ---------------------------------------------------------------------------
// dpram : 듀얼 클럭 듀얼 포트 RAM (FPGA Block RAM 추론용)
//
//   port A (clk_a) : 읽기/쓰기  - 엔진 (셀 RAM 고치기)
//   port B (clk_b) : 읽기 전용  - 화면 (matrix_display)
//   두 포트 모두 읽기 지연 1 클럭 (registered output)
// ---------------------------------------------------------------------------
module dpram #(
    parameter DW    = 8,
    parameter AW    = 18,
    parameter DEPTH = 160000
) (
    // port A
    input  wire          clk_a,
    input  wire          we_a,
    input  wire [AW-1:0] addr_a,
    input  wire [DW-1:0] wdata_a,
    output reg  [DW-1:0] rdata_a,
    // port B
    input  wire          clk_b,
    input  wire [AW-1:0] addr_b,
    output reg  [DW-1:0] rdata_b
);
    reg [DW-1:0] mem [0:DEPTH-1];

    always @(posedge clk_a) begin
        if (we_a)
            mem[addr_a] <= wdata_a;
        rdata_a <= mem[addr_a];
    end

    always @(posedge clk_b)
        rdata_b <= mem[addr_b];
endmodule
