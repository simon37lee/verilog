// ---------------------------------------------------------------------------
// mandel_engine (v2) : 픽셀 생성기 + 4 단 파이프라인 링 1 개 (픽셀 4 개 인터리브)
//
//   인터페이스는 v1 과 같다 (rtl/v1/mandel_engine.v 머리말 참고).
//
//   생성기는 픽셀을 순서대로 (px, py) 만들어 두고, 링이 in_ready 일 때마다 하나씩 넣는다.
//   링에서 끝난 픽셀은 바로 프레임버퍼에 쓰고, 그 클럭에 같은 자리로 새 픽셀이 들어간다
//   -> v1 의 픽셀당 오버헤드 (start / done 대기 4 클럭) 가 없다.
//   픽셀마다 반복 횟수가 달라서 결과는 들어간 순서와 다르게 나온다 (주소를 같이 들고 다님).
//   NPIX 개를 다 쓰면 done.
//
//   `define SLOTS 로 링에 동시에 넣을 픽셀 수를 바꿀 수 있다 (기본 4, 1 = 인터리브 없음 비교용)
//     make V=2 DEFS=SLOTS=1 check
// ---------------------------------------------------------------------------
module mandel_engine #(
    parameter W    = 18,
    parameter FRAC = W - 4,
    parameter IW   = 8,
    parameter FB_W = 320,
    parameter FB_H = 240,
    parameter PW   = 17
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire signed [W+7:0] x0,
    input  wire signed [W+7:0] top,
    input  wire        [W+7:0] step,
    input  wire     [IW-1:0] max_iter,
    output reg               fb_we,
    output reg      [PW-1:0] fb_addr,
    output reg      [IW-1:0] fb_data,
    output reg               done,
    output wire              busy
);
    localparam CW   = W + 8;
    localparam NPIX = FB_W * FB_H;
`ifdef SLOTS
    localparam RING_SLOTS = `SLOTS;
`else
    localparam RING_SLOTS = 4;
`endif

    // ---- 픽셀 생성기 ----------------------------------------------------------
    reg                 gen_valid;          // 아직 넣을 픽셀이 남음
    reg  [8:0]          px;
    reg  [7:0]          py;
    reg  [PW-1:0]       idx;
    reg  signed [CW-1:0] x0_lat, cur_re, cur_im;
    reg         [CW-1:0] step_lat;
    reg        [IW-1:0] max_lat;

    wire          ring_ready;
    wire          take = gen_valid && ring_ready;

    always @(posedge clk) begin
        if (rst) begin
            gen_valid <= 1'b0;
        end else if (start) begin
            gen_valid <= 1'b1;
            x0_lat    <= x0;
            cur_re    <= x0;
            cur_im    <= top;
            step_lat  <= step;
            max_lat   <= max_iter;
            px        <= 0;
            py        <= 0;
            idx       <= 0;
        end else if (take) begin
            idx <= idx + 1'b1;
            if (px == FB_W - 1) begin
                px     <= 0;
                cur_re <= x0_lat;
                cur_im <= cur_im - step_lat;
                if (py == FB_H - 1) gen_valid <= 1'b0;
                else                py <= py + 1'b1;
            end else begin
                px     <= px + 1'b1;
                cur_re <= cur_re + step_lat;
            end
        end
    end

    // ---- 링 ------------------------------------------------------------------
    wire          out_valid;
    wire [PW-1:0] out_idx;
    wire [IW-1:0] out_iter;

    mandel_ring #(.W(W), .FRAC(FRAC), .IW(IW), .PW(PW), .SLOTS(RING_SLOTS)) u_ring (
        .clk(clk), .rst(rst), .max_iter(max_lat),
        .in_valid(gen_valid), .in_re(cur_re[CW-1 -: W]), .in_im(cur_im[CW-1 -: W]), .in_idx(idx),
        .in_ready(ring_ready),
        .out_valid(out_valid), .out_idx(out_idx), .out_iter(out_iter),
        .busy(busy)
    );

    // ---- 결과 쓰기 ------------------------------------------------------------
    reg [PW-1:0] written;

    always @(posedge clk) begin
        fb_we   <= out_valid;
        fb_addr <= out_idx;
        fb_data <= (out_iter == max_lat) ? {IW{1'b0}} : out_iter;
        done    <= 1'b0;
        if (rst || start) begin
            written <= 0;
        end else if (out_valid) begin
            written <= written + 1'b1;
            if (written == NPIX - 1) done <= 1'b1;
        end
    end
endmodule
