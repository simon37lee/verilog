// ---------------------------------------------------------------------------
// mandel_atlys : Digilent Atlys (Spartan-6 XC6SLX45-CSG324-3) 최상위
//
//   100 MHz 오실레이터 -> PLL_BASE (VCO 1000 MHz)
//     CLKOUT0 /8  = 125 MHz      TMDS 직렬화 (DDR, 픽셀 x5)
//     CLKOUT1 /8  = 125 MHz 180° ODDR2 의 두 번째 클럭
//     CLKOUT2 /40 =  25 MHz      픽셀 클럭 (clk_pix, 640x480 @ 60 Hz)
//     CLKOUT3 /CORE_DIV          연산 클럭 (clk_core, 기본 /20 = 50 MHz)
//
//   조작: SW7 내림 = 자동 데모 (Seahorse Valley 로 32 배 확대 / 축소 반복), 올림 = 버튼 조작
//           BTNL/BTNR/BTNU/BTND 이동, BTNC 확대 (SW0 올리면 축소)
//         SW6 올림 = 단일 버퍼 (그리는 과정이 보임), 내림 = 더블 버퍼
//         {SW2, SW1} max_iter: 0 = 255, 1 = 127, 2 = 63, 3 = 31
//         RESET (T15, active-low) 처음 보기 영역으로
//
//   LED: [0] PLL lock  [1] RESET 버튼  [2]/[3] core/pix 클럭 깜빡임
//        [4] vsync 32 프레임마다 토글  [5] 렌더 프레임 4 개마다 토글  [6] 코어 busy
// ---------------------------------------------------------------------------
module mandel_atlys #(
    // Makefile 이 rtl/vN/config.mk 값을 XST -generics 로 넘긴다
    parameter W        = 18,
    parameter CORE_DIV = 20,                // clk_core = 1000 MHz / CORE_DIV
    parameter VERSION  = 1                  // 화면 표시용 엔진 버전
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
    output wire       hdmi_clk_n
);
    localparam CORE_HZ = 1000000000 / CORE_DIV;

    // ---- 클럭 생성 ---------------------------------------------------------
    wire clk_in;
    IBUFG u_ibufg (.I(clk_100m), .O(clk_in));

    wire clkfb, pll_locked;
    wire clk_x5_unbuf, clk_x5n_unbuf, clk_pix_unbuf, clk_core_unbuf;

    PLL_BASE #(
        .CLKIN_PERIOD   (10.0),
        .DIVCLK_DIVIDE  (1),
        .CLKFBOUT_MULT  (10),       // VCO 1000 MHz
        .CLKOUT0_DIVIDE (8),   .CLKOUT0_PHASE (0.0),     // 125 MHz
        .CLKOUT1_DIVIDE (8),   .CLKOUT1_PHASE (180.0),   // 125 MHz 180°
        .CLKOUT2_DIVIDE (40),                            //  25 MHz
        .CLKOUT3_DIVIDE (CORE_DIV),                      // clk_core
        .CLKOUT4_DIVIDE (10),
        .CLKOUT5_DIVIDE (10),
        .CLK_FEEDBACK   ("CLKFBOUT"),
        .COMPENSATION   ("INTERNAL")
    ) u_pll (
        .CLKIN    (clk_in),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk_x5_unbuf),
        .CLKOUT1  (clk_x5n_unbuf),
        .CLKOUT2  (clk_pix_unbuf),
        .CLKOUT3  (clk_core_unbuf),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .LOCKED   (pll_locked),
        .RST      (1'b0)
    );

    wire clk_x5, clk_x5n, clk_pix, clk_core;
    BUFG u_bufg_x5   (.I(clk_x5_unbuf),   .O(clk_x5));
    BUFG u_bufg_x5n  (.I(clk_x5n_unbuf),  .O(clk_x5n));
    BUFG u_bufg_pix  (.I(clk_pix_unbuf),  .O(clk_pix));
    BUFG u_bufg_core (.I(clk_core_unbuf), .O(clk_core));

    // ---- Mandelbrot ---------------------------------------------------------
    wire [7:0]  r, g, b;
    wire        de, hsync, vsync;
    wire [15:0] frames;
    wire        busy;

    mandel_system #(.W(W), .CORE_HZ(CORE_HZ), .VERSION(VERSION)) u_sys (
        .clk_core(clk_core), .clk_pix(clk_pix),
        .rst(!btn_rst_n || !pll_locked),
        .btn_l(btn_l), .btn_r(btn_r), .btn_u(btn_u), .btn_d(btn_d), .btn_c(btn_c),
        .sw_manual(sw_manual), .sw_single(sw_single),
        .sw_zoom_out(sw_zoom_out), .sw_iter(sw_iter),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
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

    assign led = {1'b0,
                  busy,              // 6: 코어 계산 중
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
                .C0(clk_x5), .C1(clk_x5n), .CE(1'b1),
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
