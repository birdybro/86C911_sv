//==============================================================================
// s3_accel_regs.sv
//
// 86C911 accelerator register file. The chip exposes the same register set
// at TWO addressing schemes:
//   - 8514/A legacy: 0xXXE8 / 0xXXE9 / 0xXXEA / 0xXXEB
//   - S3 mirror   : 0xXX48 / 0xXX49 / 0xXX4A / 0xXX4B
//
// Trick: a register's logical position depends only on the upper 6 bits of
// the port — specifically `{port[15:12], port[11:10]}` — plus the 2-bit
// byte-within-register `port[1:0]`. Both legacy and S3-mirror forms produce
// the SAME index, because:
//   - port[11:8] is {2,6,A,E} for legacy and {1,5,9,D} for new — both have
//     port[11:10] taking values 00/01/10/11 in the same order.
//   - port[1:0] is 00..11 for both forms (E8/E9/EA/EB ↔ 48/49/4A/4B).
//
// Storage:
//   - `byte_ram` : 256-byte flat store. Most registers live here.
//   - `multifunc`: 16 × 12-bit sub-registers driven through MULTIFUNC_CNTL.
//
// Special semantics:
//   - Read at idx 0x98 / 0x99 (port 9AE8/9AE9 or 9948/9949) returns the
//     Subsystem Status byte, NOT the CMD register. (Writes still update the
//     CMD bytes in `byte_ram`.) Source: 86Box `vid_s3.c` INT_* bit map.
//   - MULTIFUNC_CNTL writes at idx 0xBC/0xBD parse wdata as {idx[15:12],
//     data[11:0]} and update `multifunc[idx]`. Reads return
//     multifunc[multifunc[0xF] (READ_SEL)] left-padded with zeros.
//
// Phase 5 scope:
//   - Register file with read/write at both addressing schemes.
//   - Status byte read overlay.
//   - MULTIFUNC routing.
//   - No engine — Phase 6 blitter consumes the exported register values.
//   - PIX_TRANS (0xE0 region), pattern (0xE4/E8/EC), ROPMIX (0xD0) are
//     allocated in `byte_ram` but no special semantics yet.
//==============================================================================

