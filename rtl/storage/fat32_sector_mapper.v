// -----------------------------------------------------------------------------
// Module purpose: Read-only fragmented FAT32 file-sector translation with per-client cursors.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
// Read-only FAT32 logical-sector translator, 2026-10-27.
// Clients retain their existing virtual LBA = first_file_LBA + sector_offset.
// owner=2 is the raw filesystem client; other owners have independent cursors.
// One FAT-sector cache (128x32) absorbs sequential-cluster lookups. No media
// data are stored here. A transaction is owned until its response completes.
module fat32_sector_mapper #(
  parameter integer IO_TIMEOUT = 25000000,
  parameter integer MAX_WALK   = 1048576
) (
  input wire clk, rst, invalidate,
  input wire mounted,
  input wire [31:0] fat_start_lba, data_start_lba,
  input wire [3:0] cluster_shift,
  input wire [27:0] max_cluster,
  input wire req,
  input wire [1:0] owner,
  input wire [31:0] virtual_lba, file_base_lba,
  input wire multi, pace,
  output wire [7:0] data,
  output wire valid,
  output wire done,
  output reg error,
  output reg [3:0] error_code,
  output reg [1:0] error_owner,
  output wire sd_req,
  output reg [31:0] sd_lba,
  output wire sd_multi, sd_pace,
  input wire [7:0] sd_data,
  input wire sd_valid, sd_done
);
  reg [7:0] sd_data_q;
  reg sd_valid_q, sd_done_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      sd_data_q  <= 0;
      sd_valid_q <= 0;
      sd_done_q  <= 0;
    end else begin
      sd_data_q  <= sd_data;
      sd_valid_q <= sd_valid;
      sd_done_q  <= sd_done;
    end
  end
  localparam IDLE=21'h000001, OFFSET=21'h000002, BASE=21'h000004, CURSOR=21'h000008, LOOK=21'h000010, CACHE=21'h000020, FAT_READ=21'h000040, FAT_FINISH=21'h000080, ADVANCE=21'h000100, PHYS=21'h000200, READ=21'h000400, GAP=21'h000800, FAIL=21'h001000, CTX_READ=21'h002000, CTX_CHECK=21'h004000, CTX_WRITE=21'h008000, CACHE_HI=21'h010000, ALIGN=21'h020000, PHYS_ADD=21'h040000, SHIFT_RIGHT=21'h080000, SHIFT_LEFT=21'h100000, LOOK_PRE=22'h200000, LOOK_CACHE=23'h400000, NEXT_CHECK=24'h800000;
  reg [23:0] state;
  reg [ 1:0] who;
  reg [31:0] v_lba, base_lba, target_index, sector_in_cluster;
  reg [31:0] physical_lba, fat_lba, offset_lba;
  reg [27:0] first_cluster, current_cluster;
  reg [31:0] current_index;
  reg [$clog2(MAX_WALK+1)-1:0] walks;
  reg [3:0] shift_left;
  reg want_multi, want_pace, physical_multi;
  // Six 16-bit words per owner; serial metadata access costs <0.2us,
  // while keeping the complete three-stream cursor in one tiny BRAM.
  // Shared 16-bit memory: 0..255 FAT sector, 256..287 owner contexts.
  // Only one transaction is active, so both uses share read/write ports.
  (* ram_style="bram" *) reg [15:0] metadata_mem[0:511];
  reg [15:0] metadata_q, cache_low;
  reg [31:0] context_base;
  reg [15:0] context_write_data;
  reg [ 2:0] context_word;
  reg [ 3:0] cursor_valid;
  reg [31:0] cache_lba, assembled, next_entry;
  reg cache_valid;
  reg [9:0] byte_count;
  reg [6:0] entry_index;
  reg [$clog2(IO_TIMEOUT+2)-1:0] watchdog;
  // Mounted geometry is stable before a media request. Register the external
  // max-cluster add/decode before it reaches fault handling and cursor enables.
  reg [27:0] max_cluster_q;
  always @(posedge clk) max_cluster_q <= max_cluster;
  reg [6:0] sector_mask;
  always @(posedge clk) begin
    case (cluster_shift)
      0: sector_mask <= 0;
      1: sector_mask <= 1;
      2: sector_mask <= 3;
      3: sector_mask <= 7;
      4: sector_mask <= 15;
      5: sector_mask <= 31;
      6: sector_mask <= 63;
      default: sector_mask <= 127;
    endcase
  end
  wire[8:0]metadata_ra=(state==CACHE||state==FAT_FINISH||state==CACHE_HI)?
  {1'b0,entry_index,(state==FAT_FINISH||state==CACHE_HI)}:{4'b1000,who,context_word};
  reg [31:0] lookup_lba;
  reg lookup_at_target, lookup_walk_limit, lookup_cluster_bad, lookup_cache_hit;
  // One explicit prepare cycle: current_cluster/index and geometry have
  // settled before these flags feed the wide state/data clock enables.
  always @(posedge clk)
    if (state[21]) begin
      lookup_lba <= fat_start_lba + {11'd0, current_cluster[27:7]};
      lookup_at_target <= current_index == target_index;
      lookup_walk_limit <= walks >= MAX_WALK;
      lookup_cluster_bad <= current_cluster < 2 || current_cluster > max_cluster_q;
    end
  // Address addition completes before the equality comparator is sampled.
  always @(posedge clk) if (state[22]) lookup_cache_hit <= cache_valid && cache_lba == lookup_lba;
  wire [27:0] next_cluster = next_entry[27:0];
  // Separate wide FAT-entry validation from the shared fault/state/data
  // enables. next_entry is complete before NEXT_CHECK; the predicates
  // are consumed only in ADVANCE. EOC/bad/loop priority is unchanged.
  reg next_eoc_q, next_bad_q, next_loop_q;
  always @(posedge clk)
    if (state[23]) begin
      next_eoc_q <= next_cluster >= 28'hffffff8;
      next_bad_q <= next_cluster == 28'hffffff7 || next_cluster < 2 || next_cluster > max_cluster_q;
      next_loop_q <= next_cluster == current_cluster || next_cluster == first_cluster;
    end

  assign sd_req = ((state == FAT_READ) || (state == READ)) && !sd_done && !sd_done_q;
  assign sd_multi = (state == READ) && physical_multi;
  assign sd_pace = (state == READ) && want_pace;
  assign data = sd_data_q;
  assign valid = (state == READ) && sd_valid_q;
  assign done = ((state == READ) && sd_done_q) || (state == FAIL);
  // Serialize directly from the live fields; avoid a second 96-bit
  // shift register and its load/shift mux on every transaction.
  always @(*) begin
    case (context_word)
      0: context_write_data = base_lba[15:0];
      1: context_write_data = base_lba[31:16];
      2: context_write_data = current_index[15:0];
      3: context_write_data = current_index[31:16];
      4: context_write_data = current_cluster[15:0];
      default: context_write_data = {4'd0, current_cluster[27:16]};
    endcase
  end
  integer i;
  always @(posedge clk) begin
    metadata_q <= metadata_mem[metadata_ra];
    if (state == CTX_WRITE) metadata_mem[{4'b1000, who, context_word}] <= context_write_data;
    else if (state == FAT_READ && sd_valid_q && byte_count < 512 && byte_count[0])
      metadata_mem[{1'b0, byte_count[8:1]}] <= {sd_data_q, assembled[7:0]};
  end
  task fault;
    input [3:0] code;
    begin
      error <= 1;
      error_code <= code;
      error_owner <= who;
      cursor_valid[who] <= 0;
      state <= FAIL;
    end
  endtask
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= IDLE;
      who <= 0;
      v_lba <= 0;
      base_lba <= 0;
      target_index <= 0;
      sector_in_cluster <= 0;
      physical_lba <= 0;
      sd_lba <= 0;
      fat_lba <= 0;
      offset_lba <= 0;
      first_cluster <= 0;
      current_cluster <= 0;
      current_index <= 0;
      walks <= 0;
      shift_left <= 0;
      want_multi <= 0;
      want_pace <= 0;
      physical_multi <= 0;
      cursor_valid <= 0;
      cache_valid <= 0;
      cache_lba <= 0;
      byte_count <= 0;
      assembled <= 0;
      next_entry <= 0;
      entry_index <= 0;
      watchdog <= 0;
      error <= 0;
      error_code <= 0;
      error_owner <= 0;
      context_word <= 0;
      context_base <= 0;
    end else begin
      error <= 0;
      if (state == FAT_READ || state == READ) begin
        if (sd_valid_q || sd_done_q) watchdog <= 0;
        else watchdog <= watchdog + 1'b1;
      end else watchdog <= 0;
      case (1'b1)  // synthesis parallel_case
        state[0]:
        if (req) begin
          who <= owner;
          v_lba <= virtual_lba;
          base_lba <= file_base_lba;
          want_multi <= multi;
          want_pace <= pace;
          walks <= 0;
          if (owner == 2) begin
            physical_lba <= virtual_lba;
            sd_lba <= virtual_lba;
            physical_multi <= 0;
            state <= READ;
          end else state <= OFFSET;
        end
        state[1]: begin
          offset_lba   <= v_lba - base_lba;
          physical_lba <= base_lba - data_start_lba;
          if (!mounted || cluster_shift > 7 || base_lba < data_start_lba || v_lba < base_lba)
            fault(1);
          else state <= ALIGN;
        end
        state[17]: begin
          if ((physical_lba & {25'd0, sector_mask}) != 0) fault(1);
          else begin
            sector_in_cluster <= offset_lba & {25'd0, sector_mask};
            shift_left <= cluster_shift;
            state <= SHIFT_RIGHT;
          end
        end
        state[19]: begin
          if (shift_left != 0) begin
            physical_lba <= physical_lba >> 1;
            offset_lba   <= offset_lba >> 1;
            shift_left   <= shift_left - 1'b1;
          end else if (physical_lba > 32'h0fffffed) fault(2);
          else begin
            first_cluster <= physical_lba + 2;
            target_index <= offset_lba;
            state <= BASE;
          end
        end
        state[2]: begin
          if (first_cluster < 2 || first_cluster > max_cluster_q) fault(2);
          else state <= CURSOR;
        end
        state[3]: begin
          context_word <= 0;
          context_base <= 0;
          if (cursor_valid[who]) state <= CTX_READ;
          else begin
            current_index <= 0;
            current_cluster <= first_cluster;
            state <= LOOK_PRE;
          end
        end
        state[13]: begin
          case (context_word)
            1: context_base[15:0] <= metadata_q;
            2: context_base[31:16] <= metadata_q;
            3: current_index[15:0] <= metadata_q;
            4: current_index[31:16] <= metadata_q;
            5: current_cluster[15:0] <= metadata_q;
            6: current_cluster[27:16] <= metadata_q[11:0];
          endcase
          if (context_word == 6) state <= CTX_CHECK;
          else context_word <= context_word + 1'b1;
        end
        state[14]: begin
          if (context_base != base_lba || current_index > target_index) begin
            current_index   <= 0;
            current_cluster <= first_cluster;
          end
          state <= LOOK_PRE;
        end
        state[15]: begin
          if (context_word == 5) begin
            cursor_valid[who] <= 1;
            state <= READ;
          end else context_word <= context_word + 1'b1;
        end
        state[21]: state <= LOOK_CACHE;
        state[22]: state <= LOOK;
        state[4]: begin
          if (lookup_at_target) state <= PHYS;
          else if (lookup_walk_limit) fault(3);
          else if (lookup_cluster_bad) fault(2);
          else begin
            entry_index <= current_cluster[6:0];
            if (lookup_cache_hit) state <= CACHE;
            else begin
              fat_lba <= lookup_lba;
              sd_lba <= lookup_lba;
              byte_count <= 0;
              assembled <= 0;
              cache_valid <= 0;
              state <= FAT_READ;
            end
          end
        end
        // The synchronous cache read needs one full cycle after entry_index.
        state[5]:  state <= FAT_FINISH;
        state[6]: begin
          if (sd_valid_q) begin
            if (byte_count >= 512) fault(4);
            else begin
              byte_count <= byte_count + 1'b1;
              case (byte_count[1:0])
                0, 2: assembled[7:0] <= sd_data_q;
              endcase
            end
          end
          if (sd_done_q) begin
            if (!((byte_count == 512 && !sd_valid_q) || (byte_count == 511 && sd_valid_q)))
              fault(4);
            else begin
              cache_lba <= fat_lba;
              cache_valid <= 1;
              state <= GAP;
            end
          end else if (watchdog >= IO_TIMEOUT) fault(5);
        end
        state[11]: state <= CACHE;
        state[7]: begin
          cache_low <= metadata_q;
          state <= CACHE_HI;
        end
        state[16]: begin
          next_entry <= {metadata_q, cache_low};
          state <= NEXT_CHECK;
        end
        state[23]: state <= ADVANCE;
        state[8]: begin
          if (next_eoc_q) fault(6);  // EOC before requested offset
          else if (next_bad_q) fault(7);
          else if (next_loop_q) fault(8);
          else begin
            current_cluster <= next_cluster;
            current_index <= current_index + 1'b1;
            walks <= walks + 1'b1;
            state <= LOOK_PRE;
          end
        end
        state[9]: begin
          physical_lba <= current_cluster - 2;
          shift_left <= cluster_shift;
          // Never let a physical CMD18 batch cross a cluster boundary. Physically
          // cached sectors may be reused only by exact physical-LBA matches below.
          physical_multi<=want_multi&&(cluster_shift>=4)&&(sector_in_cluster[6:0]<={sector_mask[6:4],4'd0});
          context_word <= 0;
          state <= SHIFT_LEFT;
        end
        state[20]: begin
          if (shift_left != 0) begin
            physical_lba <= physical_lba << 1;
            shift_left   <= shift_left - 1'b1;
          end else state <= PHYS_ADD;
        end
        state[18]: begin
          sd_lba <= data_start_lba + physical_lba + sector_in_cluster;
          state  <= CTX_WRITE;
        end
        state[10]: begin
          if (sd_done_q) state <= IDLE;
          else if (watchdog >= IO_TIMEOUT) fault(5);
        end
        state[12]: state <= IDLE;
        default:   state <= IDLE;
      endcase
      // Card removal/remount invalidation occurs only outside a transaction.
      // The integration must reset the SD core for an active removal/timeout.
      if (invalidate) begin
        cursor_valid <= 0;
        cache_valid  <= 0;
      end
    end
  end
endmodule
