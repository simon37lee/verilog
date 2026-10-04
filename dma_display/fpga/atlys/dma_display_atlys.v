// ---------------------------------------------------------------------------
// dma_display_atlys : Digilent Atlys (Spartan-6 XC6SLX45-CSG324-3) 최상위
//
//   100 MHz 오실레이터 -> PLL_BASE (VCO 1000 MHz)
//     CLKOUT0 /8  = 125 MHz      TMDS 직렬화 (DDR, 픽셀 x5)
//     CLKOUT1 /8  = 125 MHz 180° ODDR2 의 두 번째 클럭
//     CLKOUT2 /40 =  25 MHz      픽셀 클럭 (clk_pix)
//     CLKOUT3 /30 =  33.33 MHz   소스 도메인 (clk_src)
//     CLKOUT4 /10 = 100 MHz      -> DCM_CLKGEN
//   DCM_CLKGEN 100 MHz x 2 / 5 = 40 MHz  타겟 도메인 (clk_tgt)
//
//   타겟(40 MHz)이 소스(33.33 MHz)보다 빨라서 타겟2 버스의 모든 값을 최소 한 번은 샘플링한다
//   (픽셀 누락 없음, 일부는 두 번 샘플링되지만 같은 주소에 같은 값을 다시 쓸 뿐이다).
//   남는 노이즈는 버스 비트 간 배선 지연 차이(skew)와 메타스테빌리티 때문이다.
//   보드에 오실레이터가 하나뿐이라 두 클럭은 정확히 6:5 관계이고, 위상 관계는 고정 패턴이 반복된다
//   (DCM 지터만큼만 흔들림). 22 MHz 시절에는 29/131 로 일부러 정수비를 피했었다.
//
//   타겟2 버스(n2_* -> t2_*)는 dma_display_top.v 처럼 그대로 연결한다 (의도적인 버그).
//   여기서는 시뮬레이션 모델이 아니라 실제 배선 지연/메타스테빌리티가 노이즈를 만든다.
//
//   메모리: Block RAM 이 약 2.1 Mbit 이므로 버퍼를 200x200 (1:1 표시) 으로 줄인다.
//           (400x400 x 3 = 3.84 Mbit 는 들어가지 않음)
//
//   스위치: SW0 = 타겟2 오류 누적 맵 (스크롤 멈춤 + 회색 무늬 + 타겟2 DMA 반복), SW1 = 타겟2 버스 skew 확대
//
//   LED: [0] PLL lock  [1] DCM lock  [2] RESET 버튼  [3]/[4]/[5] src/tgt/pix 클럭 깜빡임
//        [6] vsync 32 프레임마다 토글  [7] 타겟1 DMA 프레임 32 개마다 토글
// ---------------------------------------------------------------------------
module dma_display_atlys (
    input  wire       clk_100m,
    input  wire       btn_rst_n,    // RESET 버튼 (T15 = M0 겸용 핀, 평소 1 / 누르면 0)
    input  wire       sw_errmap,    // SW0: 1 = 스크롤 멈춤 + 타겟2 오류 누적 맵 (빨간 점), 0 = 지움
    input  wire       sw_skew,      // SW1: 1 = 타겟2 버스 비트마다 0~15 단 LUT 지연 (skew 확대)
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
    wire clk_x5_unbuf, clk_x5n_unbuf, clk_pix_unbuf, clk_src_unbuf, clk_100_unbuf;

    PLL_BASE #(
        .CLKIN_PERIOD   (10.0),
        .DIVCLK_DIVIDE  (1),
        .CLKFBOUT_MULT  (10),       // VCO 1000 MHz
        .CLKOUT0_DIVIDE (8),   .CLKOUT0_PHASE (0.0),     // 125 MHz
        .CLKOUT1_DIVIDE (8),   .CLKOUT1_PHASE (180.0),   // 125 MHz 180°
        .CLKOUT2_DIVIDE (40),                            //  25 MHz
        .CLKOUT3_DIVIDE (30),                            //  33.33 MHz
        .CLKOUT4_DIVIDE (10),                            // 100 MHz
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
        .CLKOUT3  (clk_src_unbuf),
        .CLKOUT4  (clk_100_unbuf),
        .CLKOUT5  (),
        .LOCKED   (pll_locked),
        .RST      (1'b0)
    );

    wire clk_x5, clk_x5n, clk_pix, clk_src, clk_100;
    BUFG u_bufg_x5  (.I(clk_x5_unbuf),  .O(clk_x5));
    BUFG u_bufg_x5n (.I(clk_x5n_unbuf), .O(clk_x5n));
    BUFG u_bufg_pix (.I(clk_pix_unbuf), .O(clk_pix));
    BUFG u_bufg_src (.I(clk_src_unbuf), .O(clk_src));
    BUFG u_bufg_100 (.I(clk_100_unbuf), .O(clk_100));

    wire clk_tgt_unbuf, dcm_locked;

    DCM_CLKGEN #(
        .CLKIN_PERIOD    (10.0),
        .CLKFX_MULTIPLY  (2),
        .CLKFX_DIVIDE    (5),       // 40 MHz
        .CLKFXDV_DIVIDE  (2),
        .SPREAD_SPECTRUM ("NONE"),
        .STARTUP_WAIT    ("FALSE")
    ) u_dcm (
        .CLKIN     (clk_100),
        .RST       (!pll_locked),
        .FREEZEDCM (1'b0),
        .PROGCLK   (1'b0),
        .PROGDATA  (1'b0),
        .PROGEN    (1'b0),
        .CLKFX     (clk_tgt_unbuf),
        .CLKFX180  (),
        .CLKFXDV   (),
        .LOCKED    (dcm_locked),
        .PROGDONE  (),
        .STATUS    ()
    );

    wire clk_tgt;
    BUFG u_bufg_tgt (.I(clk_tgt_unbuf), .O(clk_tgt));

    wire locked = pll_locked & dcm_locked;

    // ---- DMA + 3분할 화면 (리셋 동기화는 코어 안에서 도메인별로) -----------
    wire [7:0]  r, g, b;
    wire        de, hsync, vsync;
    wire        n2_valid;
    wire [15:0] n2_addr;
    wire [7:0]  n2_data;
    wire [15:0] tgt_frames;
    wire        t2_valid;
    wire [15:0] t2_addr;
    wire [7:0]  t2_data;

    // 타겟2 버스: CDC 없이 직결 (의도적인 버그). SW1 이면 비트마다 다른 지연을 더한다
    bus_skew #(.W(25)) u_skew (
        .sel(sw_skew), .din({n2_valid, n2_addr, n2_data}), .dout({t2_valid, t2_addr, t2_data})
    );

    dma_display_core #(
        .W (200),
        .H (200),
        .AW(16)
    ) u_core (
        .clk_src(clk_src), .clk_tgt(clk_tgt), .clk_pix(clk_pix),
        .rst(!btn_rst_n || !locked),
        .errmap_mode(sw_errmap),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
        .n2_valid(n2_valid), .n2_addr(n2_addr), .n2_data(n2_data),
        .t2_valid(t2_valid), .t2_addr(t2_addr), .t2_data(t2_data),
        .tgt_frames(tgt_frames)
    );

    // ---- 상태 LED -----------------------------------------------------------
    //   클럭마다 리셋 없는 카운터로 "클럭이 살아 있는지" 를 따로 보여준다 (약 1 Hz 깜빡임)
    reg [24:0] hb_src = 0, hb_tgt = 0, hb_pix = 0;
    always @(posedge clk_src) hb_src <= hb_src + 1'b1;
    always @(posedge clk_tgt) hb_tgt <= hb_tgt + 1'b1;
    always @(posedge clk_pix) hb_pix <= hb_pix + 1'b1;

    // vsync 하강 에지 수 (영상 타이밍이 돌고 있는지, 32 프레임마다 토글)
    reg       vs_d = 1'b1;
    reg [5:0] vs_cnt = 0;
    always @(posedge clk_pix) begin
        vs_d <= vsync;
        if (vs_d && !vsync) vs_cnt <= vs_cnt + 1'b1;
    end

    assign led = {tgt_frames[5],     // 7: 타겟1 DMA 프레임 (약 1 Hz)
                  vs_cnt[5],         // 6: 영상 타이밍 vsync (약 1 Hz)
                  hb_pix[24],        // 5: clk_pix 살아 있음
                  hb_tgt[24],        // 4: clk_tgt 살아 있음
                  hb_src[24],        // 3: clk_src 살아 있음
                  !btn_rst_n,        // 2: RESET 버튼 눌림 (누를 때만 켜져야 함)
                  dcm_locked,        // 1
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