`include "s3_pkg.sv"

module s3_accel_regs
  import s3_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  host_req_t   host_req,
  input  bus_target_e target,
  output host_rsp_t   host_rsp,

  // Status-bit inputs (from timing_gen / FIFO / engine in later phases)
  input  logic        int_vsy,
  input  logic        int_ge_bsy,
  input  logic        int_fifo_ovr,
  input  logic        int_fifo_emp,

  // Exports — every 16-bit register the blitter will consume in Phase 6
  output logic [15:0] cur_x_q,
  output logic [15:0] cur_y_q,
  output logic [15:0] cur_x2_q,
  output logic [15:0] cur_y2_q,
  output logic [15:0] desty_axstp_q,
  output logic [15:0] destx_distp_q,
  output logic [15:0] err_term_q,
  output logic [15:0] maj_axis_pcnt_q,
  output logic [15:0] cmd_q,
  output logic [15:0] short_stroke_q,
  output logic [15:0] bkgd_color_q,
  output logic [15:0] frgd_color_q,
  output logic [15:0] wrt_mask_q,
  output logic [15:0] rd_mask_q,
  output logic [15:0] color_cmp_q,
  output logic [15:0] bkgd_mix_q,
  output logic [15:0] frgd_mix_q,
  output logic [11:0] multifunc_q [0:15]
);

  // ---------------------------------------------------------------------------
  // Index computation
  // ---------------------------------------------------------------------------
  // 8-bit register-byte index. Both legacy and S3-new forms map to the same
  // 8-bit value because port[11:10] and port[1:0] agree across the forms.
  wire [7:0] base_idx = {host_req.addr[15:12], host_req.addr[11:10], host_req.addr[1:0]};

  // Helpers for byte/word lane handling on the host bus.
  wire is_my_cycle  = (target == TGT_ACCEL) && host_req.req;
  wire wr_low_lane  = is_my_cycle && host_req.we &&
                      ((host_req.be[0] && !host_req.addr[0]) ||
                       (host_req.be[1] &&  host_req.addr[0]));
  wire wr_high_lane = is_my_cycle && host_req.we &&
                      (host_req.be[1] && !host_req.addr[0]);
  wire rd_low_lane  = is_my_cycle && !host_req.we &&
                      ((host_req.be[0] && !host_req.addr[0]) ||
                       (host_req.be[1] &&  host_req.addr[0]));
  wire rd_high_lane = is_my_cycle && !host_req.we &&
                      (host_req.be[1] && !host_req.addr[0]);

  // The byte that the host wants placed at base_idx (low lane), and at
  // base_idx+1 (high lane) for a word access.
  wire [7:0] wr_low_byte  = host_req.addr[0] ? host_req.wdata[15:8]
                                              : host_req.wdata[7:0];
  wire [7:0] wr_high_byte = host_req.wdata[15:8];

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------
  logic [7:0]  byte_ram  [0:255];
  logic [11:0] multifunc [0:15];

  // ---------------------------------------------------------------------------
  // Write path
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 256; i++) byte_ram[i]  <= 8'h00;
      for (int j = 0; j < 16;  j++) multifunc[j] <= 12'h000;
    end else begin
      // MULTIFUNC_CNTL is special: word write at idx 0xBC populates
      // multifunc[wdata[15:12]] = wdata[11:0]. We detect the word write by
      // requiring both lanes active or the high-lane half of a byte write.
      // (The low byte alone would only update bits [7:0]; software always
      // does a word write here in practice, but we accept partial writes
      // and reconstruct the 16-bit value from whatever the host provided.)
      if (is_my_cycle && host_req.we && base_idx == 8'hBC) begin
        // Reconstruct the intended 16-bit value from low + high lanes; use
        // the registered byte for any lane the host did NOT update so a
        // partial write doesn't clobber the other half.
        logic [15:0] mfw;
        mfw[7:0]  = wr_low_lane  ? wr_low_byte  : byte_ram[8'hBC];
        mfw[15:8] = wr_high_lane ? wr_high_byte : byte_ram[8'hBD];
        multifunc[mfw[15:12]] <= mfw[11:0];
        // Also keep the byte_ram copies updated so a plain readback at BC/BD
        // returns the last value written. (Real hardware returns the indexed
        // sub-register on read; we provide that via the read overlay below.)
        if (wr_low_lane)  byte_ram[8'hBC] <= wr_low_byte;
        if (wr_high_lane) byte_ram[8'hBD] <= wr_high_byte;
      end else begin
        if (wr_low_lane)  byte_ram[base_idx]        <= wr_low_byte;
        if (wr_high_lane) byte_ram[base_idx + 8'h1] <= wr_high_byte;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Status byte (overlay on idx 0x98 read)
  //   bit 0 = INT_VSY, bit 1 = INT_GE_BSY,
  //   bit 2 = INT_FIFO_OVR, bit 3 = INT_FIFO_EMP
  // Bits [7:4] are 0 on 86C911 (deeper FIFO-slot status fields appear on
  // later S3 chips — kept zero here per the 86Box INT_MASK = 0xF).
  // ---------------------------------------------------------------------------
  wire [7:0] status_byte = {4'h0, int_fifo_emp, int_fifo_ovr, int_ge_bsy, int_vsy};

  // ---------------------------------------------------------------------------
  // Read path — combinational, with overlays for status + MULTIFUNC.
  // ---------------------------------------------------------------------------
  logic [7:0] rd_low_byte_val, rd_high_byte_val;
  logic [11:0] mf_readsel_value;

  // READ_SEL is multifunc[0xF] per `vid_s3.c` MULTIFUNC convention.
  wire [3:0] mf_read_sel_idx = multifunc[8'hF][3:0];
  assign     mf_readsel_value = multifunc[mf_read_sel_idx];

  always_comb begin
    // Default: byte from RAM.
    rd_low_byte_val  = byte_ram[base_idx];
    rd_high_byte_val = byte_ram[base_idx + 8'h1];

    // Status read overlay on 9AE8 / 9948 (CMD slot).
    if (base_idx == 8'h98) rd_low_byte_val  = status_byte;
    if (base_idx == 8'h99) rd_low_byte_val  = status_byte;  // odd-addr byte-read path
    if (base_idx == 8'h98 && rd_high_lane)
                            rd_high_byte_val = 8'h00;        // hi byte of word: reserved 0

    // MULTIFUNC read at idx 0xBC/0xBD returns multifunc[READ_SEL].
    if (base_idx == 8'hBC) begin
      rd_low_byte_val  = mf_readsel_value[7:0];
      rd_high_byte_val = {4'h0, mf_readsel_value[11:8]};
    end
    if (base_idx == 8'hBD) begin
      rd_low_byte_val  = {4'h0, mf_readsel_value[11:8]};
    end
  end

  always_comb begin
    host_rsp = '0;
    if (is_my_cycle) begin
      host_rsp.ready = 1'b1;
      if (!host_req.we) begin
        host_rsp.rdata[7:0]  = rd_low_lane  ? rd_low_byte_val  : 8'h00;
        host_rsp.rdata[15:8] = rd_high_lane ? rd_high_byte_val : 8'h00;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Exports — assemble 16-bit views over byte_ram
  // ---------------------------------------------------------------------------
  assign cur_y_q         = {byte_ram[8'h81], byte_ram[8'h80]};
  assign cur_y2_q        = {byte_ram[8'h83], byte_ram[8'h82]};
  assign cur_x_q         = {byte_ram[8'h85], byte_ram[8'h84]};
  assign cur_x2_q        = {byte_ram[8'h87], byte_ram[8'h86]};
  assign desty_axstp_q   = {byte_ram[8'h89], byte_ram[8'h88]};
  assign destx_distp_q   = {byte_ram[8'h8D], byte_ram[8'h8C]};
  assign err_term_q      = {byte_ram[8'h91], byte_ram[8'h90]};
  assign maj_axis_pcnt_q = {byte_ram[8'h95], byte_ram[8'h94]};
  assign cmd_q           = {byte_ram[8'h99], byte_ram[8'h98]};
  assign short_stroke_q  = {byte_ram[8'h9D], byte_ram[8'h9C]};
  assign bkgd_color_q    = {byte_ram[8'hA1], byte_ram[8'hA0]};
  assign frgd_color_q    = {byte_ram[8'hA5], byte_ram[8'hA4]};
  assign wrt_mask_q      = {byte_ram[8'hA9], byte_ram[8'hA8]};
  assign rd_mask_q       = {byte_ram[8'hAD], byte_ram[8'hAC]};
  assign color_cmp_q     = {byte_ram[8'hB1], byte_ram[8'hB0]};
  assign bkgd_mix_q      = {byte_ram[8'hB5], byte_ram[8'hB4]};
  assign frgd_mix_q      = {byte_ram[8'hB9], byte_ram[8'hB8]};

  always_comb begin
    for (int k = 0; k < 16; k++) multifunc_q[k] = multifunc[k];
  end

endmodule
