// ---------------------------------------------------------------------------
// mandel_atlys (v5, mandel_atlys_ddr.v) : Digilent Atlys 최상위 - 800x600 HDMI + DDR2 프레임버퍼
//
//   클럭 (PLL 2 개)
//     MIG (fpga/atlys/mig/infrastructure.v) : 보드 100 MHz -> VCO 600 MHz
//         DDR2 컨트롤러 (MCB) 600 MHz x2 (DDR2 300 MHz), 보정 75 MHz, 사용자 클럭 c3_clk0 = 100 MHz
//     u_pll : c3_clk0 (100 MHz) -> VCO 1000 MHz
//         CLKOUT0 /5  = 200 MHz      TMDS 직렬화 (DDR, 픽셀 x5). ODDR2 의 두 번째 클럭은 이 클럭을 뒤집어서
//         CLKOUT1 /25 =  40 MHz      픽셀 클럭 (800x600 @ 60 Hz)
//         CLKOUT2 /CORE_DIV          연산 클럭 (clk_core, 7 = 142.9 MHz)
//   처음에는 PLL 하나로 MCB 클럭까지 만들었는데 (MIG 의 PLL 을 빼고) DDR2 보정이 끝나지 않았다.
//   MIG 예제 설계 (fpga/atlys/ddr_test) 는 같은 보드에서 정상이어서 MIG 의 클럭 구성을 그대로 쓰고
//   나머지 클럭은 그 뒤에 PLL 을 하나 더 두어 만든다.
//
//   DDR2: 32 비트 포트 0 = 쓰기 (clk_core), 1 = 읽기 (clk_pix)
//
//   LED: [0] PLL lock  [1] RESET 버튼  [2]/[3] core/pix 클럭 깜빡임  [4] vsync  [5] 렌더 프레임
//        [6] MCB 클럭 버퍼 (BUFPLL_MCB) 잠금  [7] DDR2 보정 완료 (calib_done)
// ---------------------------------------------------------------------------
module mandel_atlys #(
    // Makefile 이 rtl/vN/config.mk 값을 XST -generics 로 넘긴다
    parameter W        = 34,
    parameter IW       = 10,                // 반복 횟수 비트 수
    parameter CORE_DIV = 7,                 // clk_core = 1000 MHz / CORE_DIV
    parameter VERSION  = 5                  // 화면 표시용 엔진 버전
) (
    input  wire       clk_100m,
    input  wire       btn_rst_n,            // RESET 버튼 (T15 = M0 겸용 핀, 평소 1 / 누르면 0)
    input  wire       btn_l, btn_r, btn_u, btn_d, btn_c,
    input  wire       sw_manual,            // SW7
    input  wire       sw_single,            // SW6
    input  wire       sw_zoom_out,          // SW0
    input  wire [1:0] sw_iter,              // {SW2, SW1}
    output wire [7:0] led,
    output wire [2:0] hdmi_d_p,             // [0]=Blue, [1]=Green, [2]=Red
    output wire [2:0] hdmi_d_n,
    output wire       hdmi_clk_p,
    output wire       hdmi_clk_n,
    // DDR2 (MT47H64M16, MCB 뱅크 3)
    inout  wire [15:0] mcb3_dram_dq,
    output wire [12:0] mcb3_dram_a,
    output wire [2:0]  mcb3_dram_ba,
    output wire        mcb3_dram_ras_n,
    output wire        mcb3_dram_cas_n,
    output wire        mcb3_dram_we_n,
    output wire        mcb3_dram_odt,
    output wire        mcb3_dram_cke,
    output wire        mcb3_dram_dm,
    output wire        mcb3_dram_udm,
    inout  wire        mcb3_dram_dqs,
    inout  wire        mcb3_dram_dqs_n,
    inout  wire        mcb3_dram_udqs,
    inout  wire        mcb3_dram_udqs_n,
    output wire        mcb3_dram_ck,
    output wire        mcb3_dram_ck_n,
    inout  wire        mcb3_rzq
);
    localparam CORE_HZ = 1000000000 / CORE_DIV;

    // ---- 클럭 생성 (MIG 뒤의 두 번째 PLL) ------------------------------------------
    wire c3_clk0, c3_rst0;                  // MIG 사용자 클럭 100 MHz (BUFG), 그 리셋
    wire clkfb, pll_locked;
    wire clk_x5_unbuf, clk_pix_unbuf, clk_core_unbuf;

    PLL_BASE #(
        .CLKIN_PERIOD   (10.0),
        .DIVCLK_DIVIDE  (1),
        .CLKFBOUT_MULT  (10),       // VCO 1000 MHz
        .CLKOUT0_DIVIDE (5),                             // 200 MHz
        .CLKOUT1_DIVIDE (25),                            //  40 MHz
        .CLKOUT2_DIVIDE (CORE_DIV),                      // clk_core
        .CLK_FEEDBACK   ("CLKFBOUT"),
        .COMPENSATION   ("INTERNAL")
    ) u_pll (
        .CLKIN    (c3_clk0),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk_x5_unbuf),
        .CLKOUT1  (clk_pix_unbuf),
        .CLKOUT2  (clk_core_unbuf),
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .LOCKED   (pll_locked),
        .RST      (c3_rst0)
    );

    wire clk_x5, clk_pix, clk_core;
    BUFG u_bufg_x5   (.I(clk_x5_unbuf),   .O(clk_x5));
    BUFG u_bufg_pix  (.I(clk_pix_unbuf),  .O(clk_pix));
    BUFG u_bufg_core (.I(clk_core_unbuf), .O(clk_core));

    // ---- DDR2 컨트롤러 (MIG) ----------------------------------------------------
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

    wire bufpll_lock;
    mig_ddr2 u_mig (
        .mcb3_dram_dq(mcb3_dram_dq), .mcb3_dram_a(mcb3_dram_a), .mcb3_dram_ba(mcb3_dram_ba),
        .mcb3_dram_ras_n(mcb3_dram_ras_n), .mcb3_dram_cas_n(mcb3_dram_cas_n), .mcb3_dram_we_n(mcb3_dram_we_n),
        .mcb3_dram_odt(mcb3_dram_odt), .mcb3_dram_cke(mcb3_dram_cke),
        .mcb3_dram_dm(mcb3_dram_dm), .mcb3_dram_udm(mcb3_dram_udm),
        .mcb3_dram_udqs(mcb3_dram_udqs), .mcb3_dram_udqs_n(mcb3_dram_udqs_n),
        .mcb3_dram_dqs(mcb3_dram_dqs), .mcb3_dram_dqs_n(mcb3_dram_dqs_n),
        .mcb3_dram_ck(mcb3_dram_ck), .mcb3_dram_ck_n(mcb3_dram_ck_n), .mcb3_rzq(mcb3_rzq),
        .c3_sys_clk(clk_100m), .c3_sys_rst_i(1'b0),
        .c3_clk0(c3_clk0), .c3_rst0(c3_rst0), .c3_bufpll_lock_o(bufpll_lock),
        .c3_calib_done(calib_done),
        // 포트 0: 쓰기 (clk_core)
        .c3_p0_cmd_clk(clk_core), .c3_p0_cmd_en(p0_cmd_en), .c3_p0_cmd_instr(p0_cmd_instr),
        .c3_p0_cmd_bl(p0_cmd_bl), .c3_p0_cmd_byte_addr(p0_cmd_byte_addr),
        .c3_p0_cmd_empty(p0_cmd_empty), .c3_p0_cmd_full(p0_cmd_full),
        .c3_p0_wr_clk(clk_core), .c3_p0_wr_en(p0_wr_en), .c3_p0_wr_mask(p0_wr_mask), .c3_p0_wr_data(p0_wr_data),
        .c3_p0_wr_full(), .c3_p0_wr_empty(p0_wr_empty), .c3_p0_wr_count(),
        .c3_p0_wr_underrun(), .c3_p0_wr_error(),
        .c3_p0_rd_clk(clk_core), .c3_p0_rd_en(1'b0), .c3_p0_rd_data(),
        .c3_p0_rd_full(), .c3_p0_rd_empty(), .c3_p0_rd_count(), .c3_p0_rd_overflow(), .c3_p0_rd_error(),
        // 포트 1: 읽기 (clk_pix)
        .c3_p1_cmd_clk(clk_pix), .c3_p1_cmd_en(p1_cmd_en), .c3_p1_cmd_instr(p1_cmd_instr),
        .c3_p1_cmd_bl(p1_cmd_bl), .c3_p1_cmd_byte_addr(p1_cmd_byte_addr),
        .c3_p1_cmd_empty(), .c3_p1_cmd_full(p1_cmd_full),
        .c3_p1_wr_clk(clk_pix), .c3_p1_wr_en(1'b0), .c3_p1_wr_mask(4'b0), .c3_p1_wr_data(32'b0),
        .c3_p1_wr_full(), .c3_p1_wr_empty(), .c3_p1_wr_count(), .c3_p1_wr_underrun(), .c3_p1_wr_error(),
        .c3_p1_rd_clk(clk_pix), .c3_p1_rd_en(p1_rd_en), .c3_p1_rd_data(p1_rd_data),
        .c3_p1_rd_full(), .c3_p1_rd_empty(p1_rd_empty), .c3_p1_rd_count(), .c3_p1_rd_overflow(), .c3_p1_rd_error()
    );

    // ---- Mandelbrot ---------------------------------------------------------
    wire [7:0]  r, g, b;
    wire        de, hsync, vsync;
    wire [15:0] frames;
    wire        busy;

    mandel_system #(.W(W), .IW(IW), .CORE_HZ(CORE_HZ), .VERSION(VERSION)) u_sys (
        .clk_core(clk_core), .clk_pix(clk_pix),
        .rst(!btn_rst_n || !pll_locked),
        .btn_l(btn_l), .btn_r(btn_r), .btn_u(btn_u), .btn_d(btn_d), .btn_c(btn_c),
        .sw_manual(sw_manual), .sw_single(sw_single),
        .sw_zoom_out(sw_zoom_out), .sw_iter(sw_iter),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
        .calib_done(calib_done),
        .p0_cmd_en(p0_cmd_en), .p0_cmd_instr(p0_cmd_instr), .p0_cmd_bl(p0_cmd_bl),
        .p0_cmd_byte_addr(p0_cmd_byte_addr), .p0_cmd_full(p0_cmd_full), .p0_cmd_empty(p0_cmd_empty),
        .p0_wr_en(p0_wr_en), .p0_wr_mask(p0_wr_mask), .p0_wr_data(p0_wr_data), .p0_wr_empty(p0_wr_empty),
        .p1_cmd_en(p1_cmd_en), .p1_cmd_instr(p1_cmd_instr), .p1_cmd_bl(p1_cmd_bl),
        .p1_cmd_byte_addr(p1_cmd_byte_addr), .p1_cmd_full(p1_cmd_full),
        .p1_rd_en(p1_rd_en), .p1_rd_data(p1_rd_data), .p1_rd_empty(p1_rd_empty),
        .fb_we(), .fb_waddr(), .fb_wdata(), .perf_bcd(),
        .frames(frames), .busy(busy)
    );

    // ---- 상태 LED -----------------------------------------------------------
    reg [24:0] hb_core = 0, hb_pix = 0;
    always @(posedge clk_core) hb_core <= hb_core + 1'b1;
    always @(posedge clk_pix)  hb_pix  <= hb_pix + 1'b1;

    reg       vs_d = 1'b1;
    reg [5:0] vs_cnt = 0;
    always @(posedge clk_pix) begin
        vs_d <= vsync;
        if (vs_d && !vsync) vs_cnt <= vs_cnt + 1'b1;
    end

    assign led = {calib_done,        // 7: DDR2 보정 완료
                  bufpll_lock,       // 6: MCB 클럭 버퍼 잠금
                  frames[2],         // 5: 렌더 프레임
                  vs_cnt[5],         // 4: vsync
                  hb_pix[24],        // 3
                  hb_core[24],       // 2
                  !btn_rst_n,        // 1
                  pll_locked};       // 0

    // ---- TMDS 인코딩 (clk_pix) ---------------------------------------------
    reg [3:0] rst_pix_sr = 4'hF;
    reg [3:0] rst_x5_sr  = 4'hF;
    always @(posedge clk_pix or negedge pll_locked)
        if (!pll_locked) rst_pix_sr <= 4'hF; else rst_pix_sr <= {rst_pix_sr[2:0], 1'b0};
    always @(posedge clk_x5 or negedge pll_locked)
        if (!pll_locked) rst_x5_sr <= 4'hF; else rst_x5_sr <= {rst_x5_sr[2:0], 1'b0};
    wire rst_pix = rst_pix_sr[3];
    wire rst_x5  = rst_x5_sr[3];

    wire [9:0] tmds0, tmds1, tmds2;
    tmds_encoder u_enc_b (.clk(clk_pix), .rst(rst_pix), .d(b), .c0(hsync), .c1(vsync), .de(de), .q_out(tmds0));
    tmds_encoder u_enc_g (.clk(clk_pix), .rst(rst_pix), .d(g), .c0(1'b0),  .c1(1'b0),  .de(de), .q_out(tmds1));
    tmds_encoder u_enc_r (.clk(clk_pix), .rst(rst_pix), .d(r), .c0(1'b0),  .c1(1'b0),  .de(de), .q_out(tmds2));

    // ---- 직렬화 (clk_x5, 클럭당 2비트) -------------------------------------
    wire [1:0] s0, s1, s2, sclk;
    tmds_serializer_ddr u_ser (
        .clk_x5(clk_x5), .rst(rst_x5),
        .ch0(tmds0), .ch1(tmds1), .ch2(tmds2),
        .s_ch0(s0), .s_ch1(s1), .s_ch2(s2), .s_clk(sclk)
    );

    // ---- DDR 출력 + 차동 버퍼 (TMDS_33) -----------------------------------
    wire [3:0] q;
    wire [7:0] bits = {sclk, s2, s1, s0};     // 채널 i 의 {나중, 먼저} = bits[2i+1 : 2i]

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_oddr
            ODDR2 #(
                .DDR_ALIGNMENT("C0"),
                .INIT         (1'b0),
                .SRTYPE       ("ASYNC")
            ) u_oddr (
                .C0(clk_x5), .C1(~clk_x5), .CE(1'b1),
                .D0(bits[2*i]), .D1(bits[2*i+1]),
                .R(1'b0), .S(1'b0),
                .Q(q[i])
            );
        end
    endgenerate

    OBUFDS #(.IOSTANDARD("TMDS_33")) u_ob0 (.I(q[0]), .O(hdmi_d_p[0]), .OB(hdmi_d_n[0]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_ob1 (.I(q[1]), .O(hdmi_d_p[1]), .OB(hdmi_d_n[1]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_ob2 (.I(q[2]), .O(hdmi_d_p[2]), .OB(hdmi_d_n[2]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_obc (.I(q[3]), .O(hdmi_clk_p),  .OB(hdmi_clk_n));
endmodule
