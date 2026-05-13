//==============================================================================
// s3_vga_mem_mapper.sv
//
// Host-bus slave that owns TGT_MEM_VGA_APER. Translates VGA aperture
// addresses (A0000 / B0000 / B8000 selected by GR06[3:2]) into VRAM plane +
// offset, applies write-mode logic, and forwards read data back to the host.
//
// Phase 3a scope:
//   - GR06[3:2] aperture decode
//   - Chain-4 mode (SR04[3] = 1, GR05[6] used by 256-color mode)
//   - Planar mode WM0 with bit mask (GR08) + 4-byte latch updated on host
//     reads
//   - Read mode 0 (return plane[GR04])
//
// Deferred to later sub-phases:
//   - Set/Reset (GR00/GR01) and the rotate-by-N logic (GR03[2:0])
//   - Logical ops AND/OR/XOR (GR03[4:3])
//   - Write modes 1, 2, 3
//   - Read mode 1 (color compare)
//   - Odd/Even mode (text)
//
// Source: standard VGA register semantics from FreeVGA. Behavior is not
// 86C911-specific (the C911 uses stock VGA front-end logic).
//==============================================================================

`include "s3_pkg.sv"

module s3_vga_mem_mapper
  import s3_pkg::*;
#(
  parameter int unsigned PLANE_AW   = 18   // 256 KB per plane
)(
  input  logic               clk,
  input  logic               rst_n,

  // ---- host bus -----------------------------------------------------------
  input  host_req_t          host_req,
  input  bus_target_e        target,
  output host_rsp_t          host_rsp,

  // ---- sequencer state ----------------------------------------------------
  input  logic [3:0]         sr_plane_mask,
  input  logic               sr_chain4,
  input  logic               sr_oddeven_dis,
  input  logic               sr_extmem,

  // ---- graphics controller state -----------------------------------------
  input  logic [1:0]         gr_read_map_sel,
  input  logic [1:0]         gr_write_mode,
  input  logic               gr_read_mode,
  input  logic [1:0]         gr_mem_map_sel,
  input  logic [7:0]         gr_bit_mask,
  input  logic               gr_256mode,

  // ---- VRAM port (drives s3_vram_ctrl.host port) -------------------------
  output logic               vram_wr_en,
  output logic [3:0]         vram_wr_plane_mask,
  output logic [PLANE_AW-1:0] vram_wr_addr,
  output logic [7:0]         vram_wr_data_p0,
  output logic [7:0]         vram_wr_data_p1,
  output logic [7:0]         vram_wr_data_p2,
  output logic [7:0]         vram_wr_data_p3,

  output logic [PLANE_AW-1:0] vram_rd_addr,
  input  logic [7:0]         vram_rd_data_p0,
  input  logic [7:0]         vram_rd_data_p1,
  input  logic [7:0]         vram_rd_data_p2,
  input  logic [7:0]         vram_rd_data_p3
);

  // ---------------------------------------------------------------------------
  // GR06[3:2] aperture decode
  //   00: A0000-BFFFF (128 KB window)
  //   01: A0000-AFFFF (64  KB)
  //   10: B0000-B7FFF (32  KB, mono text)
  //   11: B8000-BFFFF (32  KB, color text)
  // ---------------------------------------------------------------------------
  logic [23:0] aper_base;
  always_comb begin
    unique case (gr_mem_map_sel)
      2'b00:   aper_base = 24'h0A_0000;     // 128 K window starts at A0000
      2'b01:   aper_base = 24'h0A_0000;
      2'b10:   aper_base = 24'h0B_0000;
      2'b11:   aper_base = 24'h0B_8000;
      default: aper_base = 24'h0A_0000;
    endcase
  end

  // Aperture offset = host_addr - aper_base. Limited to 17 bits (covers the
  // 128 KB largest window). For smaller windows the upper bits are ignored.
  wire [16:0] aper_offset = host_req.addr[16:0] - aper_base[16:0];

  // Selected by chain-4 / planar:
  //   chain-4:  plane = aper_offset[1:0], plane offset = aper_offset[N:2]
  //   planar:   plane = sr_plane_mask    , plane offset = aper_offset
  wire [PLANE_AW-1:0] po_chain4 = aper_offset[PLANE_AW+1:2];
  wire [PLANE_AW-1:0] po_planar = aper_offset[PLANE_AW-1:0];

  // ---------------------------------------------------------------------------
  // 4-byte latch — updated on every host read.
  // ---------------------------------------------------------------------------
  logic [7:0] latch_q [0:3];

  // ---------------------------------------------------------------------------
  // Operation classification — only assert vram_* when we own the cycle and
  // a byte-enable is set.
  // ---------------------------------------------------------------------------
  wire is_my_cycle = (target == TGT_MEM_VGA_APER) && host_req.req;
  wire is_read     = is_my_cycle && !host_req.we && |host_req.be;
  wire is_write    = is_my_cycle &&  host_req.we && |host_req.be;

  // Which byte of the host word is active? For mem we accept both lanes.
  // be[0] writes/reads at addr; be[1] writes/reads at addr+1.
  // We process at most one byte per transaction in this MVP — a word write
  // splits into two consecutive VRAM transactions over two cycles. For the
  // smoke tests we exercise byte access only.

  // Active byte from the host: pick by which byte-enable is set.
  //   be=01           : low byte slot — byte address = addr   (addr must be even)
  //   be=10, addr odd : high byte slot at odd port — byte address = addr
  //   be=10, addr even: high byte slot of word at even base    — byte address = addr+1
  //   be=11           : word — Phase 3a MVP only processes the low byte; the
  //                     high byte is dropped (host should split word writes).
  wire        use_high_byte = host_req.be[1] && !host_req.be[0];
  wire [7:0]  host_byte     = use_high_byte ? host_req.wdata[15:8] : host_req.wdata[7:0];
  wire [16:0] active_offset = (use_high_byte && !host_req.addr[0])
                                ? aper_offset + 17'd1
                                : aper_offset;
  wire [PLANE_AW-1:0] active_po_chain4 = active_offset[PLANE_AW+1:2];
  wire [PLANE_AW-1:0] active_po_planar = active_offset[PLANE_AW-1:0];
  wire [1:0]  active_chain4_plane     = active_offset[1:0];

  // ---------------------------------------------------------------------------
  // Read address — used for the host_rsp path AND for latch updates.
  // ---------------------------------------------------------------------------
  assign vram_rd_addr = sr_chain4 ? active_po_chain4 : active_po_planar;

  // ---------------------------------------------------------------------------
  // Read mode 0: byte from plane[GR04] in planar; chain-4 picks the plane
  // by offset[1:0].
  // ---------------------------------------------------------------------------
  logic [7:0] rm0_byte;
  always_comb begin
    if (sr_chain4) begin
      unique case (active_chain4_plane)
        2'd0:    rm0_byte = vram_rd_data_p0;
        2'd1:    rm0_byte = vram_rd_data_p1;
        2'd2:    rm0_byte = vram_rd_data_p2;
        default: rm0_byte = vram_rd_data_p3;
      endcase
    end else begin
      unique case (gr_read_map_sel)
        2'd0:    rm0_byte = vram_rd_data_p0;
        2'd1:    rm0_byte = vram_rd_data_p1;
        2'd2:    rm0_byte = vram_rd_data_p2;
        default: rm0_byte = vram_rd_data_p3;
      endcase
    end
  end

  // RM1 (color compare) — stubbed; for now return RM0 byte.
  wire [7:0] read_byte = rm0_byte;

  // ---------------------------------------------------------------------------
  // Latch update — on every successful host read.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      latch_q[0] <= 8'h00;
      latch_q[1] <= 8'h00;
      latch_q[2] <= 8'h00;
      latch_q[3] <= 8'h00;
    end else if (is_read) begin
      latch_q[0] <= vram_rd_data_p0;
      latch_q[1] <= vram_rd_data_p1;
      latch_q[2] <= vram_rd_data_p2;
      latch_q[3] <= vram_rd_data_p3;
    end
  end

  // ---------------------------------------------------------------------------
  // Write data path — Phase 3a does write mode 0 + bit_mask:
  //   out[p] = (host_byte & bit_mask) | (latch[p] & ~bit_mask)
  // For chain-4 we route the single host byte to plane (offset[1:0]) only.
  // ---------------------------------------------------------------------------
  logic [7:0] wm0_byte_p0, wm0_byte_p1, wm0_byte_p2, wm0_byte_p3;
  always_comb begin
    // WM0 with bit mask — same byte to all planes (planar mode). Set/Reset
    // and logical ops are deferred; the host byte goes through unmodified.
    wm0_byte_p0 = (host_byte & gr_bit_mask) | (latch_q[0] & ~gr_bit_mask);
    wm0_byte_p1 = (host_byte & gr_bit_mask) | (latch_q[1] & ~gr_bit_mask);
    wm0_byte_p2 = (host_byte & gr_bit_mask) | (latch_q[2] & ~gr_bit_mask);
    wm0_byte_p3 = (host_byte & gr_bit_mask) | (latch_q[3] & ~gr_bit_mask);
  end

  // Write mode + chain-4 → wr_plane_mask and per-plane data:
  always_comb begin
    vram_wr_en        = is_write;
    vram_wr_addr      = sr_chain4 ? active_po_chain4 : active_po_planar;
    vram_wr_plane_mask = 4'b0000;
    vram_wr_data_p0    = host_byte;
    vram_wr_data_p1    = host_byte;
    vram_wr_data_p2    = host_byte;
    vram_wr_data_p3    = host_byte;

    if (is_write) begin
      if (sr_chain4) begin
        // Only the plane addressed by aper_offset[1:0] is written.
        unique case (active_chain4_plane)
          2'd0: vram_wr_plane_mask = 4'b0001;
          2'd1: vram_wr_plane_mask = 4'b0010;
          2'd2: vram_wr_plane_mask = 4'b0100;
          default: vram_wr_plane_mask = 4'b1000;
        endcase
        // Plane data is the raw host byte for chain-4.
        vram_wr_data_p0 = host_byte;
        vram_wr_data_p1 = host_byte;
        vram_wr_data_p2 = host_byte;
        vram_wr_data_p3 = host_byte;
      end else begin
        // Planar WM0: all planes selected by SR02 plane mask.
        unique case (gr_write_mode)
          2'd0: begin
            vram_wr_plane_mask = sr_plane_mask;
            vram_wr_data_p0 = wm0_byte_p0;
            vram_wr_data_p1 = wm0_byte_p1;
            vram_wr_data_p2 = wm0_byte_p2;
            vram_wr_data_p3 = wm0_byte_p3;
          end
          default: begin
            // WM1/2/3 not yet implemented — pass-through latch (WM1-ish).
            vram_wr_plane_mask = sr_plane_mask;
            vram_wr_data_p0 = latch_q[0];
            vram_wr_data_p1 = latch_q[1];
            vram_wr_data_p2 = latch_q[2];
            vram_wr_data_p3 = latch_q[3];
          end
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Host response
  // ---------------------------------------------------------------------------
  always_comb begin
    host_rsp = '0;
    if (is_my_cycle) begin
      host_rsp.ready = 1'b1;
      if (is_read) begin
        host_rsp.rdata = use_high_byte ? {read_byte, 8'h00}
                                       : {8'h00,     read_byte};
      end
    end
  end

  // verilator lint_off UNUSED
  wire unused_extras = |{sr_oddeven_dis, sr_extmem, gr_256mode, gr_read_mode};
  // verilator lint_on UNUSED

endmodule
