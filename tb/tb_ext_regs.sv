//==============================================================================
// tb_ext_regs.sv
//
// Self-checking TB for the S3 extended register space in s3_crtc.sv.
// Drives host_req directly. Covers:
//   1. CR30 returns 0xFF while locked, returns CHIP_ID_BYTE (0x81 default
//      for 86C911) once CR38 unlocked.
//   2. CR38 unlock predicate is a *masked* compare ((CR38 & 0xCC) == 0x48):
//      writing 0x4C also unlocks; writing 0xC8 does NOT.
//   3. CR40+ writes require CR39 unlock ((CR39 & 0xE0) == 0xA0). 0xA5
//      satisfies; 0x80 does not.
//   4. CR36 writes require CR39 == 0xA5 exactly. 0xA0 is NOT enough.
//   5. PRE_86C928=1 silently drops CR50+ writes even when CR39 unlocked.
//   6. CR2E always returns CHIP_ID_EXT (0x81), regardless of lock.
//==============================================================================

`include "s3_pkg.sv"

module tb_ext_regs;
  import s3_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  host_req_t req;
  host_rsp_t rsp;

  logic [7:0] cr00,cr01,cr04,cr05,cr06,cr07,cr10,cr11,cr12,cr13,cr17,cr18;
  logic [15:0] cr0c0d;
  logic [7:0]  cr31_w, cr38_w, cr39_w, cr40_w, cr53_w;
  logic        ext_unlock_2x, ext_unlock_40, ext_unlock_36;
  logic [7:0]  crtc_arr_w [0:31];

  s3_crtc #(
    .CHIP_ID_BYTE (8'h81),
    .CHIP_ID_EXT  (8'h81),
    .CHIP_REV_BYTE(8'h00),
    .PRE_86C928   (1'b1)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(TGT_VGA_CRTC), .host_rsp(rsp),
    .cr00_htotal(cr00), .cr01_hde_end(cr01),
    .cr04_hsync_st(cr04), .cr05_hsync_end(cr05),
    .cr06_vtotal(cr06), .cr07_overflow(cr07),
    .cr10_vsync_st(cr10), .cr11_vsync_end(cr11),
    .cr12_vde_end(cr12), .cr0c0d_start_addr(cr0c0d),
    .cr13_offset(cr13), .cr17_mode_ctrl(cr17),
    .cr18_line_compare(cr18),
    .cr31_mem_cfg(cr31_w), .cr38_lock1(cr38_w),
    .cr39_lock2(cr39_w), .cr40_sys_cfg(cr40_w),
    .cr53_ext_ctrl(cr53_w),
    .ext_unlocked_2x_3x (ext_unlock_2x),
    .ext_unlocked_40plus(ext_unlock_40),
    .ext_unlocked_cr36  (ext_unlock_36),
    .crtc_array(crtc_arr_w)
  );

  // ---- helpers -------------------------------------------------------------
  int errors = 0;

  task automatic step(int n = 1); repeat (n) @(posedge clk); endtask

  task automatic bus_wr_b(input logic [15:0] port, input logic [7:0] data);
    @(negedge clk);
    req         = '0;
    req.req     = 1'b1;
    req.we      = 1'b1;
    req.is_mem  = 1'b0;
    req.addr    = {8'h00, port};
    req.be      = port[0] ? 2'b10 : 2'b01;
    req.wdata   = port[0] ? {data, 8'h00} : {8'h00, data};
    @(negedge clk);
    req = '0;
  endtask

  task automatic bus_rd_b(input logic [15:0] port, output logic [7:0] data);
    @(negedge clk);
    req         = '0;
    req.req     = 1'b1;
    req.we      = 1'b0;
    req.is_mem  = 1'b0;
    req.addr    = {8'h00, port};
    req.be      = port[0] ? 2'b10 : 2'b01;
    #1;
    if (!rsp.ready) begin
      $display("FAIL  no ready on rd port=%h", port);
      errors++;
    end
    data = port[0] ? rsp.rdata[15:8] : rsp.rdata[7:0];
    @(negedge clk);
    req = '0;
  endtask

  task automatic crtc_w(input logic [7:0] idx, input logic [7:0] dat);
    bus_wr_b(16'h03D4, idx);
    bus_wr_b(16'h03D5, dat);
  endtask

  task automatic crtc_r(input logic [7:0] idx, output logic [7:0] dat);
    bus_wr_b(16'h03D4, idx);
    bus_rd_b(16'h03D5, dat);
  endtask

  task automatic chk(input string label, input logic [7:0] got, input logic [7:0] exp);
    if (got !== exp) begin
      $display("FAIL  %0s  got=%h exp=%h", label, got, exp);
      errors++;
    end else begin
      $display("ok    %0s  =%h", label, got);
    end
  endtask

  // ---- stimulus ------------------------------------------------------------
  initial begin
    $display("=== tb_ext_regs ===");
    rst_n = 0; req = '0;
    step(3);
    rst_n = 1;
    step(2);

    // ----- (1) CR30 returns 0xFF when locked --------------------------------
    begin
      logic [7:0] r;
      crtc_r(8'h30, r);
      chk("CR30 locked", r, 8'hFF);
    end

    // ----- (2) Unlock with exact key 0x48 -> CR30 returns chip ID -----------
    crtc_w(8'h38, 8'h48);
    begin
      logic [7:0] r;
      crtc_r(8'h30, r);
      chk("CR30 unlocked w/ 0x48", r, 8'h81);
    end

    // Try a mask-equivalent key 0x68 ((0x68 & 0xCC) == 0x48) -> still unlocks.
    // (0x68 has bit 6=1, bit 3=1, bit 7=0, bit 2=0; bits 5/4/1/0 are dont-cares.)
    crtc_w(8'h38, 8'h68);
    begin
      logic [7:0] r;
      crtc_r(8'h30, r);
      chk("CR30 unlocked w/ 0x68", r, 8'h81);
    end

    // Try a key that should NOT unlock: 0xC8 ((0xC8 & 0xCC) == 0xC8 != 0x48)
    crtc_w(8'h38, 8'hC8);
    begin
      logic [7:0] r;
      crtc_r(8'h30, r);
      chk("CR30 locked again w/ 0xC8", r, 8'hFF);
    end

    // Re-unlock for the rest of the test
    crtc_w(8'h38, 8'h48);

    // ----- (6) CR2E always returns id_ext, no unlock needed -----------------
    crtc_w(8'h38, 8'h00);   // lock again
    begin
      logic [7:0] r;
      crtc_r(8'h2E, r);
      chk("CR2E always 0x81", r, 8'h81);
    end
    crtc_w(8'h38, 8'h48);

    // ----- (3) CR40+ requires CR39 unlock ----------------------------------
    // First: write to CR40 with CR39 still at reset (0x00) -> should drop.
    crtc_w(8'h40, 8'hAA);
    begin
      logic [7:0] r;
      crtc_r(8'h40, r);
      chk("CR40 dropped while CR39 locked", r, 8'h00);
    end

    // Now unlock CR39 with 0xA0 (passes (CR39 & 0xE0) == 0xA0).
    crtc_w(8'h39, 8'hA0);
    crtc_w(8'h40, 8'hAA);
    begin
      logic [7:0] r;
      crtc_r(8'h40, r);
      chk("CR40 writable w/ CR39=0xA0", r, 8'hAA);
    end

    // CR39 with 0x80 (high bits 100) should NOT unlock CR40+.
    crtc_w(8'h39, 8'h80);
    crtc_w(8'h40, 8'h55);
    begin
      logic [7:0] r;
      crtc_r(8'h40, r);
      chk("CR40 still 0xAA (CR39=0x80 didn't unlock)", r, 8'hAA);
    end

    // ----- (4) CR36 requires CR39 == 0xA5 exactly --------------------------
    // With CR39 = 0xA0 (which DID unlock CR40+), CR36 should still be locked.
    crtc_w(8'h39, 8'hA0);
    crtc_w(8'h36, 8'hBB);
    begin
      logic [7:0] r;
      crtc_r(8'h36, r);
      chk("CR36 dropped w/ CR39=0xA0", r, 8'h00);
    end

    // Now CR39 = 0xA5 exactly -> CR36 should unlock.
    crtc_w(8'h39, 8'hA5);
    crtc_w(8'h36, 8'hBB);
    begin
      logic [7:0] r;
      crtc_r(8'h36, r);
      chk("CR36 writable w/ CR39=0xA5", r, 8'hBB);
    end

    // ----- (5) PRE_86C928: CR50+ writes silently drop ----------------------
    // CR39 still 0xA5 (most-unlocked state).
    crtc_w(8'h53, 8'h77);
    begin
      logic [7:0] r;
      crtc_r(8'h53, r);
      chk("CR53 dropped on 86C911", r, 8'h00);
    end

    // CR40 (below the 0x50 line) should still work though.
    crtc_w(8'h40, 8'h11);
    begin
      logic [7:0] r;
      crtc_r(8'h40, r);
      chk("CR40 still writable (below CR50 floor)", r, 8'h11);
    end

    // ----- diagnostic exports -----------------------------------------------
    chk("ext_unlock_2x export", {7'h0, ext_unlock_2x}, 8'h01);
    chk("ext_unlock_40 export", {7'h0, ext_unlock_40}, 8'h01);
    chk("ext_unlock_36 export", {7'h0, ext_unlock_36}, 8'h01);
    chk("cr38 export",          cr38_w, 8'h48);
    chk("cr39 export",          cr39_w, 8'hA5);
    chk("cr40 export",          cr40_w, 8'h11);
    chk("cr53 export (locked)", cr53_w, 8'h00);

    $display("=== tb_ext_regs: %0d errors ===", errors);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish(errors == 0 ? 0 : 1);
  end

  initial begin
    #500000;
    $display("FAIL  global watchdog");
    $finish(1);
  end

endmodule
