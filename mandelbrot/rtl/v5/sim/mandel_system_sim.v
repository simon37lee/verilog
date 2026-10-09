// ---------------------------------------------------------------------------
// mandel_system_sim (v5, 시뮬레이션 전용) : mandel_system + DDR2 컨트롤러 동작 모델 (mcb_model)
//
//   시뮬레이터 (Verilator) 최상위. 포트는 v1~v4 의 mandel_system 과 같아서 sim/verilator/vmon_mandel.cpp 를 그대로 쓴다
//   (Makefile 이 --prefix Vmandel_system 으로 같은 C++ 클래스 이름을 만든다). mcb_err 만 늘었다.
// ---------------------------------------------------------------------------
module mandel_system_sim #(
    parameter W       = 34,
    parameter IW      = 10,
    parameter CORE_HZ = 142857142,
    parameter VERSION = 5
) (
    input  wire        clk_core,
    input  wire        clk_pix,
    input  wire        rst,
    input  wire        btn_l, btn_r, btn_u, btn_d, btn_c,
    input  wire        sw_manual,
    input  wire        sw_single,
    input  wire        sw_zoom_out,
    input  wire [1:0]  sw_iter,
    output wire [7:0]  r, g, b,
    output wire        de, hsync, vsync,
    output wire        fb_we,
    output wire [19:0] fb_waddr,
    output wire [7:0]  fb_wdata,
    output wire [23:0] perf_bcd,
    output wire [15:0] frames,
    output wire        busy,
    output wire        mcb_err
);
    wire        calib_done;
    wire        p0_cmd_en, p0_cmd_full, p0_cmd_empty, p0_wr_en, p0_wr_empty;
    wire [2:0]  p0_cmd_instr;
    wire [5:0]  p0_cmd_bl;
    wire [29:0] p0_cmd_byte_addr;
    wire [3:0]  p0_wr_mask;
    wire [31:0] p0_wr_data;
    wire        p1_cmd_en, p1_cmd_full, p1_rd_en, p1_rd_empty;
    wire [2:0]  p1_cmd_instr;
    wire [5:0]  p1_cmd_bl;
    wire [29:0] p1_cmd_byte_addr;
    wire [31:0] p1_rd_data;

    mandel_system #(.W(W), .IW(IW), .CORE_HZ(CORE_HZ), .VERSION(VERSION)) u_sys (
        .clk_core(clk_core), .clk_pix(clk_pix), .rst(rst),
        .btn_l(btn_l), .btn_r(btn_r), .btn_u(btn_u), .btn_d(btn_d), .btn_c(btn_c),
        .sw_manual(sw_manual), .sw_single(sw_single), .sw_zoom_out(sw_zoom_out), .sw_iter(sw_iter),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
        .calib_done(calib_done),
        .p0_cmd_en(p0_cmd_en), .p0_cmd_instr(p0_cmd_instr), .p0_cmd_bl(p0_cmd_bl),
        .p0_cmd_byte_addr(p0_cmd_byte_addr), .p0_cmd_full(p0_cmd_full), .p0_cmd_empty(p0_cmd_empty),
        .p0_wr_en(p0_wr_en), .p0_wr_mask(p0_wr_mask), .p0_wr_data(p0_wr_data), .p0_wr_empty(p0_wr_empty),
        .p1_cmd_en(p1_cmd_en), .p1_cmd_instr(p1_cmd_instr), .p1_cmd_bl(p1_cmd_bl),
        .p1_cmd_byte_addr(p1_cmd_byte_addr), .p1_cmd_full(p1_cmd_full),
        .p1_rd_en(p1_rd_en), .p1_rd_data(p1_rd_data), .p1_rd_empty(p1_rd_empty),
        .fb_we(fb_we), .fb_waddr(fb_waddr), .fb_wdata(fb_wdata),
        .perf_bcd(perf_bcd), .frames(frames), .busy(busy)
    );

    mcb_model u_mcb (
        .rst(rst), .calib_done(calib_done), .err(mcb_err),
        .clk0(clk_core),
        .p0_cmd_en(p0_cmd_en), .p0_cmd_instr(p0_cmd_instr), .p0_cmd_bl(p0_cmd_bl),
        .p0_cmd_byte_addr(p0_cmd_byte_addr), .p0_cmd_full(p0_cmd_full), .p0_cmd_empty(p0_cmd_empty),
        .p0_wr_en(p0_wr_en), .p0_wr_mask(p0_wr_mask), .p0_wr_data(p0_wr_data), .p0_wr_empty(p0_wr_empty),
        .clk1(clk_pix),
        .p1_cmd_en(p1_cmd_en), .p1_cmd_instr(p1_cmd_instr), .p1_cmd_bl(p1_cmd_bl),
        .p1_cmd_byte_addr(p1_cmd_byte_addr), .p1_cmd_full(p1_cmd_full),
        .p1_rd_en(p1_rd_en), .p1_rd_data(p1_rd_data), .p1_rd_empty(p1_rd_empty)
    );
endmodule
