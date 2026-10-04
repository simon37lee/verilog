// ---------------------------------------------------------------------------
// dma_display_top : 합성용 최상위. 타겟2 직접 전송 버스를 그대로 연결한다.
//   (시뮬레이션에서는 이 연결 대신 하네스의 배선 지연/메타스테빌리티 모델을 사용)
// ---------------------------------------------------------------------------
module dma_display_top (
    input  wire       clk_src,
    input  wire       clk_tgt,
    input  wire       clk_pix,
    input  wire       rst,
    output wire [7:0] r,
    output wire [7:0] g,
    output wire [7:0] b,
    output wire       de,
    output wire       hsync,
    output wire       vsync
);
    wire        n2_valid;
    wire [17:0] n2_addr;
    wire [7:0]  n2_data;
    wire [4:0]  f_wgray, f_rgray;

    dma_display_core u_core (
        .clk_src(clk_src), .clk_tgt(clk_tgt), .clk_pix(clk_pix), .rst(rst), .errmap_mode(1'b0),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
        .n2_valid(n2_valid), .n2_addr(n2_addr), .n2_data(n2_data),
        // CDC 없이 직결 (의도적인 버그)
        .t2_valid(n2_valid), .t2_addr(n2_addr), .t2_data(n2_data),
        .f_wgray_x(f_wgray), .f_wgray_s(f_wgray), .f_rgray_x(f_rgray), .f_rgray_s(f_rgray),
        .tgt_frames()
    );
endmodule
