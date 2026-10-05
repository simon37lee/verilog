// ---------------------------------------------------------------------------
// ac97_out : AC'97 컨트롤러 (출력 전용) - Atlys 의 LM4550 코덱으로 48 kHz 스테레오 PCM 재생
//
//   AC-link: 코덱이 BIT_CLK (12.288 MHz) 를 만들고, 256 비트 = 1 프레임 = 48 kHz.
//     컨트롤러는 SYNC / SDATA_OUT 을 BIT_CLK 상승 에지에서 바꾸고, 코덱은 SYNC 를 상승 에지,
//     SDATA_OUT 을 하강 에지에서 샘플링한다. SYNC 는 프레임 시작 16 비트 동안 1 이고 데이터보다
//     한 클럭 먼저 올라간다 (bit 255 에서 1 -> 코덱이 bit 0 을 받는 에지에서 SYNC=1 을 본다).
//
//     비트    슬롯      내용
//     0..15   slot0     tag: [15] 프레임 유효, [14] slot1, [13] slot2, [12] slot3 (L), [11] slot4 (R) 유효
//     16..35  slot1     명령 주소: [19] 0 = 쓰기, [18:12] 레지스터 번호
//     36..55  slot2     명령 데이터: [19:4]
//     56..75  slot3     PCM 왼쪽:  [19:4] = 16 비트 2의 보수
//     76..95  slot4     PCM 오른쪽
//     96..255           0
//
//   코덱 초기화: 리셋 기본값은 출력이 모두 음소거라서 아래 세 레지스터를 매 프레임 돌아가며 계속 쓴다
//   (코덱 준비가 늦어도 몇 프레임 뒤에는 반드시 적용된다. 같은 값을 다시 쓰는 것은 무해하다).
//     02h Master Volume    = 0000h  LINE OUT  0 dB, 음소거 해제
//     04h Headphone Volume = 0000h  HP OUT    0 dB, 음소거 해제
//     18h PCM Out Volume   = pcm_vol 입력 (실행 중 바꿀 수 있음, 3 프레임 안에 반영)
//                            [12:8]/[4:0] 왼쪽/오른쪽: 00h = +12 dB, 08h = 0 dB, 1Fh = -34.5 dB (1.5 dB 단위)
//
//   리셋: rst 뒤 RESET# 를 RESET_CYCLES 클럭 (기본 4096 = 41 us, 규격은 1 us 이상) 동안 0 으로.
//         그동안 BIT_CLK 가 멈춰 있으므로 BIT_CLK 쪽 레지스터는 RESET# 로 비동기 리셋한다
//         (SYNC / SDATA_OUT 은 리셋 중 0 이어야 한다 - 아니면 코덱이 ATE 테스트 모드로 들어감).
//
//   샘플 전달 (clk -> BIT_CLK): BIT_CLK 쪽이 프레임 중간 (bit 128) 에 요청 토글을 뒤집으면
//     clk 쪽이 그걸 동기화해서 pcm_l/pcm_r (와 pcm_vol) 을 hold 에 잡고 sample_req 를 1 클럭 낸다.
//     BIT_CLK 쪽은 프레임 끝 (bit 255) 에 hold 를 읽는다 - 그 사이 약 10 us 동안 hold 는 변하지 않는다.
//     생산자는 sample_req 를 받고 다음 샘플을 준비하면 된다 (다음 프레임에 잡힘, 지연 1 프레임).
// ---------------------------------------------------------------------------
module ac97_out #(
    parameter RESET_CYCLES = 4096
) (
    input  wire        clk,             // 시스템 클럭 (100 MHz)
    input  wire        rst,             // 동기 리셋 (clk)
    input  wire [15:0] pcm_l,           // 2의 보수, clk 도메인
    input  wire [15:0] pcm_r,
    input  wire [15:0] pcm_vol,         // 18h PCM Out Volume 값, clk 도메인
                                        //   [15] 음소거, [12:8]/[4:0] 왼쪽/오른쪽 감쇠:
                                        //   00h = +12 dB, 08h = 0 dB, 1Fh = -34.5 dB (1.5 dB 단위)
    output wire        sample_req,      // clk 도메인 1 클럭 펄스, 48 kHz
    output reg         codec_ready,     // 코덱 slot0 의 Codec Ready 비트 (BIT_CLK 도메인, LED 용)

    output reg         ac97_reset_n,
    input  wire        ac97_bit_clk,
    output reg         ac97_sync,
    output reg         ac97_sdata_out,
    input  wire        ac97_sdata_in
);
    // ---- clk 도메인: 코덱 콜드 리셋 -----------------------------------------
    reg [15:0] rst_cnt;
    always @(posedge clk)
        if (rst) begin
            rst_cnt      <= 0;
            ac97_reset_n <= 1'b0;
        end else if (rst_cnt != RESET_CYCLES) begin
            rst_cnt      <= rst_cnt + 1'b1;
            ac97_reset_n <= 1'b0;
        end else begin
            ac97_reset_n <= 1'b1;
        end

    // ---- clk 도메인: 샘플 요청 동기화 + hold ------------------------------
    reg        req_tog;                         // BIT_CLK 도메인
    reg  [2:0] req_s;
    reg [47:0] hold;
    always @(posedge clk) begin
        req_s <= {req_s[1:0], req_tog};
        if (req_s[2] != req_s[1]) hold <= {pcm_vol, pcm_l, pcm_r};
    end
    assign sample_req = (req_s[2] != req_s[1]);

    // ---- BIT_CLK 도메인: 프레임 생성 -------------------------------------
    reg  [7:0] bit_cnt;
    reg  [1:0] cmd_idx;
    reg [15:0] f_l, f_r;                         // 이번 프레임에 보낼 PCM
    reg [15:0] f_vol;                            // 18h 에 쓸 값
    reg  [6:0] f_addr;
    reg [15:0] f_data;

    // 명령 표
    reg  [6:0] cmd_addr;
    reg [15:0] cmd_data;
    always @* begin
        case (cmd_idx)
            2'd0:    begin cmd_addr = 7'h02; cmd_data = 16'h0000; end
            2'd1:    begin cmd_addr = 7'h04; cmd_data = 16'h0000; end
            default: begin cmd_addr = 7'h18; cmd_data = f_vol; end
        endcase
    end

    // 비트 위치 -> 보낼 비트
    wire [19:0] slot1 = {1'b0, f_addr, 12'h000};
    wire [19:0] slot2 = {f_data, 4'h0};
    wire [19:0] slot3 = {f_l, 4'h0};
    wire [19:0] slot4 = {f_r, 4'h0};
    wire [15:0] tag   = 16'b1111_1000_0000_0000;
    reg         next_bit;
    always @* begin
        if (bit_cnt < 8'd16)       next_bit = tag[15 - bit_cnt];
        else if (bit_cnt < 8'd36)  next_bit = slot1[35 - bit_cnt];
        else if (bit_cnt < 8'd56)  next_bit = slot2[55 - bit_cnt];
        else if (bit_cnt < 8'd76)  next_bit = slot3[75 - bit_cnt];
        else if (bit_cnt < 8'd96)  next_bit = slot4[95 - bit_cnt];
        else                       next_bit = 1'b0;
    end

    always @(posedge ac97_bit_clk or negedge ac97_reset_n)
        if (!ac97_reset_n) begin
            bit_cnt        <= 8'd0;
            cmd_idx        <= 2'd0;
            ac97_sync      <= 1'b0;
            ac97_sdata_out <= 1'b0;
            req_tog        <= 1'b0;
            f_l            <= 16'h0000;
            f_r            <= 16'h0000;
            f_vol          <= 16'h8808;         // 코덱 리셋 기본값 (음소거)
            f_addr         <= 7'h02;
            f_data         <= 16'h0000;
        end else begin
            bit_cnt        <= bit_cnt + 1'b1;
            ac97_sdata_out <= next_bit;

            if (bit_cnt == 8'd255) ac97_sync <= 1'b1;   // 다음 에지의 bit 0 보다 한 클럭 먼저
            if (bit_cnt == 8'd15)  ac97_sync <= 1'b0;

            if (bit_cnt == 8'd128) req_tog <= ~req_tog;

            if (bit_cnt == 8'd255) begin                 // 다음 프레임 내용 확정
                {f_vol, f_l, f_r} <= hold;
                f_addr     <= cmd_addr;
                f_data     <= cmd_data;
                cmd_idx    <= (cmd_idx == 2'd2) ? 2'd0 : cmd_idx + 1'b1;
            end
        end

    // 코덱은 SDATA_IN 을 상승 에지에서 내보낸다 -> 하강 에지에서 읽는다.
    // slot0 의 첫 비트 (Codec Ready) 는 bit_cnt 가 1 인 반주기에 나온다.
    always @(negedge ac97_bit_clk or negedge ac97_reset_n)
        if (!ac97_reset_n)        codec_ready <= 1'b0;
        else if (bit_cnt == 8'd1) codec_ready <= ac97_sdata_in;
endmodule

// ---------------------------------------------------------------------------
// nes_pcm : APU 믹스 값 (0..45, 한쪽 극성) -> 16 비트 PCM, DC 제거
//   y[n] = x[n] - x[n-1] + y[n-1] - y[n-1]/256   (1차 고역 통과, 48 kHz 에서 차단 약 30 Hz)
//   x = level << SHIFT (기본 10: 최대 46080). 채널을 켜고 끌 때 생기는 큰 DC 계단이 "퍽" 소리로
//   남지 않게 한다. 보통 음악은 level 10~30 이라 16 비트 범위를 적당히 쓰고, 드물게 넘치면 포화시킨다.
// ---------------------------------------------------------------------------
module nes_pcm #(
    parameter SHIFT = 10                // 디지털 게인: 9 = 이전 (-6 dB), 10 = 기본, 11 = +6 dB
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        step,        // 48 kHz (ac97_out.sample_req)
    input  wire  [5:0] level,
    output reg  [15:0] pcm
);
    // APU 믹서 (테이블 두 개 + 덧셈) 뒤에 바로 필터 연산이 붙으면 100 MHz 에서 경로가 길어지므로 한 번 받는다
    reg         [5:0] level_q;
    always @(posedge clk) level_q <= level;

    reg signed [19:0] x_prev, y;
    wire signed [19:0] x      = $signed({14'd0, level_q}) <<< SHIFT;
    wire signed [19:0] y_next = x - x_prev + y - (y >>> 8);

    always @(posedge clk)
        if (rst) begin
            x_prev <= 0;
            y      <= 0;
            pcm    <= 16'h0000;
        end else if (step) begin
            x_prev <= x;
            y      <= y_next;
            pcm    <= (y_next >  20'sd32767) ? 16'h7FFF :
                      (y_next < -20'sd32768) ? 16'h8000 : y_next[15:0];
        end
endmodule
