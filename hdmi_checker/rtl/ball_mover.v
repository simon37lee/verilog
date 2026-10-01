// ---------------------------------------------------------------------------
// ball_mover : 체스칸 단위로 랜덤하게 움직이는 공의 위치
//
//   MOVE_CYCLES 클럭(기본 25 MHz x 0.1 s)마다 8방향(상/하/좌/우/대각선) 중
//   하나를 LFSR 로 골라 한 칸 이동한다. 가장자리에 닿으면 그 축 방향을 반대로
//   바꿔서(튕겨서) 화면 밖으로 나가지 않는다.
//
//   화면이 그려지는 도중에 위치가 바뀌면 화면이 찢어지므로(tearing),
//   이동 시점이 되면 예약만 해 두고 실제 이동은 frame_tick(블랭킹 시작)에서 한다.
// ---------------------------------------------------------------------------
module ball_mover #(
    parameter GRID_W      = 20,          // 가로 칸 수
    parameter GRID_H      = 15,          // 세로 칸 수
    parameter MOVE_CYCLES = 2_500_000    // 0.1 s @ 25 MHz
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       frame_tick,        // 프레임 표시 구간이 끝날 때 1클럭 펄스
    output reg  [6:0] cx,                // 공이 있는 칸 (열)
    output reg  [6:0] cy                 // 공이 있는 칸 (행)
);
    // ---- 0.1 s 타이머 -----------------------------------------------------
    reg [31:0] timer;
    reg        move_pending;

    // ---- 16비트 Galois LFSR (x^16 + x^14 + x^13 + x^11 + 1) ----------------
    reg [15:0] lfsr;
    always @(posedge clk) begin
        if (rst) lfsr <= 16'hACE1;
        else     lfsr <= {1'b0, lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);
    end

    // ---- 방향 선택: 0~7 -> 8방향 ------------------------------------------
    //   0:↖  1:↑  2:↗
    //   3:←       4:→
    //   5:↙  6:↓  7:↘
    reg signed [1:0] dx, dy;
    always @(*) begin
        case (lfsr[2:0])
            3'd0: begin dx = -1; dy = -1; end
            3'd1: begin dx =  0; dy = -1; end
            3'd2: begin dx =  1; dy = -1; end
            3'd3: begin dx = -1; dy =  0; end
            3'd4: begin dx =  1; dy =  0; end
            3'd5: begin dx = -1; dy =  1; end
            3'd6: begin dx =  0; dy =  1; end
            default: begin dx = 1; dy = 1; end
        endcase
        // 가장자리에서는 튕겨 나온다
        if (cx == 0          && dx < 0) dx = 1;
        if (cx == GRID_W - 1 && dx > 0) dx = -1;
        if (cy == 0          && dy < 0) dy = 1;
        if (cy == GRID_H - 1 && dy > 0) dy = -1;
    end

    always @(posedge clk) begin
        if (rst) begin
            timer        <= 0;
            move_pending <= 1'b0;
            cx           <= GRID_W / 2;
            cy           <= GRID_H / 2;
        end else begin
            if (timer == MOVE_CYCLES - 1) begin
                timer        <= 0;
                move_pending <= 1'b1;
            end else begin
                timer <= timer + 1'b1;
            end

            if (frame_tick && move_pending) begin
                cx           <= cx + {{5{dx[1]}}, dx};
                cy           <= cy + {{5{dy[1]}}, dy};
                move_pending <= (timer == MOVE_CYCLES - 1);   // 같은 클럭에 또 만료된 경우
            end
        end
    end
endmodule
