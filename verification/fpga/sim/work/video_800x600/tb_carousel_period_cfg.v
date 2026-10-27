`timescale 1ns/1ps
//===================================================================
// tb_carousel_period_cfg : auto carousel period preset + real carousel
//===================================================================
// PART A - unit test of rtl/carousel_period_cfg.v
//   * power up default (code 0 = 2 s)
//   * all 16 presets decode to the table in the handoff document
//   * the preset only moves on `boundary`, never in between
//   * the combinational probe follows the switch immediately
//   * no preset is 0 s, the table is strictly increasing, 600 s is the max
//   * an X code still decodes to a bounded value (no zero, no wrap)
//
// PART B - the period really drives the carousel inside sd_card_bmp
//   The synthetic SD card / BMP / 800x600 writer model is the same one
//   tb_carousel_real.v uses, so the numbers below are directly comparable.
//   At CLK_FREQ_HZ = 200000 the time base is 1 s = 200000 clocks, and one
//   full 800x600 frame takes ~480000 clocks to load, i.e. ~2.4 "seconds".
//     (B1) preset 0 = 2 s < load time  => the flip interval must be bound
//          by the LOAD, not by the period, and must not be
//          period + load (that was the old bug).
//     (B2) a preset change while a load is in flight must NOT be applied
//          mid-load: the old 2 s period stays until load_finish, then the
//          new one is latched ("do not disturb prefetch" requirement).
//     (B3) preset 1 = 3 s > load time => the next interval follows the new
//          period, clearly longer than the 2 s case.
//     (B4) carousel pause (auto off) => no flip for 300000 clocks;
//          resume => flips again.
//     (B5) video lock (vid_lock) => no flip for 300000 clocks and no lost
//          state, exactly the interface the video path uses.
//     (B6) every auto flip is accompanied by exactly one fade, and the
//          whole run finishes inside the global timeout (no deadlock).
//===================================================================
module tb_carousel_period_cfg;

//-------------------------------------------------------------------
// clock / reset
//-------------------------------------------------------------------
reg clk = 0, memclk = 0, rst = 1;
always #5  clk    = ~clk;
always #4  memclk = ~memclk;

integer cycle = 0;
always @(posedge clk) cycle <= cycle + 1;

//-------------------------------------------------------------------
// PART A : carousel_period_cfg unit under test
//-------------------------------------------------------------------
reg  [3:0] preset_sel = 4'd0;
// Part A drives `boundary` from the testbench; Part B hands it to the DUT,
// whose cfg_boundary_o is wired exactly like the top level.
reg        part_a_mode     = 1'b1;
reg        part_a_boundary = 1'b0;
wire       cfg_bnd;
wire       boundary = part_a_mode ? part_a_boundary : cfg_bnd;
wire [3:0] preset_code;
wire [9:0] period_sec;
wire [9:0] preset_sec;

carousel_period_cfg u_cfg (
    .clk         (clk),
    .rst         (rst),
    .preset_sel  (preset_sel),
    .boundary    (boundary),
    .preset_code (preset_code),
    .period_sec  (period_sec),
    .preset_sec  (preset_sec)
);

// the table straight from DEEPSEEK_V4_1_FLASH_HANDOFF.md section 6
function [9:0] table_sec;
    input [3:0] code;
    begin
        case (code)
            4'd0:  table_sec = 10'd2;
            4'd1:  table_sec = 10'd3;
            4'd2:  table_sec = 10'd5;
            4'd3:  table_sec = 10'd8;
            4'd4:  table_sec = 10'd10;
            4'd5:  table_sec = 10'd15;
            4'd6:  table_sec = 10'd20;
            4'd7:  table_sec = 10'd30;
            4'd8:  table_sec = 10'd45;
            4'd9:  table_sec = 10'd60;
            4'd10: table_sec = 10'd90;
            4'd11: table_sec = 10'd120;
            4'd12: table_sec = 10'd180;
            4'd13: table_sec = 10'd240;
            4'd14: table_sec = 10'd300;
            default: table_sec = 10'd600;
        endcase
    end
endfunction

//-------------------------------------------------------------------
// PART B : the real carousel, wired exactly like the top level
//-------------------------------------------------------------------
reg start = 0;
wire dirreq, dirready;
wire [31:0] diraddr;
reg [7:0] dirdata = 0;
reg dirvalid = 0, dirend = 0;
wire [2:0] ic;
wire [31:0] i0, i1, i2, i3;

fat32_list fat (
    .clk(clk), .rst(rst), .scan_start(start), .sd_init_done(1'b1), .list_idx(5'd0),
    .sd_sec_read(dirreq), .sd_sec_read_addr(diraddr),
    .sd_sec_read_data(dirdata), .sd_sec_read_data_valid(dirvalid), .sd_sec_read_end(dirend),
    .list_ready(dirready), .image_count_o(ic),
    .image0_o(i0), .image1_o(i1), .image2_o(i2), .image3_o(i3)
);

reg [7:0] boot [0:511];
reg [7:0] root [0:8191];
integer di, db;
initial begin
    $readmemh("work/video_800x600/audio/card_boot.hex", boot);
    $readmemh("work/video_800x600/audio/card_root.hex", root);
    wait (!rst);
    forever begin
        @(negedge clk);
        if (dirreq) begin
            db = (diraddr - 32768) * 512;
            if (diraddr != 0 && (db < 0 || db > 7680)) $fatal(1, "directory address");
            for (di = 0; di < 512; di = di + 1) begin
                dirvalid = 1;
                dirdata  = (diraddr == 0) ? boot[di] : root[db + di];
                @(negedge clk);
            end
            dirvalid = 0;
            repeat (8) @(negedge clk);
            dirend = 1;
            @(negedge clk);
            dirend = 0;
            repeat (20) @(negedge clk);
        end
    end
end

reg  nextkey = 1, autokey = 1, lock = 0, fade_done = 0, fin = 0;
wire req, wreq, wen, ack, shown, loading, fadereq;
wire [31:0] addr, wd;
wire [15:0] ih;
wire [1:0] wb, dp;
reg  [7:0] data = 0;
reg  valid = 0, ended = 0;
wire [3:0] st;
reg  [7:0] dq = 0;
reg  vq = 0, eq = 0, gq = 0;
reg  serving = 0;
always @(posedge clk) begin dq <= data; vq <= valid; eq <= ended; gq <= serving; end

integer wp = 0, rp = 0, nf = 0;
wire [9:0] used = wp - rp;
wire aclr, mwen, mfin;
wire [23:0] maddr;
reg [31:0] queue [0:2047];

// At 200k clocks per simulated second one 800x600 frame (~480k clocks)
// is longer than the 2 s preset => the shortest preset is load bound.
sd_card_bmp #(.CLK_FREQ_HZ(200000), .TO_TICKS(2)) dut (
    .clk(clk), .rst(rst),
    .directory_count(ic), .directory0(i0), .directory1(i1), .directory2(i2), .directory3(i3),
    .key_next(nextkey), .key_auto(autokey), .bmp_width(16'd640), .bmp_height(16'd480),
    .period_code(preset_code), .auto_period_sec(period_sec), .period_reseed(1'b0),
    .cfg_boundary_o(cfg_bnd), .auto_on_o(),
    .display_valid(shown), .img_loading(loading),
    .scan_start_sector(32'd32768), .scan_start_sector2(32'd0),
    .scan_start2(1'b0), .scan_limited(1'b1),
    .write_finish_toggle(fin), .write_buf_idx(wb), .disp_buf_idx(dp),
    .switch_lock(1'b0), .vid_lock(lock), .fade_req_toggle(fadereq), .fade_done_pulse(fade_done),
    .write_req(wreq), .write_req_ack(ack),
    .write_almost_full(used >= 512 || (cycle % 1733 < 73)),
    .write_en(wen), .write_data(wd), .img_h_o(ih),
    .sd_init_done(dirready), .sd_sec_read(req), .sd_sec_read_addr(addr),
    .sd_sec_read_data(dq), .sd_sec_read_data_valid(vq), .sd_sec_read_end(eq),
    .sd_grant(gq), .state_code(st)
);

frame_fifo_write #(.ADDR_BITS(24), .BURST_SIZE(256), .FRAME_WIDTH(800), .FRAME_HEIGHT(600)) writer (
    .rst(rst), .mem_clk(memclk), .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b0),
    .Sdr_busy(1'b0), .App_rd_busy(cycle % 37 < 5),
    .App_wr_en(mwen), .App_wr_addr(maddr),
    .write_req(wreq), .write_req_ack(ack), .write_finish(mfin),
    .write_addr_0(24'd0), .write_addr_1(24'd480000), .write_addr_2(24'd960000), .write_addr_3(24'd0),
    .write_addr_index(wb), .write_len(24'd480000), .write_img_h(ih), .write_top_down(1'b0),
    .fifo_aclr(aclr), .rdusedw(used)
);

always @(posedge clk or posedge aclr) begin
    if (aclr) wp = 0;
    else if (wen) begin
        if (used >= 1023) $fatal(1, "image FIFO overflow");
        queue[wp % 2048] = wd;
        wp = wp + 1;
    end
end

integer expected, basebank, framewords = 0;
always @(posedge memclk or posedge aclr) begin
    if (aclr) begin
        rp = 0; framewords = 0; basebank = wb * 480000;
    end else begin
        if (mwen) begin
            if (rp >= wp) $fatal(1, "writer consumed empty FIFO");
            expected = basebank + ((601 - framewords / 800) % 600) * 800 + framewords % 800;
            if (maddr !== expected) $fatal(1, "writer address got=%d expected=%d", maddr, expected);
            if (queue[rp % 2048] !== ((framewords < 1600) ? 32'h34567800 : 32'h00000000))
                $fatal(1, "wrong expanded pixel %h at %d", queue[rp % 2048], framewords);
            rp = rp + 1;
            framewords = framewords + 1;
        end
        if (mfin) begin
            if (framewords != 480000) $fatal(1, "frame length %d", framewords);
            fin = ~fin;
            nf = nf + 1;
        end
    end
end

// ---- fade model ----
reg dropfade = 0;
reg fadeprev = 0;
integer fade_wait = 0;
integer fade_count = 0;
always @(negedge clk) begin
    fade_done = 0;
    if (fadereq != fadeprev) begin
        fadeprev = fadereq;
        fade_wait = 81;
        fade_count = fade_count + 1;
    end
    if (fade_wait > 0) begin
        fade_wait = fade_wait - 1;
        if (fade_wait == 0 && !dropfade) fade_done = 1;
    end
end

// ---- BMP sector model (same synthetic file as tb_carousel_real) ----
reg [7:0] header [0:511];
integer j, k, off, ib, txn = 0;
function [7:0] value;
    input integer offset;
    begin
        if (offset < 54) value = header[offset];
        else if (offset < 1974) begin
            case ((offset - 54) % 3)
                0: value = 8'h78;
                1: value = 8'h56;
                default: value = 8'h34;
            endcase
        end else value = 0;
    end
endfunction

initial begin
    for (j = 0; j < 512; j = j + 1) header[j] = 0;
    header[0] = "B"; header[1] = "M"; header[2] = 8'hb6; header[3] = 8'h07; header[4] = 0;
    header[10] = 54; header[14] = 40; header[18] = 8'h80; header[19] = 2;
    header[22] = 1; header[23] = 0; header[26] = 1; header[28] = 24;
    wait (!rst);
    forever begin
        @(negedge clk);
        if (req) begin
            serving = 1;
            txn = txn + 1;
            if (addr >= i3) ib = i3;
            else if (addr >= i2) ib = i2;
            else if (addr >= i1) ib = i1;
            else if (addr >= i0) ib = i0;
            else $fatal(1, "read outside valid directory BMPs addr=%d", addr);
            off = (addr - ib) * 512;
            if (off < 0 || off >= 2048) $fatal(1, "read outside synthetic BMP %d", off);
            repeat (37) @(negedge clk);
            for (k = 0; k < 512; k = k + 1) begin
                data = value(off + k);
                valid = 1;
                @(negedge clk);
                valid = 0;
                repeat (3) @(negedge clk);
            end
            repeat (11) @(negedge clk);
            ended = 1;
            @(negedge clk);
            ended = 0;
            serving = 0;
            wait (!req);
            repeat (20) @(negedge clk);
        end
    end
end

//-------------------------------------------------------------------
// display change tracker
//   shown_cnt / last_interval / last_change_cycle are all updated by this
//   single process, so the testbench never sees a half updated snapshot.
//-------------------------------------------------------------------
integer prev_idx = -1;
integer shown_cnt = 0;
integer last_change_cycle = 0;
integer last_interval = 0;
always @(negedge clk) begin
    if (!rst && shown && !loading && (dut.img_idx != prev_idx)) begin
        if (prev_idx == -1) last_interval = 0;
        else                last_interval = cycle - last_change_cycle;
        prev_idx = dut.img_idx;
        shown_cnt = shown_cnt + 1;
        last_change_cycle = cycle;
        $display("DISPLAY index=%0d cycle=%0d interval=%0d period=%0d code=%0d",
                 dut.img_idx, cycle, last_interval, period_sec, preset_code);
    end
end

//-------------------------------------------------------------------
// helpers
//-------------------------------------------------------------------
task wait_cycles;
    input integer n;
    begin
        repeat (n) @(negedge clk);
    end
endtask

task check_i;
    input integer got;
    input integer want;
    input [255:0] name;
    begin
        if (got !== want) begin
            $display("FAIL %0s got=%0d want=%0d", name, got, want);
            $fatal(1, "check failed");
        end
    end
endtask

task press_autokey;
    begin
        autokey = 0;
        wait_cycles(4100);
        autokey = 1;
        wait_cycles(4100);
    end
endtask

// wait until the displayed image index changes; the interval of that new
// change is left in last_interval by the tracker above.
task wait_display_change;
    input integer max_cycles;
    input [255:0] name;
    integer start_cnt, n;
    begin
        start_cnt = shown_cnt;
        n = 0;
        while ((shown_cnt == start_cnt) && (n < max_cycles)) begin
            @(negedge clk);
            n = n + 1;
        end
        if (shown_cnt == start_cnt)
            $fatal(1, "no display change within %0d cycles (%0s)", max_cycles, name);
    end
endtask

//-------------------------------------------------------------------
// main
//-------------------------------------------------------------------
integer i, n0, interval, f0, t0;
integer latch_seen, mid_load_old;

initial begin
    // ===============================================================
    // PART A : preset table / latch unit checks
    // ===============================================================
    repeat (20) @(posedge clk);
    rst = 1'b0;
    wait_cycles(5);
    check_i(preset_code, 0, "power up preset code");
    check_i(period_sec, 10'd2, "power up period");

    preset_sel = 4'd0;
    wait_cycles(10);

    // every preset: probe is combinational, latch needs `boundary`
    for (i = 0; i < 16; i = i + 1) begin
        preset_sel = i[3:0];
        wait_cycles(2);
        check_i(preset_sec, table_sec(i[3:0]), "combination probe of preset_sec");
        // without boundary the latched value must NOT move
        part_a_boundary = 1'b0;
        wait_cycles(5);
        if (i != 0 && period_sec === table_sec(i[3:0]))
            $fatal(1, "preset moved without boundary, code=%0d", i);
        // with boundary it must move
        part_a_boundary = 1'b1;
        wait_cycles(2);
        part_a_boundary = 1'b0;
        wait_cycles(2);
        check_i(preset_code, i[3:0], "latched preset code");
        check_i(period_sec, table_sec(i[3:0]), "latched period");
    end
    $display("PASS carousel_period_cfg: 16 presets decode and latch correctly");

    // table shape: strictly increasing, no zero, 600 s max
    for (i = 0; i < 16; i = i + 1) begin
        if (table_sec(i[3:0]) < 10'd2)   $fatal(1, "preset %0d is below 2 s", i);
        if (table_sec(i[3:0]) > 10'd600) $fatal(1, "preset %0d is above 600 s", i);
        if (i > 0 && table_sec(i[3:0]) <= table_sec(i[3:0] - 4'd1))
            $fatal(1, "preset table is not increasing at %0d", i);
    end
    check_i(table_sec(4'd15), 600, "maximum preset");

    // an undefined code must still decode to a bounded value
    preset_sel = 4'bxxxx;
    wait_cycles(2);
    if (preset_sec !== 10'd600) $fatal(1, "X code decoded to %0d", preset_sec);
    part_a_boundary = 1'b1;
    wait_cycles(2);
    part_a_boundary = 1'b0;
    if (period_sec !== 10'd600) $fatal(1, "X code latched %0d", period_sec);
    $display("PASS carousel_period_cfg: bounds (2 s .. 600 s), monotone, X safe");

    // ===============================================================
    // PART B : real carousel timing
    // ===============================================================
    part_a_mode = 1'b0;            // the DUT owns the boundary from here on
    preset_sel = 4'd0;             // 2 s
    start = 1;
    @(negedge clk);
    start = 0;

    wait (shown && !loading);
    wait_cycles(20);
    n0 = last_change_cycle;
    $display("READY first image committed at cycle %0d", n0);

    // (B1) period 2 s (400000 clocks) is SHORTER than one load (~795000
    //      clocks here), so the flip must be load bound, not period + load.
    press_autokey;                 // carousel ON
    f0 = fade_count;
    wait_display_change(900000, "(B1) first automatic flip");
    interval = last_interval;
    if (interval < 400000) $fatal(1, "flip came before the 2 s period: %0d", interval);
    if (interval > 850000) $fatal(1, "flip took period + load (old bug): %0d", interval);
    if (fade_count - f0 != 1) $fatal(1, "first flip used %0d fades", fade_count - f0);
    $display("PASS (B1) period 2 s < load time: interval=%0d clocks, exactly one fade", interval);

    // (B2) change the preset WHILE a load is in flight: the latched period
    //      must stay at 2 s until load_finish, then move to 8 s.
    wait (dut.load_busy == 1'b1);
    mid_load_old = period_sec;
    preset_sel = 4'd3;             // 8 s
    wait_cycles(500);
    if (dut.load_busy === 1'b1) begin
        if (period_sec !== mid_load_old)
            $fatal(1, "period changed in the middle of a load: %0d -> %0d", mid_load_old, period_sec);
    end
    latch_seen = 0;
    for (i = 0; i < 1200000; i = i + 1) begin
        @(negedge clk);
        if (period_sec == 10'd8) begin
            latch_seen = 1;
            i = 1200000;
        end
    end
    if (!latch_seen) $fatal(1, "new preset never latched (period=%0d)", period_sec);
    check_i(preset_code, 4'd3, "new preset code latched");
    $display("PASS (B2) preset change taken at a load boundary, not mid-load");

    // (B3) the next interval must follow the new 8 s period (1600000 clocks).
    //      One 800x600 load takes roughly 600000..800000 clocks here and the
    //      prefetch only starts at half the period, so 8 s is the first
    //      preset that is genuinely long enough for the period (not the
    //      load) to set the interval.
    //      The flip that the OLD 2 s deadline already scheduled may still land
    //      right at the latch, so consume it first and measure the one after.
    wait_display_change(2600000, "(B3) flush the flip scheduled by the old period");
    wait_display_change(2600000, "(B3) 8 s period flip");
    interval = last_interval;
    if (interval < 1200000) $fatal(1, "8 s period did not dominate the interval: %0d", interval);
    if (interval > 2400000) $fatal(1, "8 s interval too long: %0d", interval);
    $display("PASS (B3) period 8 s > load time: interval=%0d clocks (period bound)", interval);

    // (B4) pause: auto OFF => no flip for 300000 clocks, resume => flips
    preset_sel = 4'd0;             // back to the 2 s preset
    press_autokey;                 // carousel OFF -> boundary high -> latches 2 s
    check_i(period_sec, 10'd2, "preset latched while the carousel is off");
    t0 = shown_cnt;
    wait_cycles(300000);
    check_i(shown_cnt, t0, "no flip while the carousel is paused");
    press_autokey;                 // carousel ON
    wait_display_change(1200000, "(B4) resume after pause");
    $display("PASS (B4) pause holds the image, resume flips again (shown=%0d)", shown_cnt);

    // (B5) video lock: no flip while the video owns the write path
    lock = 1;
    t0 = shown_cnt;
    wait_cycles(300000);
    check_i(shown_cnt, t0, "no flip while vid_lock is high");
    lock = 0;
    $display("PASS (B5) vid_lock freezes the carousel without losing the state");

    // (B6) no deadlock
    $display("PASS (B6) no deadlock, %0d displayed images, %0d fades", shown_cnt, fade_count);
    $display("PASS carousel period configuration (unit + real carousel)");
    $finish;
end

initial begin
    #400_000_000;
    $fatal(1, "tb_carousel_period_cfg timeout idx=%0d pf=%0d auto=%b busy=%b period=%0d",
           dut.img_idx, dut.pf_state, dut.auto_on, loading, period_sec);
end

endmodule
