//==============================================================================
// s3_vga_general.sv
//
// "General" VGA registers — those that aren't part of an indexed block:
//   3C2 W  : Misc Output
//   3CC R  : Misc Output (readback)
//   3C2 R  : Input Status 0
//   3DA/3BA R : Input Status 1   (also resets AR flip-flop on either port)
//   3DA/3BA W : Feature Control  (most bits ignored on VGA)
//
// Clock/reset: synchronous, active-low rst_n.
//
// Misc Output (3C2 W) bit map (FreeVGA):
//   [7] VSYNC polarity     (1 = negative)
//   [6] HSYNC polarity     (1 = negative)
//   [5] Page select        (odd/even page, 64K mode)
//   [3:2] Clock select     (00 = 25.175 MHz, 01 = 28.322 MHz, others = ext)
//   [1] Enable RAM
//   [0] I/O address select (1 = color = 3Dx, 0 = mono = 3Bx)
//
// Cross-module side effect:
//   `ar_ff_clr_pulse` asserts for one cycle when status1 is read at either
//   3DA or 3BA — used by s3_attribute_controller to reset its index/data
//   flip-flop.
//==============================================================================

`include "s3_pkg.sv"

module s3_vga_general
  import s3_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  host_req_t   host_req,
  input  bus_target_e target,
  output host_rsp_t   host_rsp,

  // Live timing inputs from s3_timing_gen (Phase 2b). Stubbed to 0 here.
  input  logic        vretrace_active,
  input  logic        display_disabled,    // hblank | vblank
  input  logic        switch_sense,        // monitor sense (3C2.R bit 4)
  input  logic        crt_interrupt,       // light pen / CRT interrupt (3C2.R bit 7)

  // Exported state
  output logic [7:0]  misc_out,
  output logic        ar_ff_clr_pulse
);

  logic [7:0] misc_out_q;

  // Misc Output: write at 3C2, readback at 3CC.
  // Reset value: 0x00 (host BIOS will program it).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      misc_out_q <= 8'h00;
    end else if (target == TGT_VGA_GENERAL && wr_to(host_req, 16'h03C2)) begin
      misc_out_q <= wr_byte(host_req, 16'h03C2);
    end
  end

  assign misc_out = misc_out_q;

  // Status 1: reading 3DA *or* 3BA returns vretrace/display-disabled status
  // *and* resets the AR flip-flop.
  // (We accept both ports always; the host gates with Misc.IO_AS for real.)
  wire rd_status1 = (target == TGT_VGA_GENERAL) &&
                    (rd_from(host_req, 16'h03DA) || rd_from(host_req, 16'h03BA));

  assign ar_ff_clr_pulse = rd_status1;

  // Status 0 at 3C2 R: bit[7] = CRT interrupt, bit[4] = switch sense, rest = 0.
  wire rd_status0 = (target == TGT_VGA_GENERAL) && rd_from(host_req, 16'h03C2);

  // Misc readback at 3CC.
  wire rd_misc = (target == TGT_VGA_GENERAL) && rd_from(host_req, 16'h03CC);

  logic [7:0] status0_byte;
  logic [7:0] status1_byte;

  always_comb begin
    status0_byte = '0;
    status0_byte[7] = crt_interrupt;
    status0_byte[4] = switch_sense;

    status1_byte = '0;
    status1_byte[3] = vretrace_active;
    status1_byte[0] = display_disabled;
    // diagnostic bits 5:4 reflect attribute output during retrace — left 0 here.
  end

  // Response: a register touch in our space yields a 1-cycle ready.
  always_comb begin
    host_rsp = '0;
    if (target == TGT_VGA_GENERAL && host_req.req) begin
      host_rsp.ready = 1'b1;
      if (!host_req.we) begin
        // Build the right byte slot. mk_rdata centralises the be/addr decode.
        if (rd_status0)        host_rsp.rdata = mk_rdata(host_req, status0_byte, 8'h00);
        else if (rd_misc)      host_rsp.rdata = mk_rdata(host_req, misc_out_q,  8'h00);
        else if (rd_from(host_req,16'h03DA))
                               host_rsp.rdata = mk_rdata(host_req, status1_byte, 8'h00);
        else if (rd_from(host_req,16'h03BA))
                               host_rsp.rdata = mk_rdata(host_req, status1_byte, 8'h00);
      end
    end
  end

endmodule
