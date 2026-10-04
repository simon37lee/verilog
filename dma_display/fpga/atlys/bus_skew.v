// ---------------------------------------------------------------------------
// bus_skew : 버스 비트마다 일부러 다른 지연을 넣는다 (Spartan-6 LUT1 버퍼 체인)
//
//   비트 i 에 LUT1 버퍼 (i*7) mod 16 단 = 0 ~ 15 단 (단마다 LUT + 배선 약 0.5~1 ns)
//   -> 비트 간 도착 시각 차이가 수 ns 로 벌어져서, 비동기 샘플링 때 옛 값/새 값이
//      섞이는 확률이 그만큼 커진다 (확률 ~ skew 폭 / 소스 클럭 주기).
//   sel = 0 이면 지연선을 거치지 않고 그대로 연결 (배선 툴이 만든 자연스러운 skew 만 남음).
//   KEEP 이 없으면 합성/맵에서 버퍼가 지워진다.
// ---------------------------------------------------------------------------
module bus_skew #(
    parameter W = 25
) (
    input  wire         sel,
    input  wire [W-1:0] din,
    output wire [W-1:0] dout
);
    genvar i, k;
    generate
        for (i = 0; i < W; i = i + 1) begin : g_bit
            (* KEEP = "TRUE" *) wire [(i * 7) % 16 : 0] n;
            assign n[0] = din[i];
            for (k = 0; k < (i * 7) % 16; k = k + 1) begin : g_st
                LUT1 #(.INIT(2'b10)) u_buf (.I0(n[k]), .O(n[k + 1]));
            end
            assign dout[i] = sel ? n[(i * 7) % 16] : din[i];
        end
    endgenerate
endmodule
