// ---------------------------------------------------------------------------
// async_fifo : 비동기 클럭 FIFO (Gray code 포인터 + 2단 동기화기)
//
//   쓰기/읽기 클럭이 서로 무관(asynchronous)해도 안전하게 데이터를 넘긴다.
//   - 포인터는 AW+1 비트 (최상위 비트는 wrap 구분용)
//   - 상대 도메인으로 넘길 때는 Gray code 로 바꿔서 한 번에 1비트만 변하게 함
//   - 넘겨받은 포인터는 2단 플립플롭으로 동기화
//   - full/empty/wlevel 은 동기화 지연 때문에 항상 "보수적"(안전한 쪽)으로 보인다
//   - 읽기 데이터는 show-ahead (rempty=0 이면 rdata 가 바로 유효)
//   - wrst/rrst 는 각 도메인에 이미 동기화된 리셋이므로 동기식 리셋으로 사용
// ---------------------------------------------------------------------------
module async_fifo #(
    parameter DW = 9,
    parameter AW = 4                 // 깊이 = 2^AW
) (
    // 쓰기 도메인
    input  wire          wclk,
    input  wire          wrst,
    input  wire          winc,
    input  wire [DW-1:0] wdata,
    output wire          wfull,
    output wire [AW:0]   wlevel,     // 쓰기 쪽에서 본 사용량 (실제 이상으로 보일 수 있음)
    // 읽기 도메인
    input  wire          rclk,
    input  wire          rrst,
    input  wire          rinc,
    output wire [DW-1:0] rdata,
    output wire          rempty
);
    localparam DEPTH = 1 << AW;

    reg [DW-1:0] mem [0:DEPTH-1];

    function [AW:0] bin2gray;
        input [AW:0] b;
        bin2gray = b ^ (b >> 1);
    endfunction

    // b[i] = g[AW] ^ ... ^ g[i]  (위쪽 비트들의 XOR). 시프트-XOR 로 계산 (AW+1 <= 16 비트)
    function [AW:0] gray2bin;
        input [AW:0] g;
        reg   [AW:0] b;
        begin
            b = g ^ (g >> 1);
            b = b ^ (b >> 2);
            b = b ^ (b >> 4);
            b = b ^ (b >> 8);
            gray2bin = b;
        end
    endfunction

    // ---- 쓰기 도메인 -------------------------------------------------------
    reg [AW:0] wbin, wgray;
    reg [AW:0] rgray_w1, rgray_w2;          // 읽기 포인터 동기화기

    always @(posedge wclk) begin
        if (wrst) {rgray_w2, rgray_w1} <= 0;
        else      {rgray_w2, rgray_w1} <= {rgray_w1, rgray};
    end

    // 꽉 참: 상위 2비트만 반대이고 나머지가 같으면 (Gray code 에서의 full 조건)
    assign wfull  = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    assign wlevel = wbin - gray2bin(rgray_w2);

    always @(posedge wclk) begin
        if (wrst) begin
            wbin  <= 0;
            wgray <= 0;
        end else if (winc && !wfull) begin
            mem[wbin[AW-1:0]] <= wdata;
            wbin  <= wbin + 1'b1;
            wgray <= bin2gray(wbin + 1'b1);
        end
    end

    // ---- 읽기 도메인 -------------------------------------------------------
    reg [AW:0] rbin, rgray;
    reg [AW:0] wgray_r1, wgray_r2;          // 쓰기 포인터 동기화기

    always @(posedge rclk) begin
        if (rrst) {wgray_r2, wgray_r1} <= 0;
        else      {wgray_r2, wgray_r1} <= {wgray_r1, wgray};
    end

    assign rempty = (rgray == wgray_r2);
    assign rdata  = mem[rbin[AW-1:0]];

    always @(posedge rclk) begin
        if (rrst) begin
            rbin  <= 0;
            rgray <= 0;
        end else if (rinc && !rempty) begin
            rbin  <= rbin + 1'b1;
            rgray <= bin2gray(rbin + 1'b1);
        end
    end
endmodule
