// ---------------------------------------------------------------------------
// tb_tmds_serializer_ddr : 클럭당 2비트 TMDS 직렬화기 검증
//   - clk_pix(25 MHz) 와 clk_x5(125 MHz) 를 같은 위상으로 만든다 (같은 PLL 출력과 같은 관계)
//   - 픽셀 클럭마다 무작위 10비트 워드 3개를 넣고, DDR 출력 순서(s[0] 다음 s[1])로
//     비트열을 다시 모아 10비트씩 끊었을 때 넣은 워드가 순서대로 나오는지 확인
//   - 클럭 채널은 항상 0000011111 (LSB 먼저) 이어야 한다
// ---------------------------------------------------------------------------
`timescale 1ps / 1ps

module tb_tmds_serializer_ddr;
    localparam WORDS = 2000;

    reg clk_x5 = 0, clk_pix = 0, rst = 1;
    always #4000 clk_x5 = ~clk_x5;           // 125 MHz
    always #20000 clk_pix = ~clk_pix;        // 25 MHz, 상승 에지가 clk_x5 와 맞물림

    reg  [9:0] ch0 = 0, ch1 = 0, ch2 = 0;
    wire [1:0] s0, s1, s2, sc;

    tmds_serializer_ddr dut (
        .clk_x5(clk_x5), .rst(rst), .ch0(ch0), .ch1(ch1), .ch2(ch2),
        .s_ch0(s0), .s_ch1(s1), .s_ch2(s2), .s_clk(sc)
    );

    // 보낸 워드 기록
    reg [29:0] sent [0:WORDS+16];
    integer    nsent = 0;
    always @(posedge clk_pix) if (!rst) begin
        ch0 <= $random; ch1 <= $random; ch2 <= $random;
        sent[nsent] <= {ch2, ch1, ch0};
        nsent <= nsent + 1;
    end

    // 출력 비트열을 다시 10비트 워드로 (클럭 채널 패턴으로 워드 경계를 찾는다)
    reg [9:0] r0, r1, r2, rc;
    integer   nbits = 0, nrecv = 0, errors = 0, offset = -1, k;
    always @(posedge clk_x5) if (!rst) begin
        r0 = {s0, r0[9:2]};
        r1 = {s1, r1[9:2]};
        r2 = {s2, r2[9:2]};
        rc = {sc, rc[9:2]};
        nbits = nbits + 2;
        if (offset < 0 && rc == 10'b0000011111)
            nbits = 10;                      // 첫 경계 발견
        if (rc == 10'b0000011111 && nbits == 10) begin
            nbits = 0;
            if (offset < 0) begin            // 첫 워드가 보낸 기록의 몇 번째인지 찾기
                for (k = 0; k < nsent; k = k + 1)
                    if (sent[k] == {r2, r1, r0} && offset < 0) offset = k;
            end else if (sent[offset + nrecv] !== {r2, r1, r0}) begin
                if (errors < 5) $display("word %0d: got %h expected %h", nrecv, {r2, r1, r0}, sent[offset + nrecv]);
                errors = errors + 1;
            end
            if (offset >= 0) nrecv = nrecv + 1;
        end else if (nbits == 10) begin
            if (offset >= 0) begin
                if (errors < 5) $display("clock channel pattern broken at word %0d: %b", nrecv, rc);
                errors = errors + 1;
            end
            nbits = 0;
        end
    end

    initial begin
        repeat (4) @(posedge clk_pix);
        rst <= 0;
        wait (nrecv == WORDS);
        if (offset < 0 || errors) $display("FAIL: %0d errors (offset %0d)", errors, offset);
        else                      $display("PASS: %0d words", nrecv);
        $finish;
    end
endmodule
