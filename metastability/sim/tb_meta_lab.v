// ---------------------------------------------------------------------------
// tb_meta_lab : meta_lab_core 전체 시뮬레이션 -> 화면 한 장을 PPM 으로 저장
//
//   clk 100 MHz, clk_s = clk 를 SAMPLE_PS 만큼 늦춘 것 (보드의 PLL 위상 출력과 같은 관계)
//   +ACC_US=<n>  히스토그램을 n us 동안 쌓은 뒤 화면 한 장을 저장 (기본 3000)
//   +OUT=<file>  저장 파일 (기본 build/meta_lab.ppm)
//   +SWAP=1      두 측정 회로의 입력을 맞바꾼다 (보드의 SW0)
//   +ZOOM=1      그래프 확대 (보드의 SW1)
// ---------------------------------------------------------------------------
`timescale 1ps / 1ps

module tb_meta_lab;
    localparam SAMPLE_PS = 4000;

    reg clk = 0, clk_s = 0, clk_pix = 0, rst = 1, swap = 0, zoom = 0;
    always #5000  clk = ~clk;
    always @(clk) clk_s <= #(SAMPLE_PS) clk;
    always #20000 clk_pix = ~clk_pix;

    wire d_async;
    ring_osc u_ro (.en(1'b1), .out(d_async));

    wire [7:0]  r, g, b;
    wire        de, hsync, vsync, clearing;
    wire [31:0] total_a, total_b;

    // 모델의 탭 지연 20 ps -> tau 표시 환산도 20.0 ps. 모델 tau = 40 ps 이므로 약 40 ps 가 나와야 한다
    // 시뮬레이션은 이벤트 수가 적고 지터가 없으므로 꼬리 기준을 얕게 (보드는 16)
    meta_lab_core #(.TAP_X10_A(200), .TAP_X10_B(200), .TAIL_SHIFT(8)) dut (
        .clk(clk), .clk_s(clk_s), .clk_pix(clk_pix), .rst(rst), .d_async(d_async), .swap(swap), .zoom(zoom),
        .r(r), .g(g), .b(b), .de(de), .hsync(hsync), .vsync(vsync),
        .total_a(total_a), .total_b(total_b), .clearing(clearing)
    );

    // 보드처럼 측정 회로 B 의 FF -> 지연선 배선을 0.47 ns 더 길게 (봉우리 위치가 회로마다 다름)
    initial dut.u_det_b.u_chain.route = 1270;

    integer acc_us, f, n, sw;
    reg [8*64-1:0] out;
    initial begin
        if (!$value$plusargs("ACC_US=%d", acc_us)) acc_us = 3000;
        if (!$value$plusargs("OUT=%s", out)) out = "build/meta_lab.ppm";
        if ($value$plusargs("SWAP=%d", sw)) swap = sw[0];
        if ($value$plusargs("ZOOM=%d", sw)) zoom = sw[0];
        #100000 rst = 0;
        repeat (acc_us) #1000000;
        $display("accumulated %0d us: chain A events %0d, chain B events %0d (swap %0d)", acc_us, total_a, total_b, swap);
        $display("tau A: status %0d %h (x0.1 ps)   tau B: status %0d %h", dut.u_disp.st_a, dut.u_disp.tau_a,
                 dut.u_disp.st_b, dut.u_disp.tau_b);

        // 다음 프레임 시작 (vsync 끝) 부터 표시 구간 픽셀을 저장
        @(negedge vsync); @(posedge vsync);
        f = $fopen(out, "w");
        $fwrite(f, "P3\n640 480\n255\n");
        n = 0;
        while (n < 640 * 480) begin
            @(posedge clk_pix);
            if (de) begin
                $fwrite(f, "%0d %0d %0d\n", r, g, b);
                n = n + 1;
            end
        end
        $fclose(f);
        $display("saved %0s", out);
        $finish;
    end
endmodule
