//==============================================================================
// tb_isa16_if.sv
//
// Self-checking testbench for s3_isa16_if. Drives synthetic ISA-bus cycles
// and verifies the internal host_req_t / host_rsp_t handshake, byte enables,
// wait-state behavior, and bus timeout.
//
// Built with verilator --binary --timing tb_isa16_if.sv ...
//==============================================================================

`include "s3_pkg.sv"

module tb_isa16_if;
  import s3_pkg::*;

  // -- clock/reset -----------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;   // 100 MHz

  // -- DUT signals -----------------------------------------------------------
  logic         isa_ior_n = 1, isa_iow_n = 1, isa_memr_n = 1, isa_memw_n = 1;
  logic         isa_aen = 0;
  logic         isa_bhe_n = 1;
  logic [19:0]  isa_sa  = '0;
  logic [23:17] isa_la  = '0;
  logic [15:0]  isa_sd_in = '0;
  logic [15:0]  isa_sd_drv;
  logic         isa_sd_oe;
  logic         isa_iochrdy;
  logic         isa_io16_n, isa_mem16_n;

  host_req_t    host_req;
  host_rsp_t    host_rsp;
  logic         err_timeout;

  s3_isa16_if #(.MIN_WAIT(1), .MAX_WAIT(16)) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .isa_ior_n  (isa_ior_n),
    .isa_iow_n  (isa_iow_n),
    .isa_memr_n (isa_memr_n),
    .isa_memw_n (isa_memw_n),
    .isa_aen    (isa_aen),
    .isa_bhe_n  (isa_bhe_n),
    .isa_sa     (isa_sa),
    .isa_la     (isa_la),
    .isa_sd_in  (isa_sd_in),
    .isa_sd_drv (isa_sd_drv),
    .isa_sd_oe  (isa_sd_oe),
    .isa_iochrdy(isa_iochrdy),
    .isa_io16_n (isa_io16_n),
    .isa_mem16_n(isa_mem16_n),
    .host_req   (host_req),
    .host_rsp   (host_rsp),
    .err_timeout(err_timeout)
  );

  // -- fake slave: configurable wait-then-reply -----------------------------
  int  rsp_delay = 0;          // cycles to hold ready low after req
  logic [15:0] rsp_data = 16'h0;
  logic        rsp_drop = 0;   // if 1, never respond (test timeout)
  int          delay_ctr = 0;

  // Latch err_timeout (it is a 1-cycle pulse by design).
  logic err_seen = 0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)               err_seen <= 1'b0;
    else if (err_timeout)     err_seen <= 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      delay_ctr <= 0;
      host_rsp  <= '0;
    end else begin
      host_rsp <= '0;
      if (host_req.req && !rsp_drop) begin
        if (delay_ctr >= rsp_delay) begin
          host_rsp.ready <= 1'b1;
          host_rsp.rdata <= rsp_data;
          delay_ctr      <= 0;
        end else begin
          delay_ctr <= delay_ctr + 1;
        end
      end else begin
        delay_ctr <= 0;
      end
    end
  end

  // -- helpers ---------------------------------------------------------------
  int errors = 0;

  task automatic step(int n = 1);
    repeat (n) @(posedge clk);
  endtask

  task automatic isa_iow_word(input logic [15:0] port, input logic [15:0] data);
    isa_sa     = {4'h0, port};
    isa_bhe_n  = 1'b0;       // 16-bit cycle
    isa_sd_in  = data;
    isa_iow_n  = 1'b0;
    // Wait for IOCHRDY high (transaction accepted) + return to idle.
    // After deassert, slave will see strobe go inactive and finish.
    do step(); while (!isa_iochrdy);
    isa_iow_n  = 1'b1;
    isa_bhe_n  = 1'b1;
    step();
  endtask

  task automatic isa_ior_word(input logic [15:0] port, output logic [15:0] data);
    isa_sa     = {4'h0, port};
    isa_bhe_n  = 1'b0;
    isa_ior_n  = 1'b0;
    do step(); while (!isa_iochrdy);
    // Read returns once we drive SD; capture it.
    @(posedge clk);
    data = isa_sd_drv;
    isa_ior_n  = 1'b1;
    isa_bhe_n  = 1'b1;
    step();
  endtask

  task automatic isa_memw_byte(input logic [23:0] addr, input logic [7:0] data, input logic high_byte);
    isa_sa    = addr[19:0];
    isa_la    = addr[23:17];
    isa_bhe_n = high_byte ? 1'b0 : 1'b1;   // for high byte we need BHE=0,SA0=1
    isa_sd_in = high_byte ? {data, 8'h0} : {8'h0, data};
    isa_memw_n = 1'b0;
    do step(); while (!isa_iochrdy);
    isa_memw_n = 1'b1;
    isa_bhe_n  = 1'b1;
    step();
  endtask

  task automatic check_req(
      input string label,
      input logic [23:0] exp_addr,
      input logic        exp_we,
      input logic        exp_is_mem,
      input logic [1:0]  exp_be,
      input logic [15:0] exp_wdata
  );
    if (host_req.addr   !== exp_addr   ||
        host_req.we     !== exp_we     ||
        host_req.is_mem !== exp_is_mem ||
        host_req.be     !== exp_be     ||
        (exp_we && host_req.wdata !== exp_wdata)) begin
      $display("FAIL  %0s  got addr=%h we=%0b mem=%0b be=%b wdata=%h",
               label, host_req.addr, host_req.we, host_req.is_mem,
               host_req.be, host_req.wdata);
      $display("                exp addr=%h we=%0b mem=%0b be=%b wdata=%h",
               exp_addr, exp_we, exp_is_mem, exp_be, exp_wdata);
      errors++;
    end else begin
      $display("ok    %0s  addr=%h", label, host_req.addr);
    end
  endtask

  // -- stimulus --------------------------------------------------------------
  initial begin
    $display("=== tb_isa16_if ===");
    rsp_delay = 0;
    rsp_drop  = 0;
    rsp_data  = 16'h0;

    // Reset
    rst_n = 0;
    step(3);
    rst_n = 1;
    step(2);

    // ---- 1. Simple I/O word write ------------------------------------------
    fork
      isa_iow_word(16'h03C4, 16'hBEEF);
    join_none
    // Wait for req to assert
    @(posedge host_req.req);
    check_req("iow_word 3C4", 24'h0003C4, 1'b1, 1'b0, 2'b11, 16'hBEEF);
    wait fork;
    step(2);

    // ---- 2. I/O word read ---------------------------------------------------
    begin
      logic [15:0] rd;
      rsp_data = 16'hCAFE;
      fork
        isa_ior_word(16'h03CC, rd);
      join_none
      @(posedge host_req.req);
      check_req("ior_word 3CC", 24'h0003CC, 1'b0, 1'b0, 2'b11, 16'h0);
      wait fork;
      if (rd !== 16'hCAFE) begin
        $display("FAIL  read data mismatch: got %h exp CAFE", rd);
        errors++;
      end else begin
        $display("ok    read returned CAFE");
      end
      step(2);
    end

    // ---- 3. Wait-state insertion -------------------------------------------
    // Use an even port (SA[0]=0) so the full word access yields be=2'b11.
    rsp_delay = 5;
    fork
      isa_iow_word(16'h03CE, 16'h1234);
    join_none
    @(posedge host_req.req);
    check_req("iow w/ waits 3CE", 24'h0003CE, 1'b1, 1'b0, 2'b11, 16'h1234);
    wait fork;
    rsp_delay = 0;
    step(2);

    // ---- 4. Memory byte write: high byte (BHE=0, SA0=1) --------------------
    fork
      isa_memw_byte(24'h0A_0001, 8'hA5, 1'b1);
    join_none
    @(posedge host_req.req);
    check_req("memw high byte A0001", 24'h0A_0001, 1'b1, 1'b1, 2'b10, 16'hA500);
    wait fork;
    step(2);

    // ---- 5. Memory byte write: low byte (BHE=1, SA0=0) ---------------------
    fork
      isa_memw_byte(24'h0A_0000, 8'h5A, 1'b0);
    join_none
    @(posedge host_req.req);
    check_req("memw low byte A0000", 24'h0A_0000, 1'b1, 1'b1, 2'b01, 16'h005A);
    wait fork;
    step(2);

    // ---- 6. AEN gating: cycle with AEN=1 should be ignored -----------------
    isa_aen = 1'b1;
    isa_sa  = 20'h03C4;
    isa_bhe_n = 1'b0;
    isa_sd_in = 16'hDEAD;
    isa_iow_n = 1'b0;
    step(4);
    if (host_req.req) begin
      $display("FAIL  AEN=1 cycle was not ignored");
      errors++;
    end else begin
      $display("ok    AEN=1 cycle ignored");
    end
    isa_iow_n = 1'b1;
    isa_aen   = 1'b0;
    isa_bhe_n = 1'b1;
    step(2);

    // ---- 7. Bus timeout -----------------------------------------------------
    err_seen   = 0;            // reset latch for this case
    rsp_drop   = 1;
    isa_sa     = 20'h03C4;
    isa_bhe_n  = 1'b0;
    isa_sd_in  = 16'h0001;
    isa_iow_n  = 1'b0;
    // Wait MAX_WAIT+a few cycles for timeout
    repeat (24) step();
    if (!err_seen) begin
      $display("FAIL  timeout not asserted after MAX_WAIT");
      errors++;
    end else begin
      $display("ok    timeout asserted");
    end
    isa_iow_n  = 1'b1;
    rsp_drop   = 0;
    isa_bhe_n  = 1'b1;
    step(4);

    $display("=== tb_isa16_if: %0d errors ===", errors);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish(errors == 0 ? 0 : 1);
  end

  // -- safety timeout --------------------------------------------------------
  initial begin
    #50000;
    $display("FAIL  global watchdog tripped");
    $finish(1);
  end

endmodule
