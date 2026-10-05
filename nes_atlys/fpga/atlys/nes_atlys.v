// ---------------------------------------------------------------------------
// nes_atlys : Digilent Atlys (Spartan-6 XC6SLX45-CSG324-3) 최상위 - fpga_nes 를 HDMI 로 출력
//
//   100 MHz 오실레이터 -> PLL_BASE (VCO 1000 MHz)
//     CLKOUT0 /8  = 125 MHz      TMDS 직렬화 (DDR, 픽셀 x5)
//     CLKOUT1 /8  = 125 MHz 180° ODDR2 의 두 번째 클럭
//     CLKOUT2 /40 =  25 MHz      픽셀 클럭 (clk_pix)
//     CLKOUT3 /10 = 100 MHz      NES 코어 (clk_nes)
//   네 클럭 모두 같은 PLL 에서 나와 위상이 맞는다. NES 코어의 영상 출력은 100 MHz 4 클럭 동안
//   유지되므로 clk_pix 로 한 번 레지스터에 받으면 된다 (동기 경로, 타이밍 툴이 10 ns 로 분석).
//
//   ROM: build/rom/rom_cfg.vh (tools/nes2hex.py 가 생성) 의 hex 를 BRAM 에 미리 넣고 바로 실행.
//        실행 중에 USB-UART (115200 8O1) 로 tools/nes_loader.py 를 쓰면 다른 ROM 으로 교체.
//
//   조작: BTNL/BTNR = 왼쪽/오른쪽   BTNC = Start   SW7 = Select   (스위치는 올리면 누른 상태)
//         SW0 내림 (게임 모드)  : BTNU = A (점프)  BTND = B (대시/파이어)  SW5 = 위  SW6 = 아래 (파이프)
//         SW0 올림 (방향키 모드): BTNU = 위        BTND = 아래             SW5 = A   SW6 = B   (메뉴 이동용)
//         RESET (T15, active-low) = 전체 리셋 (BRAM 의 ROM 으로 다시 시작)
//
//   소리: APU 4채널 믹스 -> DC 차단 -> AC97 코덱 (LM4550) 48 kHz -> HP OUT / LINE OUT 단자
//         볼륨 = {SW4,SW3,SW2,SW1} (4 비트): 0 (모두 내림) = 최대 +12 dB, 1 늘 때마다 -3 dB, 15 = 음소거
//
//   LED: [0] PLL lock  [1] RESET 눌림  [2] clk_nes 깜빡임 (약 1.5 Hz)  [3] vsync 32 프레임마다 토글
//        [4] UART 수신 중  [5] 패드 버튼 눌림  [6] AC97 코덱 준비  [7] 소리 나는 중
// ---------------------------------------------------------------------------
module nes_atlys (
    input  wire       clk_100m,
    input  wire       btn_rst_n,    // RESET 버튼 (T15 = M0 겸용 핀, 평소 1 / 누르면 0)
    input  wire       btn_u,
    input  wire       btn_d,
    input  wire       btn_l,
    input  wire       btn_r,
    input  wire       btn_c,
    input  wire       sw_mode,      // SW0: 0 = 게임 모드, 1 = 방향키 모드 (BTNU/BTND 와 SW5/SW6 역할 교환)
    input  wire [7:5] sw,
    input  wire [4:1] sw_vol,       // SW1..SW4: 볼륨 (0 = 최대, 15 = 음소거)
    input  wire       uart_rx,      // USB-UART (J17), FPGA 입장에서 수신
    output wire       uart_tx,
    output wire [7:0] led,
    output wire       ac97_reset_n, // LM4550 AC97 코덱
    input  wire       ac97_bit_clk, //   12.288 MHz, 코덱이 만든다
    output wire       ac97_sync,
    output wire       ac97_sdata_out,
    input  wire       ac97_sdata_in,
    output wire [2:0] hdmi_d_p,     // [0]=Blue, [1]=Green, [2]=Red
    output wire [2:0] hdmi_d_n,
    output wire       hdmi_clk_p,
    output wire       hdmi_clk_n
);
    // ROM_CART_CFG, ROM_PRG_FILE, ROM_CHR_FILE
    `include "rom_cfg.vh"

    // ---- 클럭 생성 ---------------------------------------------------------
    wire clk_in;
    IBUFG u_ibufg (.I(clk_100m), .O(clk_in));

    wire clkfb, pll_locked;
    wire clk_x5_unbuf, clk_x5n_unbuf, clk_pix_unbuf, clk_nes_unbuf;

    PLL_BASE #(
        .CLKIN_PERIOD   (10.0),
        .DIVCLK_DIVIDE  (1),
        .CLKFBOUT_MULT  (10),       // VCO 1000 MHz
        .CLKOUT0_DIVIDE (8),   .CLKOUT0_PHASE (0.0),     // 125 MHz
        .CLKOUT1_DIVIDE (8),   .CLKOUT1_PHASE (180.0),   // 125 MHz 180°
        .CLKOUT2_DIVIDE (40),                            //  25 MHz
        .CLKOUT3_DIVIDE (10),                            // 100 MHz
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
        .CLKOUT3  (clk_nes_unbuf),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .LOCKED   (pll_locked),
        .RST      (1'b0)
    );

    wire clk_x5, clk_x5n, clk_pix, clk_nes;
    BUFG u_bufg_x5  (.I(clk_x5_unbuf),  .O(clk_x5));
    BUFG u_bufg_x5n (.I(clk_x5n_unbuf), .O(clk_x5n));
    BUFG u_bufg_pix (.I(clk_pix_unbuf), .O(clk_pix));
    BUFG u_bufg_nes (.I(clk_nes_unbuf), .O(clk_nes));

    // ---- 리셋 (clk_nes 동기) ------------------------------------------------
    reg [3:0] rst_nes_sr = 4'hF;
    always @(posedge clk_nes or negedge pll_locked)
        if (!pll_locked) rst_nes_sr <= 4'hF; else rst_nes_sr <= {rst_nes_sr[2:0], !btn_rst_n};
    wire rst_nes = rst_nes_sr[3];

    // ---- NES 코어 -----------------------------------------------------------
    //   pad 비트: [0]=A [1]=B [2]=Select [3]=Start [4]=Up [5]=Down [6]=Left [7]=Right
    wire       pad_a    = sw_mode ? sw[5] : btn_u;
    wire       pad_b    = sw_mode ? sw[6] : btn_d;
    wire       pad_up   = sw_mode ? btn_u : sw[5];
    wire       pad_down = sw_mode ? btn_d : sw[6];
    wire [7:0] pad = {btn_r, btn_l, pad_down, pad_up, btn_c, sw[7], pad_b, pad_a};
    wire [7:0] r, g, b;
    wire       de, hsync, vsync;
    wire [5:0] audio_level;

    reg  [3:0] vol_s1, vol_s2;
    always @(posedge clk_nes) begin
        vol_s1 <= sw_vol;
        vol_s2 <= vol_s1;
    end

    nes_atlys_core #(
        .PRG_INIT_FILE   (ROM_PRG_FILE),
        .CHR_INIT_FILE   (ROM_CHR_FILE),
        .CART_CFG_INIT   (ROM_CART_CFG),
        .HCI_START_ACTIVE(0),
        .UART_BAUD       (115200)
    ) u_core (
        .clk          (clk_nes),
        .rst          (rst_nes),
        .console_reset(1'b0),
        .pad          (pad),
        .mute         (4'b0000),
        .uart_rx      (uart_rx),
        .uart_tx      (uart_tx),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
        .audio_pwm    (),
        .audio_sample (audio_level)
    );

    // ---- 소리: APU 믹스 -> PCM -> AC97 ---------------------------------------
    wire        pcm_step, codec_ready;
    wire [15:0] pcm;

    // 코덱 PCM Out Volume (18h): 감쇠 코드 = 스위치 값 x 2 (1.5 dB x 2 = 3 dB 단위), 15 = 음소거 비트
    wire [4:0]  atten   = {vol_s2, 1'b0};
    wire [15:0] pcm_vol = (vol_s2 == 4'd15) ? 16'h8000 : {3'b000, atten, 3'b000, atten};
    nes_pcm u_pcm (
        .clk(clk_nes), .rst(rst_nes), .step(pcm_step), .level(audio_level), .pcm(pcm)
    );
    ac97_out u_ac97 (
        .clk           (clk_nes),
        .rst           (rst_nes),
        .pcm_l         (pcm),
        .pcm_r         (pcm),
        .pcm_vol       (pcm_vol),
        .sample_req    (pcm_step),
        .codec_ready   (codec_ready),
        .ac97_reset_n  (ac97_reset_n),
        .ac97_bit_clk  (ac97_bit_clk),
        .ac97_sync     (ac97_sync),
        .ac97_sdata_out(ac97_sdata_out),
        .ac97_sdata_in (ac97_sdata_in)
    );

    // 소리 표시: 믹스 값이 0 이 아니면 약 80 ms 켜 둔다
    reg [22:0] snd_led = 0;
    always @(posedge clk_nes)
        if (audio_level != 0)  snd_led <= {23{1'b1}};
        else if (snd_led != 0) snd_led <= snd_led - 1'b1;

    // ---- 100 MHz -> 25 MHz: 영상 신호를 픽셀 클럭으로 받는다 ----------------
    reg [7:0] r_p, g_p, b_p;
    reg       de_p, hs_p, vs_p;
    always @(posedge clk_pix) begin
        r_p  <= r;  g_p  <= g;  b_p <= b;
        de_p <= de; hs_p <= hsync; vs_p <= vsync;
    end

    // ---- 상태 LED -----------------------------------------------------------
    reg [25:0] hb_nes = 0;
    always @(posedge clk_nes) hb_nes <= hb_nes + 1'b1;

    reg       vs_d = 1'b1;
    reg [5:0] vs_cnt = 0;
    always @(posedge clk_pix) begin
        vs_d <= vs_p;
        if (vs_d && !vs_p) vs_cnt <= vs_cnt + 1'b1;
    end

    // UART 수신 표시: rx 가 0 이 될 때마다 약 80 ms 켜 둔다
    reg [1:0]  rx_s = 2'b11;
    reg [22:0] rx_led = 0;
    always @(posedge clk_nes) begin
        rx_s <= {rx_s[0], uart_rx};
        if (!rx_s[1])       rx_led <= {23{1'b1}};
        else if (rx_led != 0) rx_led <= rx_led - 1'b1;
    end

    assign led = {snd_led != 0,      // 7: 소리 나는 중
                  codec_ready,       // 6: AC97 코덱 준비 (slot0 Codec Ready)
                  |pad,              // 5: 패드 버튼 눌림
                  rx_led != 0,       // 4: UART 수신
                  vs_cnt[5],         // 3: vsync (약 1 Hz)
                  hb_nes[25],        // 2: clk_nes 살아 있음
                  !btn_rst_n,        // 1: RESET 버튼
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
    tmds_encoder u_enc_b (.clk(clk_pix), .rst(rst_pix), .d(b_p), .c0(hs_p), .c1(vs_p), .de(de_p), .q_out(tmds0));
    tmds_encoder u_enc_g (.clk(clk_pix), .rst(rst_pix), .d(g_p), .c0(1'b0), .c1(1'b0), .de(de_p), .q_out(tmds1));
    tmds_encoder u_enc_r (.clk(clk_pix), .rst(rst_pix), .d(r_p), .c0(1'b0), .c1(1'b0), .de(de_p), .q_out(tmds2));

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
