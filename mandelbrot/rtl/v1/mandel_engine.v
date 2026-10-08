// ---------------------------------------------------------------------------
// mandel_engine (v1) : 픽셀 스케줄러 + 코어 1 개, 픽셀을 하나씩 순서대로 계산
//
//   버전마다 이 파일 (과 코어) 이 바뀐다. 인터페이스는 모든 버전이 같다:
//     start      : 1 클럭 펄스. 이때 x0 / top / step / max_iter 를 래치하고 프레임 하나를 계산한다
//     x0, top    : 왼쪽 위 픽셀의 c (CW = W + 8 비트, 소수부 FRAC + 8)
//     step       : 픽셀 간격 (같은 형식)
//     fb_we/addr/data : 픽셀 번호 (py * FB_W + px) 와 결과. 쓰는 순서는 자유 (버전마다 다름)
//                       집합 안쪽 (n == max_iter) 은 0, 탈출한 점은 반복 횟수 (1 이상)
//     done       : 1 클럭 펄스. 마지막 쓰기와 같은 클럭이거나 그 뒤
//
//   c_re(px) = x0 + px * step,  c_im(py) = top - py * step  (덧셈 누적, 코어에는 아래 8 비트를 버리고 넘김)
//
//   v1: S_START -> 코어 start -> done 대기 -> 쓰기. 픽셀당 오버헤드 4 클럭 + 반복 횟수
// ---------------------------------------------------------------------------
module mandel_engine #(
    parameter W    = 18,
    parameter FRAC = W - 4,
    parameter IW   = 8,
    parameter FB_W = 320,
    parameter FB_H = 240,
    parameter PW   = 17                 // 픽셀 번호 비트 수
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
    output wire              busy       // 코어 계산 중 (LED)
);
    localparam CW = W + 8;

    // ---- 코어 ----------------------------------------------------------------
    reg                 core_start;
    reg  signed [W-1:0] core_re, core_im;
    wire                core_done;
    wire       [IW-1:0] core_iter;
    reg        [IW-1:0] max_lat;

    mandel_core #(.W(W), .FRAC(FRAC), .IW(IW)) u_core (
        .clk(clk), .rst(rst),
        .start(core_start), .c_re(core_re), .c_im(core_im), .max_iter(max_lat),
        .busy(busy), .done(core_done), .iter(core_iter)
    );

    // ---- 픽셀 스케줄러 --------------------------------------------------------
    localparam S_IDLE = 2'd0, S_START = 2'd1, S_WAIT = 2'd2;
    reg [1:0]  state;
    reg [8:0]  px;
    reg [7:0]  py;
    reg [PW-1:0] idx;
    reg signed [CW-1:0] x0_lat, cur_re, cur_im;
    reg        [CW-1:0] step_lat;

    always @(posedge clk) begin
        fb_we      <= 1'b0;
        done       <= 1'b0;
        core_start <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    x0_lat   <= x0;
                    cur_re   <= x0;
                    cur_im   <= top;
                    step_lat <= step;
                    max_lat  <= max_iter;
                    px       <= 0;
                    py       <= 0;
                    idx      <= 0;
                    state    <= S_START;
                end
                // core_start 는 다음 클럭 (S_WAIT) 에 1 -> 그때 코어는 이미 idle (done 과 함께 busy = 0)
                S_START: begin
                    core_start <= 1'b1;
                    core_re    <= cur_re[CW-1 -: W];      // >>> 8
                    core_im    <= cur_im[CW-1 -: W];
                    state      <= S_WAIT;
                end
                S_WAIT: if (core_done) begin
                    fb_we   <= 1'b1;
                    fb_addr <= idx;
                    fb_data <= (core_iter == max_lat) ? {IW{1'b0}} : core_iter;
                    idx     <= idx + 1'b1;
                    state   <= S_START;
                    if (px == FB_W - 1) begin
                        px     <= 0;
                        cur_re <= x0_lat;
                        cur_im <= cur_im - step_lat;
                        if (py == FB_H - 1) begin
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            py <= py + 1'b1;
                        end
                    end else begin
                        px     <= px + 1'b1;
                        cur_re <= cur_re + step_lat;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
