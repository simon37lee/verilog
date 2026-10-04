// ---------------------------------------------------------------------------
// tb_async_fifo : 비동기 FIFO 검증
//   - 서로 무관한 클럭 (33 MHz / 22 MHz 근처, 위상이 계속 흘러감)
//   - 쓰기/읽기 쪽 모두 무작위로 쉬면서 동작
//   - 순서대로 증가하는 값을 넣고, 읽은 값이 빠짐/중복/순서 오류 없이 나오는지 확인
//   - wfull 일 때 쓰기, rempty 일 때 읽기는 무시되는지, wlevel 이 깊이를 넘지 않는지
//   - 두 클럭 비율을 바꿔 (읽기가 빠른 경우/느린 경우) 두 번 돌린다
// ---------------------------------------------------------------------------
`timescale 1ps / 1ps

module tb_async_fifo;
    localparam DW = 9, AW = 4, DEPTH = 1 << AW;
    localparam COUNT = 20000;

    reg  wclk = 0, rclk = 0, rst = 1;
    reg  winc = 0, rinc = 0;
    reg  [DW-1:0] wdata = 0;
    wire [DW-1:0] rdata;
    wire wfull, rempty;
    wire [AW:0] wlevel;
    wire [AW:0] wgray, rgray;               // 도메인을 건너는 Gray 포인터 (그대로 연결)

    integer whalf = 15151, rhalf = 22727;   // 33 MHz / 22 MHz
    always #(whalf) wclk = ~wclk;
    always #(rhalf) rclk = ~rclk;

    async_fifo #(.DW(DW), .AW(AW)) dut (
        .wclk(wclk), .wrst(rst), .winc(winc), .wdata(wdata), .wfull(wfull), .wlevel(wlevel),
        .rclk(rclk), .rrst(rst), .rinc(rinc), .rdata(rdata), .rempty(rempty),
        .wgray_x(wgray), .wgray_s(wgray), .rgray_x(rgray), .rgray_s(rgray)
    );

    integer sent, recv, errors = 0, max_level = 0, run;
    reg     wr_done;

    // 쓰기 쪽: 무작위로 쉬면서 순서대로 증가하는 값
    always @(posedge wclk) if (!rst) begin
        if (winc && !wfull) begin
            sent  = sent + 1;
            wdata <= sent[DW-1:0];
        end
        if (wlevel > max_level) max_level = wlevel;
        if (wlevel > DEPTH) begin
            $display("ERROR: wlevel %0d > depth", wlevel);
            errors = errors + 1;
        end
        winc <= (sent < COUNT) && ($random % 4 != 0);
    end

    // 읽기 쪽: 무작위로 쉬면서 읽고 값 확인
    always @(posedge rclk) if (!rst) begin
        if (rinc && !rempty) begin
            if (rdata !== recv[DW-1:0]) begin
                if (errors < 10) $display("ERROR: run %0d expected %0d got %0d", run, recv[DW-1:0], rdata);
                errors = errors + 1;
            end
            recv = recv + 1;
        end
        rinc <= ($random % 3 != 0);
    end

    task do_run;
        input integer wh, rh;
        begin
            rst = 1; winc = 0; rinc = 0;
            whalf = wh; rhalf = rh;
            sent = 0; recv = 0; wdata = 0;
            #200000 rst = 0;
            wait (recv == COUNT);
            #500000;
            if (recv != COUNT) begin
                $display("ERROR: run %0d received %0d extra", run, recv - COUNT);
                errors = errors + 1;
            end
            $display("run %0d: wclk half %0d ps, rclk half %0d ps -> %0d words OK so far, max wlevel %0d",
                     run, wh, rh, recv, max_level);
        end
    endtask

    initial begin
        run = 0; do_run(15151, 22727);   // 쓰기 33 MHz, 읽기 22 MHz (읽기가 느림)
        run = 1; do_run(22727, 15151);   // 반대 (읽기가 빠름)
        run = 2; do_run(15151, 15149);   // 거의 같은 주파수 (위상이 아주 천천히 흐름)
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
