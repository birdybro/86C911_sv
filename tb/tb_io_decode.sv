//==============================================================================
// tb_io_decode.sv
//
// Self-checking testbench for s3_io_decode. Drives synthetic host_req_t
// transactions and verifies the resulting target / offset / decoded outputs.
//
// Built with verilator --binary tb_io_decode.sv ...
//==============================================================================

`include "s3_pkg.sv"

module tb_io_decode;
  import s3_pkg::*;

  // -- DUT IO ----------------------------------------------------------------
  host_req_t   req;
  bus_target_e target;
  logic [23:0] offset;
  logic        decoded;

  s3_io_decode #(.LINEAR_APER_EN(1'b0)) dut (
    .host_req (req),
    .target   (target),
    .offset   (offset),
    .decoded  (decoded)
  );

  // -- helpers ---------------------------------------------------------------
  int errors = 0;

  task automatic do_check(
      input string         label,
      input host_req_t     stim,
      input bus_target_e   exp_target,
      input logic [23:0]   exp_offset,
      input logic          exp_decoded
  );
    req = stim;
    #1;
    if (target  !== exp_target ||
        offset  !== exp_offset ||
        decoded !== exp_decoded) begin
      $display("FAIL  %0s  addr=%h is_mem=%0b -> got target=%0d offset=%h decoded=%0b   (exp target=%0d offset=%h decoded=%0b)",
               label, stim.addr, stim.is_mem,
               target, offset, decoded,
               exp_target, exp_offset, exp_decoded);
      errors++;
    end else begin
      $display("ok    %0s  addr=%h target=%0d", label, stim.addr, target);
    end
  endtask

  function automatic host_req_t mk_io(input logic [15:0] port, input logic we);
    host_req_t r;
    r        = '0;
    r.req    = 1'b1;
    r.is_mem = 1'b0;
    r.we     = we;
    r.addr   = {8'h00, port};
    r.be     = 2'b01;
    return r;
  endfunction

  function automatic host_req_t mk_mem(input logic [23:0] a, input logic we);
    host_req_t r;
    r        = '0;
    r.req    = 1'b1;
    r.is_mem = 1'b1;
    r.we     = we;
    r.addr   = a;
    r.be     = 2'b01;
    return r;
  endfunction

  // -- stimulus --------------------------------------------------------------
  initial begin
    $display("=== tb_io_decode ===");

    // Idle: req==0 means no decode
    do_check("idle", '0, TGT_NONE, 24'h0, 1'b0);

    // -- VGA general / status / DAC / sequencer / gfx / AC --------------------
    do_check("3C2 misc_out_w", mk_io(16'h03C2, 1'b1), TGT_VGA_GENERAL, 24'h0003C2, 1'b1);
    do_check("3CC misc_out_r", mk_io(16'h03CC, 1'b0), TGT_VGA_GENERAL, 24'h0003CC, 1'b1);
    do_check("3C4 seq idx",    mk_io(16'h03C4, 1'b1), TGT_VGA_SEQ,     24'h0003C4, 1'b1);
    do_check("3C5 seq data",   mk_io(16'h03C5, 1'b1), TGT_VGA_SEQ,     24'h0003C5, 1'b1);
    do_check("3C6 DAC pmask",  mk_io(16'h03C6, 1'b1), TGT_VGA_DAC,     24'h0003C6, 1'b1);
    do_check("3C9 DAC data",   mk_io(16'h03C9, 1'b1), TGT_VGA_DAC,     24'h0003C9, 1'b1);
    do_check("3C0 AC",         mk_io(16'h03C0, 1'b1), TGT_VGA_AC,      24'h0003C0, 1'b1);
    do_check("3CE GFX idx",    mk_io(16'h03CE, 1'b1), TGT_VGA_GFX,     24'h0003CE, 1'b1);
    do_check("3CF GFX data",   mk_io(16'h03CF, 1'b1), TGT_VGA_GFX,     24'h0003CF, 1'b1);

    // -- CRTC (both color & mono) ---------------------------------------------
    do_check("3D4 CRTC col idx", mk_io(16'h03D4, 1'b1), TGT_VGA_CRTC, 24'h0003D4, 1'b1);
    do_check("3D5 CRTC col data",mk_io(16'h03D5, 1'b1), TGT_VGA_CRTC, 24'h0003D5, 1'b1);
    do_check("3B4 CRTC mono idx",mk_io(16'h03B4, 1'b1), TGT_VGA_CRTC, 24'h0003B4, 1'b1);
    do_check("3DA stat1",        mk_io(16'h03DA, 1'b0), TGT_VGA_GENERAL, 24'h0003DA, 1'b1);

    // -- Accelerator: 8514/A legacy and S3-new aliases must hit same target --
    do_check("82E8 CUR_Y leg",  mk_io(16'h82E8, 1'b1), TGT_ACCEL, 24'h0082E8, 1'b1);
    do_check("8148 CUR_Y new",  mk_io(16'h8148, 1'b1), TGT_ACCEL, 24'h008148, 1'b1);
    do_check("9AE8 CMD leg",    mk_io(16'h9AE8, 1'b1), TGT_ACCEL, 24'h009AE8, 1'b1);
    do_check("9948 CMD new",    mk_io(16'h9948, 1'b1), TGT_ACCEL, 24'h009948, 1'b1);
    do_check("BEE8 MFUNC leg",  mk_io(16'hBEE8, 1'b1), TGT_ACCEL, 24'h00BEE8, 1'b1);
    do_check("BD48 MFUNC new",  mk_io(16'hBD48, 1'b1), TGT_ACCEL, 24'h00BD48, 1'b1);
    do_check("E2E8 PIX_TRANS",  mk_io(16'hE2E8, 1'b1), TGT_ACCEL, 24'h00E2E8, 1'b1);
    do_check("E148 PIX_TRANS",  mk_io(16'hE148, 1'b1), TGT_ACCEL, 24'h00E148, 1'b1);

    // Boundary: 8514 group only valid in [0x80, 0xEF] upper byte.
    // 0x7FE8 should not decode as accel.
    do_check("7FE8 not accel",  mk_io(16'h7FE8, 1'b1), TGT_NONE, 24'h0, 1'b0);
    do_check("F0E8 not accel",  mk_io(16'hF0E8, 1'b1), TGT_NONE, 24'h0, 1'b0);

    // -- Memory: VGA apertures --------------------------------------------------
    do_check("A0000 aper",     mk_mem(24'h0A_0000, 1'b1), TGT_MEM_VGA_APER, 24'h0A_0000, 1'b1);
    do_check("AFFFF aper",     mk_mem(24'h0A_FFFF, 1'b0), TGT_MEM_VGA_APER, 24'h0A_FFFF, 1'b1);
    do_check("B0000 aper",     mk_mem(24'h0B_0000, 1'b1), TGT_MEM_VGA_APER, 24'h0B_0000, 1'b1);
    do_check("B8000 aper",     mk_mem(24'h0B_8000, 1'b1), TGT_MEM_VGA_APER, 24'h0B_8000, 1'b1);

    // -- Memory: BIOS window ---------------------------------------------------
    do_check("C0000 BIOS",     mk_mem(24'h0C_0000, 1'b0), TGT_MEM_BIOS, 24'h00_0000, 1'b1);
    do_check("C7FFF BIOS",     mk_mem(24'h0C_7FFF, 1'b0), TGT_MEM_BIOS, 24'h00_7FFF, 1'b1);
    do_check("C8000 not BIOS", mk_mem(24'h0C_8000, 1'b0), TGT_NONE,     24'h0,        1'b0);

    // -- linear aperture: disabled in this instance ----------------------------
    do_check("400000 linear off", mk_mem(24'h40_0000, 1'b1), TGT_NONE, 24'h0, 1'b0);

    $display("=== tb_io_decode: %0d errors ===", errors);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish(errors == 0 ? 0 : 1);
  end

endmodule
