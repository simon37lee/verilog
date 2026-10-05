// ---------------------------------------------------------------------------
// tb_ac97 : ac97_out + nes_pcm 검증 (LM4550 쪽 동작을 흉내 내는 코덱 모델)
//
//   iverilog -g2005 -o tb_ac97.vvp sim/tb_ac97.v rtl/ac97_out.v && vvp tb_ac97.vvp
//
//   - RESET# 가 1 us 이상 0 인지, 그동안 SYNC / SDATA_OUT 이 0 인지
//   - 코덱이 RESET# 해제 뒤 BIT_CLK (12.288 MHz) 를 낸다
//   - 코덱처럼 SYNC 는 상승 에지, SDATA_OUT 은 하강 에지에서 샘플링해서 프레임을 해석
//     SYNC 폭 16, tag, slot1/2 명령 (02h/04h/18h 순환), slot3 == slot4
//   - PCM 값: level 을 0 -> 45 -> 0 -> 20 으로 바꿔 가며 같은 DC 차단 필터를 정수로 계산한 기대값과 비교
//   - 코덱 모델이 slot0 첫 비트에 Codec Ready = 1 을 내면 codec_ready 가 1 이 되는지
//   - pcm_vol 을 실행 중 바꾸면 18h 쓰기 값이 새 값으로 바뀌고 다시 돌아가지 않는지
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_ac97;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                       // 100 MHz

    reg  [5:0]  level = 0;
    reg  [15:0] vol = 16'h0404;
    wire        req, ready;
    wire [15:0] pcm;
    wire        reset_n, sync, sdo;
    reg         bit_clk = 0, sdi = 0;

    nes_pcm u_pcm (.clk(clk), .rst(rst), .step(req), .level(level), .pcm(pcm));
    ac97_out #(.RESET_CYCLES(200)) dut (
        .clk(clk), .rst(rst), .pcm_l(pcm), .pcm_r(pcm), .pcm_vol(vol), .sample_req(req), .codec_ready(ready),
        .ac97_reset_n(reset_n), .ac97_bit_clk(bit_clk), .ac97_sync(sync),
        .ac97_sdata_out(sdo), .ac97_sdata_in(sdi)
    );

    integer errors = 0;
    task fail(input [8*80-1:0] msg); begin errors = errors + 1; $display("FAIL @%0t: %0s", $time, msg); end endtask

    // ---- 리셋 검사 ----------------------------------------------------------
    realtime rst_fall, rst_rise;
    initial begin
        #100 rst = 0;
    end
    always @(negedge reset_n) rst_fall = $realtime;
    always @(posedge reset_n) begin
        rst_rise = $realtime;
        if (rst_rise - rst_fall < 1000.0) fail("RESET# low < 1 us");
    end
    always @(posedge clk)
        if (!reset_n && (sync || sdo)) fail("SYNC/SDATA_OUT not low during reset");

    // ---- 코덱 모델: BIT_CLK -----------------------------------------------
    reg clk_on = 0;
    always @(posedge reset_n) #200 clk_on = 1;
    always @(negedge reset_n) clk_on = 0;
    always #40.69 if (clk_on) bit_clk = ~bit_clk; else bit_clk = 0;

    // ---- 코덱 모델: 프레임 수신 -------------------------------------------
    reg         sync_q = 0;
    reg         in_frame = 0;
    integer     bitn = 0, sync_len = 0, frames = 0;
    reg [255:0] fr;
    always @(posedge bit_clk) begin
        sdi <= 0;
        if (sync && !sync_q && !in_frame) begin  // 프레임 시작 (첫 1 샘플)
            in_frame <= 1;
            bitn     <= 0;
            sync_len <= 1;
            sdi      <= 1;                       // slot0 첫 비트 = Codec Ready
        end else if (sync) sync_len <= sync_len + 1;
        sync_q <= sync;
    end
    always @(negedge bit_clk)
        if (in_frame) begin
            fr[255 - bitn] = sdo;
            bitn = bitn + 1;
            if (bitn == 256) begin
                in_frame = 0;
                check_frame(fr);
            end
        end

    // ---- 기대 PCM: 같은 필터를 정수로 (1 프레임 지연은 정렬로 흡수) ---------
    integer x_prev = 0, y = 0, xq;
    integer exp_q [0:4095];
    integer exp_wr = 0, exp_rd = 0;
    always @(posedge clk) if (!rst && req) begin
        xq = level * 1024;
        y  = xq - x_prev + y - ((y >= 0) ? (y / 256) : -((-y + 255) / 256));   // >>> 8 (내림)
        x_prev = xq;
        exp_q[exp_wr] = (y > 32767) ? 32767 : (y < -32768) ? -32768 : y;   // 출력만 포화 (필터 상태는 그대로)
        exp_wr = exp_wr + 1;
    end

    integer   got_l, got_r, cmd_n = 0, synced = 0, pcm_checked = 0;
    reg[15:0] vol_old = 16'h0404, vol_new = 16'h0404;
    reg       vol_switched = 0;
    integer   vol_new_seen = 0;
    reg [6:0] exp_addr;
    reg[15:0] exp_data;
    task check_frame(input [255:0] f);
        reg [15:0] tag;
        reg [19:0] s1, s2, s3, s4;
        begin
            frames = frames + 1;
            tag = f[255:240];
            s1  = f[239:220];
            s2  = f[219:200];
            s3  = f[199:180];
            s4  = f[179:160];
            if (sync_len != 16) fail("SYNC width != 16");
            if (tag !== 16'hF800) fail("tag != F800");
            if (f[159:0] !== 0) fail("slots 5..12 not zero");
            if (s1[19] !== 1'b0 || s1[11:0] !== 0 || s2[3:0] !== 0 || s3[3:0] !== 0 || s4[3:0] !== 0)
                fail("slot padding");
            // 명령은 02h -> 04h -> 18h 순환 (첫 프레임부터 위상 맞춤)
            if (frames == 1) cmd_n = (s1[18:12] == 7'h02) ? 0 : (s1[18:12] == 7'h04) ? 1 : 2;
            case (cmd_n % 3)
                0: begin exp_addr = 7'h02; exp_data = 16'h0000; end
                1: begin exp_addr = 7'h04; exp_data = 16'h0000; end
                2: begin exp_addr = 7'h18; exp_data = 16'hxxxx; end
            endcase
            if (s1[18:12] !== exp_addr) fail("command address sequence");
            if (exp_addr != 7'h18) begin
                if (s2[19:4] !== exp_data) fail("command data");
            end else if (frames > 3) begin
                // 볼륨: 바꾼 뒤 잠깐은 이전 값, 한 번 새 값이 나오면 계속 새 값
                if (s2[19:4] === vol_new) vol_new_seen = vol_new_seen + 1;
                else if (s2[19:4] !== vol_old || vol_new_seen != 0) fail("PCM volume register value");
            end
            cmd_n = cmd_n + 1;
            // PCM
            got_l = $signed(s3[19:4]);
            got_r = $signed(s4[19:4]);
            if (got_l != got_r) fail("L != R");
            if (!synced) begin
                // 기대 큐에서 같은 값이 나오는 위치를 찾는다 (처음 0 이 아닌 샘플로 정렬)
                if (got_l != 0) begin
                    while (exp_rd < exp_wr && exp_q[exp_rd] != got_l) exp_rd = exp_rd + 1;
                    if (exp_rd == exp_wr) fail("could not align PCM");
                    else begin synced = 1; exp_rd = exp_rd + 1; pcm_checked = 1; end
                end
            end else begin
                if (got_l != exp_q[exp_rd]) begin
                    $display("  frame %0d: got %0d expected %0d", frames, got_l, exp_q[exp_rd]);
                    fail("PCM mismatch");
                end
                exp_rd = exp_rd + 1;
                pcm_checked = pcm_checked + 1;
            end
        end
    endtask

    // ---- 시나리오 ----------------------------------------------------------
    initial begin
        wait (frames == 20);  level = 45;      // 계단 입력 -> 23040 에서 시작해 서서히 0 으로
        wait (frames == 60);  level = 0;       // 반대 방향 계단
        wait (frames == 80);  vol_old = vol; vol = 16'h8000 | 16'h0A0A; vol_new = vol; vol_new_seen = 0;   // 실행 중 볼륨 변경
        wait (frames == 100); level = 20;
        wait (frames == 140);
        $display("frames %0d, PCM samples checked %0d, codec_ready %b", frames, pcm_checked, ready);
        if (!ready) fail("codec_ready not seen");
        if (pcm_checked < 100) fail("too few PCM samples checked");
        if (vol_new_seen < 10) fail("new volume not applied");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #20_000_000 $display("TIMEOUT"); $finish; end
endmodule
