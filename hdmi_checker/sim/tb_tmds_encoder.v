// ---------------------------------------------------------------------------
// tb_tmds_encoder : 임의 데이터로 TMDS 인코더 검증
//   - 디코딩 결과가 입력과 같은지
//   - 데이터 구간의 누적 DC 불균형이 일정 범위 안에 머무는지
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_tmds_encoder;
    reg       clk = 0, rst = 1;
    reg [7:0] d = 0;
    reg       de = 0, c0 = 0, c1 = 0;
    wire [9:0] q;

    always #5 clk = ~clk;

    tmds_encoder dut (.clk(clk), .rst(rst), .d(d), .c0(c0), .c1(c1), .de(de), .q_out(q));

    function [7:0] decode;
        input [9:0] w;
        reg   [7:0] dd;
        integer k;
        begin
            dd = w[9] ? ~w[7:0] : w[7:0];
            decode[0] = dd[0];
            for (k = 1; k < 8; k = k + 1)
                decode[k] = w[8] ? (dd[k] ^ dd[k-1]) : ~(dd[k] ^ dd[k-1]);
        end
    endfunction

    function integer ones;
        input [9:0] v;
        integer k;
        begin
            ones = 0;
            for (k = 0; k < 10; k = k + 1) ones = ones + v[k];
        end
    endfunction

    integer i, errors = 0, disp = 0, max_disp = 0;
    reg [7:0] exp_d;
    reg       exp_de;

    initial begin
        @(posedge clk); rst = 0;
        for (i = 0; i < 200000; i = i + 1) begin
            @(negedge clk);
            d  = $random;
            de = ($random % 64) != 0;          // 가끔 블랭킹 구간
            {c1, c0} = $random;
            exp_d  = d;
            exp_de = de;
            @(posedge clk); #1;
            if (exp_de) begin
                if (decode(q) !== exp_d) begin
                    if (errors < 10) $display("ERROR: in %h decoded %h (q=%b)", exp_d, decode(q), q);
                    errors = errors + 1;
                end
                disp = disp + 2 * ones(q) - 10;
                if (disp > max_disp) max_disp = disp;
                if (-disp > max_disp) max_disp = -disp;
            end else begin
                disp = 0;
            end
        end
        $display("max DC disparity = %0d", max_disp);
        if (max_disp > 20) errors = errors + 1;
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
