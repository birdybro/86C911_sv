//==============================================================================
// tb_accel_regs.sv
//
// Self-checking TB for s3_accel_regs. Drives host_req directly. Verifies:
//   1. Each 16-bit register accepts a write at the 8514/A legacy address
//      and is read back correctly at the SAME address.
//   2. The S3-new mirror address aliases the same storage (read after legacy
//      write returns identical bytes; write at new aliases back to legacy).
//   3. The CMD slot (9AE8 / 9948) is special: writes update cmd_q; reads
//      return Subsystem Status with the wired-up int_* inputs.
//   4. MULTIFUNC_CNTL routes wdata[15:12] as sub-index and [11:0] as data.
//      READ_SEL (sub-index 0xF) selects which sub-register is returned on
//      read of the MULTIFUNC port.
//==============================================================================

`include "s3_pkg.sv"

module tb_accel_regs;
  import s3_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  host_req_t req;
  host_rsp_t rsp;

  logic int_vsy = 0, int_ge_bsy = 0, int_fifo_ovr = 0, int_fifo_emp = 1;

  logic [15:0] cur_x_q, cur_y_q, cur_x2_q, cur_y2_q;
  logic [15:0] desty_axstp_q, destx_distp_q;
  logic [15:0] err_term_q, maj_axis_pcnt_q;
  logic [15:0] cmd_q, short_stroke_q;
  logic [15:0] bkgd_color_q, frgd_color_q;
  logic [15:0] wrt_mask_q, rd_mask_q, color_cmp_q;
  logic [15:0] bkgd_mix_q, frgd_mix_q;
  logic [11:0] multifunc_q [0:15];

  s3_accel_regs dut (
    .clk(clk), .rst_n(rst_n),
    .host_req(req), .target(TGT_ACCEL), .host_rsp(rsp),
    .int_vsy(int_vsy), .int_ge_bsy(int_ge_bsy),
    .int_fifo_ovr(int_fifo_ovr), .int_fifo_emp(int_fifo_emp),
    .cur_x_q(cur_x_q), .cur_y_q(cur_y_q),
    .cur_x2_q(cur_x2_q), .cur_y2_q(cur_y2_q),
    .desty_axstp_q(desty_axstp_q), .destx_distp_q(destx_distp_q),
    .err_term_q(err_term_q), .maj_axis_pcnt_q(maj_axis_pcnt_q),
    .cmd_q(cmd_q), .short_stroke_q(short_stroke_q),
    .bkgd_color_q(bkgd_color_q), .frgd_color_q(frgd_color_q),
    .wrt_mask_q(wrt_mask_q), .rd_mask_q(rd_mask_q), .color_cmp_q(color_cmp_q),
    .bkgd_mix_q(bkgd_mix_q), .frgd_mix_q(frgd_mix_q),
    .multifunc_q(multifunc_q)
  );

  // ---- helpers -------------------------------------------------------------
  int errors = 0;

  // 16-bit write at even port (be=11).
  task automatic bus_wr_w(input logic [15:0] port, input logic [15:0] data);
    @(negedge clk);
    req         = '0;
    req.req     = 1'b1;
    req.we      = 1'b1;
    req.is_mem  = 1'b0;
    req.addr    = {8'h00, port};
    req.be      = 2'b11;
    req.wdata   = data;
    @(negedge clk);
    req = '0;
  endtask

  // 8-bit write — even or odd port. Port[0] selects byte slot.
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

  // 16-bit read at even port.
  task automatic bus_rd_w(input logic [15:0] port, output logic [15:0] data);
    @(negedge clk);
    req         = '0;
    req.req     = 1'b1;
    req.we      = 1'b0;
    req.is_mem  = 1'b0;
    req.addr    = {8'h00, port};
    req.be      = 2'b11;
    #1;
    if (!rsp.ready) begin
      $display("FAIL  no ready on rd port=%h", port);
      errors++;
    end
    data = rsp.rdata;
    @(negedge clk);
    req = '0;
  endtask

  task automatic chk16(input string label, input logic [15:0] got, input logic [15:0] exp);
    if (got !== exp) begin
      $display("FAIL  %0s  got=%h exp=%h", label, got, exp);
      errors++;
    end else begin
      $display("ok    %0s  =%h", label, got);
    end
  endtask

  // Helper: write-then-read at legacy AND verify alias via new mirror.
  task automatic verify_alias(input string name,
                              input logic [15:0] legacy_port,
                              input logic [15:0] new_port,
                              input logic [15:0] pattern);
    logic [15:0] r1, r2, r3;
    bus_wr_w(legacy_port, pattern);
    bus_rd_w(legacy_port, r1);  chk16({name, " leg->leg"}, r1, pattern);
    bus_rd_w(new_port,    r2);  chk16({name, " leg->new"}, r2, pattern);
    bus_wr_w(new_port, ~pattern);
    bus_rd_w(legacy_port, r3);  chk16({name, " new->leg"}, r3, ~pattern);
  endtask

  // ---- stimulus ------------------------------------------------------------
  initial begin
    $display("=== tb_accel_regs ===");
    req = '0;
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(negedge clk);

    // ----- Walk every register through legacy <-> new aliasing --------------
    verify_alias("CUR_Y",        16'h82E8, 16'h8148, 16'h1234);
    verify_alias("CUR_Y2",       16'h82EA, 16'h814A, 16'hCAFE);
    verify_alias("CUR_X",        16'h86E8, 16'h8548, 16'h5678);
    verify_alias("CUR_X2",       16'h86EA, 16'h854A, 16'h9ABC);
    verify_alias("DESTY_AXSTP",  16'h8AE8, 16'h8948, 16'hDEAD);
    verify_alias("DESTX_DISTP",  16'h8EE8, 16'h8D48, 16'hBEEF);
    verify_alias("ERR_TERM",     16'h92E8, 16'h9148, 16'hF00D);
    verify_alias("MAJ_AXIS",     16'h96E8, 16'h9548, 16'h0EE7);
    // CMD/status slot is special — check writes go through (we'll read
    // status separately below) by inspecting the exported cmd_q.
    bus_wr_w(16'h9AE8, 16'h53F1);
    chk16("CMD write via legacy stored",   cmd_q, 16'h53F1);
    bus_wr_w(16'h9948, 16'h53B1);
    chk16("CMD write via new mirror",      cmd_q, 16'h53B1);
    verify_alias("SHORT_STROKE", 16'h9EE8, 16'h9D48, 16'h0102);
    verify_alias("BKGD_COLOR",   16'hA2E8, 16'hA148, 16'h0040);
    verify_alias("FRGD_COLOR",   16'hA6E8, 16'hA548, 16'h00FF);
    verify_alias("WRT_MASK",     16'hAAE8, 16'hA948, 16'hFFFF);
    verify_alias("RD_MASK",      16'hAEE8, 16'hAD48, 16'hFF00);
    verify_alias("COLOR_CMP",    16'hB2E8, 16'hB148, 16'h0055);
    verify_alias("BKGD_MIX",     16'hB6E8, 16'hB548, 16'h0003);
    verify_alias("FRGD_MIX",     16'hBAE8, 16'hB948, 16'h0707);

    // ----- Subsystem status overlay -----------------------------------------
    // After CMD writes above, cmd_q holds non-zero. But reading 9AE8 / 9948
    // should NOT return cmd_q — it should return the status byte (low byte
    // only; upper byte is 0).
    int_vsy      = 1'b1;
    int_fifo_emp = 1'b1;
    @(negedge clk);
    begin
      logic [15:0] r;
      bus_rd_w(16'h9AE8, r);
      chk16("status w/ int_vsy + fifo_emp", r, 16'h0009);  // 0b1001 = bits 0,3
      bus_rd_w(16'h9948, r);
      chk16("status via new mirror",        r, 16'h0009);
    end
    int_vsy = 1'b0;
    int_ge_bsy = 1'b1;
    @(negedge clk);
    begin
      logic [15:0] r;
      bus_rd_w(16'h9AE8, r);
      chk16("status w/ ge_bsy + fifo_emp",  r, 16'h000A);  // 0b1010
    end
    int_ge_bsy = 1'b0;

    // ----- MULTIFUNC_CNTL ---------------------------------------------------
    // Write {idx=0x1, data=0x0AA} -> MULTIFUNC[1] = 0x0AA (SCISSORS_T).
    bus_wr_w(16'hBEE8, 16'h10AA);
    chk16("MF[1] = SCISSORS_T", {4'h0, multifunc_q[1]}, 16'h00AA);
    // Index 0x2 = SCISSORS_L = 0x55
    bus_wr_w(16'hBD48, 16'h2055);
    chk16("MF[2] = SCISSORS_L", {4'h0, multifunc_q[2]}, 16'h0055);
    // Set READ_SEL (idx 0xF) to point at index 0x1, then read BEE8 ->
    // should return multifunc[1] = 0x0AA.
    bus_wr_w(16'hBEE8, 16'hF001);          // READ_SEL <- 0x1
    chk16("MF[F] = READ_SEL=1", {4'h0, multifunc_q[8'hF]}, 16'h0001);
    begin
      logic [15:0] r;
      bus_rd_w(16'hBEE8, r);
      chk16("MF read via READ_SEL", r, 16'h00AA);
    end
    // Change READ_SEL to 0x2 -> next read returns 0x055.
    bus_wr_w(16'hBD48, 16'hF002);
    begin
      logic [15:0] r;
      bus_rd_w(16'hBD48, r);
      chk16("MF read via mirror+READ_SEL=2", r, 16'h0055);
    end

    $display("=== tb_accel_regs: %0d errors ===", errors);
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
