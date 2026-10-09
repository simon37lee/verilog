// ---------------------------------------------------------------------------
// matrix_atlys : Digilent Atlys (Spartan-6 XC6SLX45-CSG324-3) 최상위, 1280x720 HDMI
//
//   100 MHz 오실레이터 -> PLL_BASE (/5 -> 20 MHz 위상 비교, x37 -> VCO 740 MHz)
//     CLKOUT0 /2  = 370 MHz      TMDS 직렬화 (DDR, 픽셀 x5)
//     CLKOUT1 /2  = 370 MHz 180° ODDR2 의 두 번째 클럭
//     CLKOUT2 /10 =  74 MHz      픽셀 클럭 (규격 74.25 MHz 의 99.7 %, 화면 59.8 Hz)
//   74.25 MHz 는 100 MHz 에서 PLL 하나로 정확히 못 만든다 (위상 비교 주파수 19 MHz 이상 제약).
//   모니터는 이 정도 차이를 그대로 720p 로 받는다.
//
//   RESET (T15, active-low) 누르면 처음부터
//   LED: [0] PLL lock  [1] RESET 버튼  [2] 픽셀 클럭 깜빡임  [3] vsync 32 프레임마다 토글
// ---------------------------------------------------------------------------
module matrix_atlys (
    input  wire       clk_100m,
    input  wire       btn_rst_n,            // RESET 버튼 (T15 = M0 겸용 핀, 평소 1 / 누르면 0)
    output wire [7:0] led,
    output wire [2:0] hdmi_d_p,             // [0]=Blue, [1]=Green, [2]=Red
    output wire [2:0] hdmi_d_n,
    output wire       hdmi_clk_p,
    output wire       hdmi_clk_n
);
    // ---- 클럭 생성 ---------------------------------------------------------
    wire clk_in;
    IBUFG u_ibufg (.I(clk_100m), .O(clk_in));

    wire clkfb, pll_locked;
    wire clk_x5_unbuf, clk_x5n_unbuf, clk_pix_unbuf;

    PLL_BASE #(
        .CLKIN_PERIOD   (10.0),
        .DIVCLK_DIVIDE  (5),        // 20 MHz
        .CLKFBOUT_MULT  (37),       // VCO 740 MHz
        .CLKOUT0_DIVIDE (2),   .CLKOUT0_PHASE (0.0),     // 370 MHz
        .CLKOUT1_DIVIDE (2),   .CLKOUT1_PHASE (180.0),   // 370 MHz 180°
        .CLKOUT2_DIVIDE (10),                            //  74 MHz
        .CLKOUT3_DIVIDE (10),
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
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .LOCKED   (pll_locked),
        .RST      (1'b0)
    );

    wire clk_x5, clk_x5n, clk_pix;
    BUFG u_bufg_x5  (.I(clk_x5_unbuf),  .O(clk_x5));
    BUFG u_bufg_x5n (.I(clk_x5n_unbuf), .O(clk_x5n));
    BUFG u_bufg_pix (.I(clk_pix_unbuf), .O(clk_pix));

    // ---- 매트릭스 -----------------------------------------------------------
    wire [7:0]  r, g, b;
    wire        de, hsync, vsync;
    wire [15:0] frames;

    matrix_system u_sys (
        .clk(clk_pix), .rst(!btn_rst_n || !pll_locked),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
        .cell_we(), .cell_waddr(), .cell_wdata(),
        .frames(frames)
    );

    // ---- 상태 LED -----------------------------------------------------------
    reg [25:0] hb_pix = 0;
    always @(posedge clk_pix) hb_pix <= hb_pix + 1'b1;

    assign led = {4'b0,
                  frames[5],         // 3: vsync 32 번마다
                  hb_pix[25],        // 2
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
    //   370 MHz 에서는 시프트 레지스터 -> IOB 배선만으로 3.3 ns 가 걸려서 (주기 2.7 ns) 실패했다.
    //   ODDR2 앞에 이것만 몰고 가는 레지스터를 한 단 두면 핀 옆에 놓인다 (네 채널 모두 같은 지연)
    wire [3:0] q;
    (* KEEP = "TRUE" *) reg [7:0] bits = 8'd0;
    always @(posedge clk_x5)
        bits <= {sclk, s2, s1, s0};           // 채널 i 의 {나중, 먼저} = bits[2i+1 : 2i]

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
