// ---------------------------------------------------------------------------
// hdmi_top_xc7 : Xilinx 7-series 용 최상위 모듈 (예: Arty / Nexys / Zybo 계열)
//
//   입력 100 MHz -> MMCM -> 픽셀 25 MHz, 직렬 250 MHz
//   (VCO = 100 MHz x 10 = 1000 MHz, /40 = 25 MHz, /4 = 250 MHz)
//
//   640x480@60 의 표준 픽셀클럭은 25.175 MHz 이지만 25 MHz 도 대부분의
//   모니터에서 문제없이 동작한다 (리프레시 약 59.5 Hz).
//   벤더 전용 부분(MMCM, BUFG, OBUFDS)은 이 파일에만 있다.
// ---------------------------------------------------------------------------
module hdmi_top_xc7 (
    input  wire       clk_100m,
    input  wire       rst_btn,      // active-high 리셋 버튼
    output wire [2:0] hdmi_d_p,     // [0]=Blue, [1]=Green, [2]=Red
    output wire [2:0] hdmi_d_n,
    output wire       hdmi_clk_p,
    output wire       hdmi_clk_n
);
    // ---- 클럭 생성 ---------------------------------------------------------
    wire clkfb, clk_pix_unbuf, clk_x10_unbuf, locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (10.0),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (10.0),
        .CLKOUT0_DIVIDE_F (40.0),   // 25 MHz
        .CLKOUT1_DIVIDE   (4)       // 250 MHz
    ) u_mmcm (
        .CLKIN1   (clk_100m),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk_pix_unbuf),
        .CLKOUT1  (clk_x10_unbuf),
        .LOCKED   (locked),
        .RST      (rst_btn),
        .PWRDWN   (1'b0),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
    );

    wire clk_pix, clk_x10;
    BUFG u_bufg_pix (.I(clk_pix_unbuf), .O(clk_pix));
    BUFG u_bufg_x10 (.I(clk_x10_unbuf), .O(clk_x10));

    // ---- 리셋 동기화 (MMCM lock 전까지 리셋 유지) --------------------------
    reg [3:0] rst_pix_sr = 4'hF;
    reg [3:0] rst_x10_sr = 4'hF;
    always @(posedge clk_pix or negedge locked)
        if (!locked) rst_pix_sr <= 4'hF; else rst_pix_sr <= {rst_pix_sr[2:0], 1'b0};
    always @(posedge clk_x10 or negedge locked)
        if (!locked) rst_x10_sr <= 4'hF; else rst_x10_sr <= {rst_x10_sr[2:0], 1'b0};
    wire rst_pix = rst_pix_sr[3];
    wire rst_x10 = rst_x10_sr[3];

    // ---- 영상 생성 + TMDS 인코딩 -------------------------------------------
    wire [9:0] tmds0, tmds1, tmds2;

    hdmi_core u_core (
        .clk_pix  (clk_pix),
        .rst      (rst_pix),
        .tmds_ch0 (tmds0),
        .tmds_ch1 (tmds1),
        .tmds_ch2 (tmds2)
    );

    // ---- 직렬화 -----------------------------------------------------------
    wire s0, s1, s2, sclk;

    tmds_serializer u_ser (
        .clk_x10 (clk_x10),
        .rst     (rst_x10),
        .ch0     (tmds0),
        .ch1     (tmds1),
        .ch2     (tmds2),
        .s_ch0   (s0),
        .s_ch1   (s1),
        .s_ch2   (s2),
        .s_clk   (sclk)
    );

    // ---- 차동 출력 (TMDS_33) ----------------------------------------------
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_ob0 (.I(s0),   .O(hdmi_d_p[0]), .OB(hdmi_d_n[0]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_ob1 (.I(s1),   .O(hdmi_d_p[1]), .OB(hdmi_d_n[1]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_ob2 (.I(s2),   .O(hdmi_d_p[2]), .OB(hdmi_d_n[2]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_obc (.I(sclk), .O(hdmi_clk_p),  .OB(hdmi_clk_n));
endmodule
