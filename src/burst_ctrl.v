/*
 * burst_ctrl.v
 * Burst handling between spi_rx and hold_buf.
 *
 * One burst = one CS_n low period = command byte + exactly N data bytes,
 * N = ch_n + 1. Data byte k of a burst is written to hold_buf slot k
 * (byte interleave: ch0, ch1, ... ch(N-1)).
 *
 * Burst outcome, evaluated at CS_n rising edge
 *   WRITE accepted, N bytes          -> burst_ok
 *   WRITE accepted, more than N      -> burst_ok + burst_err (extra bytes dropped)
 *   WRITE accepted, fewer than N     -> burst_err (nothing committed)
 *   WRITE not accepted               -> burst_err (hold_buf full, or frame
 *                                       in DRAIN/TRESET)
 *   LATCH                            -> latch_req
 *   unknown or incomplete command    -> burst_err
 *
 * A rejected WRITE never touches hold_buf, so data waiting for px_tx is
 * never overwritten. Slots written by a short burst are harmless because
 * hold_buf is only marked full by burst_ok.
 *
 * CH[2:0] is sampled at every command byte while the frame is idle and
 * then held for the rest of the frame (static pins, not synchronized).
 *
 * DFF count: idx 3 + flags 4 + ch_n 3 + pulses 3 = 13
 */

`default_nettype none

module burst_ctrl (
    input  wire       clk,
    input  wire       rst_n,
    // from sync_in
    input  wire       cs_fall,
    input  wire       cs_rise,
    // from spi_rx
    input  wire       cmd_valid,
    input  wire [1:0] cmd,
    input  wire       byte_valid,
    // config pins
    input  wire [2:0] ch_pins,      // ui_in[7:5]
    // from frame_ctrl / hold_buf
    input  wire       frame_idle,   // FSM in IDLE
    input  wire       accept,       // FSM in IDLE or STREAM
    input  wire       hold_full,
    // to hold_buf
    output wire       wr_en,
    output wire [2:0] wr_idx,
    // to frame_ctrl / hold_buf / px_tx
    output reg        burst_ok,     // one clk pulse, also commits hold_buf
    output reg        burst_err,    // one clk pulse
    output reg        latch_req,    // one clk pulse
    output reg  [2:0] ch_n          // active channels - 1
);

  // Decoded command values (must match spi_rx)
  localparam [1:0] CMD_UNKNOWN    = 2'd0;
  localparam [1:0] CMD_WRITE      = 2'd1;
  localparam [1:0] CMD_WRITE_QUAD = 2'd2;
  localparam [1:0] CMD_LATCH      = 2'd3;

  reg [2:0] idx;        // next slot to write
  reg       cmd_seen;   // a full command byte was received in this burst
  reg       active;     // accepted WRITE burst in progress
  reg       got_all;    // N bytes received
  reg       too_long;   // more than N bytes received

  wire is_write = (cmd == CMD_WRITE) || (cmd == CMD_WRITE_QUAD);

  assign wr_en  = byte_valid & active & ~got_all;
  assign wr_idx = idx;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idx       <= 3'd0;
      cmd_seen  <= 1'b0;
      active    <= 1'b0;
      got_all   <= 1'b0;
      too_long  <= 1'b0;
      ch_n      <= 3'd0;
      burst_ok  <= 1'b0;
      burst_err <= 1'b0;
      latch_req <= 1'b0;
    end else begin
      burst_ok  <= 1'b0;
      burst_err <= 1'b0;
      latch_req <= 1'b0;

      if (cs_fall) begin
        idx      <= 3'd0;
        cmd_seen <= 1'b0;
        active   <= 1'b0;
        got_all  <= 1'b0;
        too_long <= 1'b0;
      end else if (cs_rise) begin
        if (!cmd_seen) begin
          burst_err <= 1'b1;                       // incomplete command
        end else if (active) begin
          if (got_all) begin
            burst_ok  <= 1'b1;
            burst_err <= too_long;
          end else begin
            burst_err <= 1'b1;                     // short burst
          end
        end
        active <= 1'b0;
      end else begin
        if (cmd_valid) begin
          cmd_seen <= 1'b1;
          if (frame_idle)
            ch_n <= ch_pins;
          if (is_write) begin
            if (accept && !hold_full)
              active <= 1'b1;
            else
              burst_err <= 1'b1;                   // rejected WRITE
          end else if (cmd == CMD_LATCH) begin
            latch_req <= 1'b1;
          end else begin
            burst_err <= 1'b1;                     // unknown command
          end
        end

        if (byte_valid && active) begin
          if (got_all) begin
            too_long <= 1'b1;
          end else if (idx == ch_n) begin
            got_all <= 1'b1;
          end else begin
            idx <= idx + 3'd1;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
