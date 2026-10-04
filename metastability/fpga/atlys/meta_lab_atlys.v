// ---------------------------------------------------------------------------
// meta_lab_atlys : 메타스테빌리티 측정 실험 - Digilent Atlys (XC6SLX45-CSG324-3) 최상위
//
//   100 MHz 오실레이터 -> PLL_BASE (VCO 1000 MHz)
//     CLKOUT0 /8  = 125 MHz      TMDS 직렬화 (DDR, 픽셀 x5)
//     CLKOUT1 /8  = 125 MHz 180° ODDR2 의 두 번째 클럭
//     CLKOUT2 /40 =  25 MHz      픽셀 클럭
//     CLKOUT3 /10 = 100 MHz      샘플링 FF / 측정 로직 (clk)
//     CLKOUT4 /10 = 100 MHz, SAMPLE_PHASE 만큼 늦춤   TDC 탭 샘플링 (clk_s)
//
//   SAMPLE_PHASE: clk 에지 뒤 TDC 탭을 샘플링할 때까지의 시간 (144° = 4.0 ns).
//     샘플링 FF 의 clock-to-Q + 지연선 입구까지 배선 + 지연선 일부 를 지난 시점이어야
//     봉우리가 그래프 가운데쯤 온다. 봉우리가 맨 왼쪽(bin 0)에 붙으면 위상을 줄이고,
//     맨 오른쪽(bin 255)에 붙으면 위상을 늘린다 (4.5° = 125 ps 단위).
//
//   RESET 버튼 (T15, active-low) : 리셋 + 히스토그램 지우기
//   SW1 : 그래프 확대 (봉우리 근처 64 칸을 칸당 8 px 로)
//   SW0 : 두 측정 회로의 입력 맞바꾸기 (0: A=비동기 B=동기, 1: A=동기 B=비동기). 바꾸면 히스토그램을 지운다
//   LED: [0] PLL lock  [1] ASYNC 이벤트 진행  [2] SYNC 이벤트 진행  [3] 히스토그램 지우는 중
// ---------------------------------------------------------------------------
module meta_lab_atlys #(
    parameter real SAMPLE_PHASE = 144.0,
    // 측정 회로별 탭 지연 (0.1 ps, tau 의 ps 환산용). 빌드 후 `make taps` 로 확인해서 맞춘다.
    // 타이밍 리포트의 가장 느린 조건 값이라 실제 칩보다 크다 -> 화면의 tau 는 상한값
    parameter TAP_X10_A = 240,
    parameter TAP_X10_B = 240
) (
    input  wire       clk_100m,
    input  wire       btn_rst_n,    // RESET 버튼 (T15 = M0 겸용 핀, 평소 1 / 누르면 0)
    input  wire       sw_swap,      // SW0: 입력 맞바꾸기
    input  wire       sw_zoom,      // SW1: 그래프 확대 (봉우리 근처 64 칸 x 8)
    output wire [7:0] led,
    output wire [2:0] hdmi_d_p,     // [0]=Blue, [1]=Green, [2]=Red
    output wire [2:0] hdmi_d_n,
    output wire       hdmi_clk_p,
    output wire       hdmi_clk_n
);
    // ---- 클럭 생성 ---------------------------------------------------------
    wire clk_in;
    IBUFG u_ibufg (.I(clk_100m), .O(clk_in));

    wire clkfb, pll_locked;
    wire clk_x5_unbuf, clk_x5n_unbuf, clk_pix_unbuf, clk_unbuf, clk_s_unbuf;

    PLL_BASE #(
        .CLKIN_PERIOD   (10.0),
        .DIVCLK_DIVIDE  (1),
        .CLKFBOUT_MULT  (10),       // VCO 1000 MHz
        .CLKOUT0_DIVIDE (8),   .CLKOUT0_PHASE (0.0),            // 125 MHz
        .CLKOUT1_DIVIDE (8),   .CLKOUT1_PHASE (180.0),          // 125 MHz 180°
        .CLKOUT2_DIVIDE (40),                                   //  25 MHz
        .CLKOUT3_DIVIDE (10),  .CLKOUT3_PHASE (0.0),            // 100 MHz
        .CLKOUT4_DIVIDE (10),  .CLKOUT4_PHASE (SAMPLE_PHASE),   // 100 MHz, 늦춤
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
        .CLKOUT3  (clk_unbuf),
        .CLKOUT4  (clk_s_unbuf),
        .CLKOUT5  (),
        .LOCKED   (pll_locked),
        .RST      (1'b0)
    );

    wire clk_x5, clk_x5n, clk_pix, clk, clk_s;
    BUFG u_bufg_x5  (.I(clk_x5_unbuf),  .O(clk_x5));
    BUFG u_bufg_x5n (.I(clk_x5n_unbuf), .O(clk_x5n));
    BUFG u_bufg_pix (.I(clk_pix_unbuf), .O(clk_pix));
    BUFG u_bufg_m   (.I(clk_unbuf),     .O(clk));
    BUFG u_bufg_s   (.I(clk_s_unbuf),   .O(clk_s));

    // ---- 비동기 테스트 신호: 링 오실레이터 ---------------------------------
    wire d_async;
    ring_osc #(.STAGES(31)) u_ro (.en(1'b1), .out(d_async));

    // ---- 측정 + 히스토그램 + 화면 -------------------------------------------
    wire [7:0]  r, g, b;
    wire        de, hsync, vsync, clearing;
    wire [31:0] total_a, total_b;

    meta_lab_core #(.N4(64), .TAP_X10_A(TAP_X10_A), .TAP_X10_B(TAP_X10_B)) u_core (
        .clk(clk), .clk_s(clk_s), .clk_pix(clk_pix),
        .rst(!btn_rst_n || !pll_locked), .d_async(d_async), .swap(sw_swap), .zoom(sw_zoom),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
        .total_a(total_a), .total_b(total_b), .clearing(clearing)
    );

    assign led = {4'b0000, clearing, total_b[23], total_a[23], pll_locked};

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
                .SRTYPE       ("ASYNC")    // DDR_ALIGNMENT C0 이면 ASYNC 여야 함
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
