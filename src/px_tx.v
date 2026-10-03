/*
 * px_tx.v
 * 8-channel NeoPixel serializer with one shared bit timer.
 *
 * All active channels send their bits at the same time, MSB first.
 * For each bit the line is high for T0H or T1H clocks and low for the
 * rest of TBIT clocks. The timing values come from the top level and are
 * selected by SEL.
 *
 * A byte (8 bits) is loaded from hold_buf when the serializer is idle or
 * at the end of the previous byte, so consecutive bursts are sent
 * without a gap. If hold_buf is empty at the end of a byte the
 * serializer stops and the line stays low; frame_ctrl treats that as an
 * underrun while the frame is streaming.
 *
 * Outputs are registered to keep the pins glitch free. This delays every
 * edge by one clock, which does not change any pulse width.
 *
 * Channels above ch_n are held low.
 *
 * DFF count: shift 8 x 8 + clk counter 6 + bit counter 3 + run 1
 *            + output 8 = 82
 */

`default_nettype none

module px_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tx_en,       // frame_ctrl: STREAM or DRAIN
    input  wire [63:0] hold_data,
    input  wire        hold_full,
    input  wire [2:0]  ch_n,        // active channels - 1
    input  wire [5:0]  t0h,         // clocks, from top level
    input  wire [5:0]  t1h,
    input  wire [5:0]  tbit,
    output wire        take,        // one clk pulse: hold_buf copied
    output wire        tx_idle,     // no byte in progress
    output reg  [7:0]  dout         // uo_out[7:0]
);

  reg [7:0] sh [0:7];   // shift register per channel
  reg [5:0] cc;         // clock counter within a bit, 0 .. tbit-1
  reg [2:0] bitc;       // bit counter within a byte, 0 .. 7
  reg       run;        // a byte is being sent

  wire bit_end  = run && (cc == tbit - 6'd1);
  wire byte_end = bit_end && (bitc == 3'd7);

  // Load a new byte when idle or exactly at the end of the current byte
  wire load = tx_en && hold_full && (!run || byte_end);

  assign take    = load;
  assign tx_idle = !run;

  integer k;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cc   <= 6'd0;
      bitc <= 3'd0;
      run  <= 1'b0;
    end else if (load) begin
      cc   <= 6'd0;
      bitc <= 3'd0;
      run  <= 1'b1;
    end else if (byte_end) begin
      cc   <= 6'd0;
      bitc <= 3'd0;
      run  <= 1'b0;
    end else if (bit_end) begin
      cc   <= 6'd0;
      bitc <= bitc + 3'd1;
    end else if (run) begin
      cc   <= cc + 6'd1;
    end
  end

  // Shift registers: no reset needed, only used while run is set
  always @(posedge clk) begin
    for (k = 0; k < 8; k = k + 1) begin
      if (load)
        sh[k] <= hold_data[8*k +: 8];
      else if (bit_end)
        sh[k] <= {sh[k][6:0], 1'b0};
    end
  end

  // Output level per channel
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dout <= 8'h00;
    end else begin
      for (k = 0; k < 8; k = k + 1) begin
        dout[k] <= run && (k <= ch_n) &&
                   (cc < (sh[k][7] ? t1h : t0h));
      end
    end
  end

endmodule

`default_nettype wire
