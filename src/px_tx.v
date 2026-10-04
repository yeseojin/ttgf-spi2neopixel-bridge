/*
 * px_tx.v
 * 8-channel NeoPixel serializer with one shared bit timer.
 *
 * All active channels send their bits at the same time, MSB first.
 * For each bit the line is high for T0H or T1H clocks and low for the
 * rest of TBIT clocks.
 *
 * A byte (8 bits) is loaded from hold_buf when the serializer is idle or
 * at the end of the previous byte, so consecutive bursts are sent
 * without a gap. If hold_buf is empty at the end of a byte the
 * serializer stops and the line stays low; frame_ctrl treats that as an
 * underrun while the frame is streaming.
 *
 * Timing structure (for setup timing at 40 MHz in the slow corner)
 *  - cc counts down from TBIT-1 to 0, so the end of a bit is cc == 0.
 *  - bit_end is a register, set one clock early from cc == 1. The load /
 *    shift enable that fans out to all 64 shift register bits therefore
 *    starts at a flip-flop output instead of after a compare.
 *  - The line is high while cc >= TBIT - TH, i.e. for the first TH clocks
 *    of the bit. The low-time thresholds come from the top level, one pair
 *    per LED type. ch_type selects the pair per channel (0 = WS2812B,
 *    1 = SK6812); the bit period is the same for both types, so all
 *    channels share one bit timer.
 *
 * Outputs are registered to keep the pins glitch free. This delays every
 * edge by one clock, which does not change any pulse width.
 *
 * Channels above ch_n are held low.
 *
 * DFF count: shift 8 x 8 + clk counter 6 + bit counter 3 + run 1
 *            + bit_end 1 + output 8 = 83 (ch_type is held in burst_ctrl)
 */

`default_nettype none

module px_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tx_en,       // frame_ctrl: STREAM or DRAIN
    input  wire [63:0] hold_data,
    input  wire        hold_full,
    input  wire [2:0]  ch_n,        // active channels - 1
    input  wire [7:0]  ch_type,     // LED type per channel, 1 = SK6812
    input  wire [5:0]  t0l_ws,      // TBIT - T0H, WS2812B, clocks
    input  wire [5:0]  t1l_ws,      // TBIT - T1H, WS2812B
    input  wire [5:0]  t0l_sk,      // TBIT - T0H, SK6812
    input  wire [5:0]  t1l_sk,      // TBIT - T1H, SK6812
    input  wire [5:0]  tbit_m1,     // TBIT - 1
    output wire        take,        // one clk pulse: hold_buf copied
    output wire        tx_idle,     // no byte in progress
    output reg  [7:0]  dout         // uo_out[7:0]
);

  reg [7:0] sh [0:7];   // shift register per channel
  reg [5:0] cc;         // clock counter within a bit, TBIT-1 down to 0
  reg [2:0] bitc;       // bit counter within a byte, 0 .. 7
  reg       run;        // a byte is being sent
  reg       bit_end;    // last clock of the current bit (cc == 0)

  wire byte_end = bit_end && (bitc == 3'd7);

  // Load a new byte when idle or exactly at the end of the current byte
  wire load = tx_en && hold_full && (!run || byte_end);

  assign take    = load;
  assign tx_idle = !run;

  // Active channel mask: ch_n = 0 -> 8'h01, ch_n = 7 -> 8'hFF
  wire [7:0] ch_mask = 8'hFF >> (3'd7 - ch_n);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cc      <= 6'd0;
      bitc    <= 3'd0;
      run     <= 1'b0;
      bit_end <= 1'b0;
    end else begin
      // cc reaches 0 on the next clock: only while running and cc == 1.
      // After a reload cc = TBIT-1 >= 19, so bit_end stays low.
      bit_end <= run && (cc == 6'd1);

      if (load) begin
        cc   <= tbit_m1;
        bitc <= 3'd0;
        run  <= 1'b1;
      end else if (byte_end) begin
        run  <= 1'b0;
      end else if (bit_end) begin
        cc   <= tbit_m1;
        bitc <= bitc + 3'd1;
      end else if (run) begin
        cc   <= cc - 6'd1;
      end
    end
  end

  // Per-channel shift register and output level. A generate loop is used
  // (not a for loop with a shared integer) so that synthesis sees one
  // independent block per channel.
  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_ch
      // Shift register: no reset needed, only used while run is set
      always @(posedge clk) begin
        if (load)
          sh[g] <= hold_data[8*g +: 8];
        else if (bit_end)
          sh[g] <= {sh[g][6:0], 1'b0};
      end

      // Low-time threshold for this channel's LED type and current bit
      wire [5:0] thr = ch_type[g] ? (sh[g][7] ? t1l_sk : t0l_sk)
                                  : (sh[g][7] ? t1l_ws : t0l_ws);

      // Output level: high for the first TH clocks of the bit
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
          dout[g] <= 1'b0;
        else
          dout[g] <= run && ch_mask[g] && (cc >= thr);
      end
    end
  endgenerate

endmodule

`default_nettype wire
