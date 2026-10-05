// ---------------------------------------------------------------------------
// nes_atlys_core : fpga_nes (brianbennett) 를 보드 독립적으로 감싼 코어
//   FPGA 최상위(fpga/atlys/nes_atlys.v)와 Verilator 가상 모니터가 같이 쓴다.
//
//   clk 는 100 MHz 하나. fpga_nes 의 PPU 가 VGA 640x480@60 타이밍(100 MHz / 4 = 25 MHz 픽셀)을
//   직접 만들고, NES 화면 256x240 을 2배 확대해 가운데에 놓는다 (위아래 8줄은 테두리색으로 가림).
//   r/g/b/de/hsync/vsync 는 4 클럭 동안 유지되므로, 같은 PLL 에서 나온 25 MHz 로 그대로 샘플링하면 된다.
//
//   ROM 은 두 가지 방법으로 넣는다
//     1) 비트스트림에 미리 넣기 : PRG_INIT_FILE / CHR_INIT_FILE ($readmemh) + CART_CFG_INIT (iNES 4..8 바이트)
//        HCI_START_ACTIVE = 0 이면 리셋 뒤 바로 실행 (아래 부트 펄스가 6502 리셋 벡터를 읽게 한다)
//     2) UART 로더 (tools/nes_loader.py) : 실행 중에도 언제든 디버그 정지 -> 다시 쓰기 -> 실행
//
//   조이패드: 보드 버튼을 NES 패드의 4021 시프트 레지스터처럼 보이게 만든다 (pad_emu).
//   pad 비트 순서는 NES 와 같다: [0]=A [1]=B [2]=Select [3]=Start [4]=Up [5]=Down [6]=Left [7]=Right
// ---------------------------------------------------------------------------
module nes_atlys_core #(
    parameter        PRG_INIT_FILE    = "prg.hex",
    parameter        CHR_INIT_FILE    = "chr.hex",
    parameter [39:0] CART_CFG_INIT    = 40'h0000000000,
    parameter        HCI_START_ACTIVE = 0,
    parameter        UART_BAUD        = 115200,
    parameter        BOOT_CYCLES      = 1024        // 리셋 뒤 콘솔 /RES 를 잡고 있는 클럭 수
) (
    input  wire       clk,            // 100 MHz
    input  wire       rst,            // 하드 리셋 (동기, active-high)
    input  wire       console_reset,  // NES 본체 RESET 버튼 (active-high, 비동기 입력 가능)
    input  wire [7:0] pad,            // 1P 버튼 (active-high, 비동기 입력 가능)
    input  wire [3:0] mute,           // APU 채널 음소거
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [7:0] r,
    output wire [7:0] g,
    output wire [7:0] b,
    output wire       de,
    output wire       hsync,          // active-low (VGA 640x480 표준 극성)
    output wire       vsync,          // active-low
    output wire       audio_pwm,
    output wire [5:0] audio_sample    // APU 4채널 믹스 (0..45, clk 도메인) - AC97 등 PCM 출력용
);
    // ---- 비동기 입력 동기화 -------------------------------------------------
    reg [7:0] pad_s1, pad_s2;
    reg [1:0] cres_s, rx_s;
    always @(posedge clk) begin
        pad_s1 <= pad;    pad_s2 <= pad_s1;
        cres_s <= {cres_s[0], console_reset};
        rx_s   <= {rx_s[0], uart_rx};
    end

    // ---- 부트 펄스 ----------------------------------------------------------
    //   fpga_nes 의 CPU 는 rst 로는 리셋 벡터를 읽지 않고 (원래는 로더가 PC 를 써 줌),
    //   /RES 의 하강 에지에서만 $FFFC 리셋 시퀀스를 탄다. 그래서 리셋 직후 /RES 를 잠깐 내린다.
    reg [15:0] boot_cnt;
    always @(posedge clk)
        if (rst)                      boot_cnt <= 0;
        else if (boot_cnt != BOOT_CYCLES) boot_cnt <= boot_cnt + 1'b1;
    wire boot_res = (boot_cnt != BOOT_CYCLES);

    // ---- NES ----------------------------------------------------------------
    wire       jp_clk, jp_latch, jp_data1;
    wire       vga_hs, vga_vs, vga_de;
    wire [2:0] vga_r, vga_g;
    wire [1:0] vga_b;

    nes_top #(
        .PRG_INIT_FILE   (PRG_INIT_FILE),
        .CHR_INIT_FILE   (CHR_INIT_FILE),
        .CART_CFG_INIT   (CART_CFG_INIT),
        .HCI_START_ACTIVE(HCI_START_ACTIVE),
        .UART_BAUD       (UART_BAUD)
    ) u_nes (
        .CLK_100MHZ      (clk),
        .BTN_SOUTH       (rst),
        .BTN_EAST        (cres_s[1] | boot_res),
        .RXD             (rx_s[1]),
        .SW              (mute),
        .NES_JOYPAD_DATA1(jp_data1),
        .NES_JOYPAD_DATA2(1'b1),          // 2P 없음 (active-low 데이터라 1 = 안 눌림)
        .TXD             (uart_tx),
        .VGA_HSYNC       (vga_hs),
        .VGA_VSYNC       (vga_vs),
        .VGA_DE          (vga_de),
        .VGA_RED         (vga_r),
        .VGA_GREEN       (vga_g),
        .VGA_BLUE        (vga_b),
        .NES_JOYPAD_CLK  (jp_clk),
        .NES_JOYPAD_LATCH(jp_latch),
        .AUDIO           (audio_pwm),
        .AUDIO_SAMPLE    (audio_sample)
    );

    // ---- 조이패드: 4021 시프트 레지스터 흉내 --------------------------------
    //   LATCH 가 1 인 동안 버튼을 병렬 로드 (A 가 data 에 나옴), CLK 상승 에지마다 한 칸씩 민다.
    //   데이터는 active-low, 8 번 민 뒤에는 1 (안 눌림) 이 들어온다.
    reg [7:0] pad_sr;
    reg       jp_clk_d;
    always @(posedge clk) begin
        jp_clk_d <= jp_clk;
        if (jp_latch)                pad_sr <= ~pad_s2;
        else if (jp_clk && !jp_clk_d) pad_sr <= {1'b1, pad_sr[7:1]};
    end
    assign jp_data1 = pad_sr[0];

    // ---- 비디오: RGB332 -> RGB888, sync 극성 ------------------------------
    assign r     = {vga_r, vga_r, vga_r[2:1]};
    assign g     = {vga_g, vga_g, vga_g[2:1]};
    assign b     = {vga_b, vga_b, vga_b, vga_b};
    assign de    = vga_de;
    assign hsync = ~vga_hs;     // fpga_nes 의 vga_sync 는 펄스 구간이 1 (positive)
    assign vsync = ~vga_vs;
endmodule
