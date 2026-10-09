// ---------------------------------------------------------------------------
// matrix_system : 매트릭스 화면 보호기 (1280x720 @ 60 Hz, 클럭 하나)
//
//   video_timing -> matrix_display (셀 RAM 읽기) -> RGB
//   matrix_engine (버전마다 다름, rtl/vN/) 이 vblank 동안 셀 RAM 을 고친다.
//
//   클럭은 픽셀 클럭 하나 (보드 74.0 MHz, 규격 74.25 MHz). 엔진도 같은 클럭.
//   cell_we / cell_waddr / cell_wdata 는 시뮬레이션 검사기용 (셀 RAM 쓰기를 그대로 내보냄)
// ---------------------------------------------------------------------------
module matrix_system (
    input  wire        clk,
    input  wire        rst,                 // 비동기 리셋 (안에서 동기화)
    output wire [7:0]  r,
    output wire [7:0]  g,
    output wire [7:0]  b,
    output wire        de,
    output wire        hsync,
    output wire        vsync,
    output wire        cell_we,
    output wire [11:0] cell_waddr,
    output wire [11:0] cell_wdata,
    output reg  [15:0] frames               // vblank 수
);
    // ---- 리셋 동기화 -----------------------------------------------------------------
    reg [2:0] rst_sr = 3'b111;
    always @(posedge clk or posedge rst)
        if (rst) rst_sr <= 3'b111;
        else     rst_sr <= {rst_sr[1:0], 1'b0};
    wire rst_s = rst_sr[2];

    // ---- 1280x720 @ 60 Hz (CEA-861, sync 양극성) --------------------------------------
    wire [11:0] x, y;
    wire        t_de, t_hs, t_vs;
    video_timing #(
        .H_ACTIVE(1280), .H_FP(110), .H_SYNC(40), .H_BP(220),
        .V_ACTIVE(720),  .V_FP(5),   .V_SYNC(5),  .V_BP(20),
        .HS_POL(1), .VS_POL(1)
    ) u_timing (
        .clk(clk), .rst(rst_s), .x(x), .y(y), .de(t_de), .hsync(t_hs), .vsync(t_vs)
    );

    wire vblank_start = (y == 12'd720) && (x == 12'd0);
    always @(posedge clk)
        if (rst_s)             frames <= 16'd0;
        else if (vblank_start) frames <= frames + 1'b1;

    // ---- 셀 RAM (80 x 30 칸, 12 비트) --------------------------------------------------
    wire [11:0] rd_addr, rd_data, eng_rdata;
    dpram #(.DW(12), .AW(12), .DEPTH(4096)) u_cells (
        .clk_a(clk), .we_a(cell_we), .addr_a(cell_waddr), .wdata_a(cell_wdata), .rdata_a(eng_rdata),
        .clk_b(clk), .addr_b(rd_addr), .rdata_b(rd_data)
    );

    matrix_engine u_engine (
        .clk(clk), .rst(rst_s), .vblank_start(vblank_start),
        .we(cell_we), .addr(cell_waddr), .wdata(cell_wdata), .rdata(eng_rdata)
    );

    matrix_display u_display (
        .clk(clk), .rst(rst_s),
        .x(x), .y(y), .de_in(t_de), .hs_in(t_hs), .vs_in(t_vs),
        .cell_addr(rd_addr), .cell_data(rd_data),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync)
    );
endmodule
