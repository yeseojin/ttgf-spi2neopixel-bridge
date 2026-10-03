/*
 * frame_ctrl.v
 * Frame state machine, reset/latch timing, READY and ERROR.
 *
 * States
 *   IDLE    no frame. First burst_ok starts a frame -> STREAM
 *   STREAM  bytes are sent. latch_req -> DRAIN
 *           underrun (serializer idle, hold_buf empty) for TRESET clocks
 *           -> treated as LATCH, back to IDLE (line already low that long)
 *   DRAIN   remaining data in hold_buf / serializer is sent -> TRESET
 *   TRESET  line held low for TRESET clocks -> IDLE
 *
 * READY = FSM in IDLE or STREAM and hold_buf empty (registered).
 * ERROR is set by burst_err or by the start of an underrun. It stays set
 * after the frame ends, so the MCU can read it once READY is high again,
 * and is cleared when the next frame starts (first burst_ok in IDLE).
 * A long burst that starts a frame sets it again in the same cycle.
 *
 * DFF count: state 2 + counter 14 + ready 1 + error 1 = 18
 */

`default_nettype none

module frame_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        burst_ok,
    input  wire        burst_err,
    input  wire        latch_req,
    input  wire        hold_full,
    input  wire        tx_idle,
    input  wire [13:0] treset,      // clocks, from top level
    output wire        frame_idle,  // to burst_ctrl
    output wire        accept,      // to burst_ctrl
    output wire        tx_en,       // to px_tx
    output reg         ready,       // uio[2]
    output reg         error        // uio[3]
);

  localparam [1:0] S_IDLE   = 2'd0;
  localparam [1:0] S_STREAM = 2'd1;
  localparam [1:0] S_DRAIN  = 2'd2;
  localparam [1:0] S_TRESET = 2'd3;

  reg [1:0]  state;
  reg [13:0] cnt;

  wire starved  = tx_idle && !hold_full;          // nothing to send
  wire underrun = (state == S_STREAM) && starved;
  wire cnt_done = (cnt == treset - 14'd1);

  assign frame_idle = (state == S_IDLE);
  assign accept     = (state == S_IDLE) || (state == S_STREAM);
  assign tx_en      = (state == S_STREAM) || (state == S_DRAIN);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      cnt   <= 14'd0;
      ready <= 1'b0;
      error <= 1'b0;
    end else begin
      ready <= accept && !hold_full;

      if (burst_err)
        error <= 1'b1;

      case (state)
        S_IDLE: begin
          cnt <= 14'd0;
          if (burst_ok) begin
            state <= S_STREAM;
            error <= burst_err;                 // clear, unless this burst failed
          end
        end

        S_STREAM: begin
          if (latch_req) begin
            state <= S_DRAIN;
            cnt   <= 14'd0;
          end else if (underrun) begin
            if (cnt == 14'd0)
              error <= 1'b1;                    // underrun started
            if (cnt_done) begin
              state <= S_IDLE;                  // treated as LATCH
              cnt   <= 14'd0;
            end else begin
              cnt <= cnt + 14'd1;
            end
          end else begin
            cnt <= 14'd0;
          end
        end

        S_DRAIN: begin
          cnt <= 14'd0;
          if (starved)
            state <= S_TRESET;
        end

        default: begin // S_TRESET
          if (cnt_done) begin
            state <= S_IDLE;
            cnt   <= 14'd0;
          end else begin
            cnt <= cnt + 14'd1;
          end
        end
      endcase
    end
  end

endmodule

`default_nettype wire
