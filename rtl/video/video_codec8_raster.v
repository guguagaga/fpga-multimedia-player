`timescale 1ns/1ps
// Convert 8x8 block order to scanlines using seven rows of shared RGB565 RAM.
// Row zero goes directly to the output. Rows one through seven are written
// by block coordinates, then read sequentially before accepting a new stripe.
// The upstream decoder is registered: busy pauses it between whole blocks.
module video_codec8_raster #(
    parameter integer FRAME_W = 800,
    parameter integer RAM_AW = $clog2(FRAME_W * 7)
)(
    input wire clk, rst, clear,
    input wire pause,
    input wire pix_valid,
    input wire [15:0] pix_rgb565,
    output reg busy,
    output wire mem_we,
    output wire [RAM_AW-1:0] mem_waddr,
    output wire [15:0] mem_wdata,
    output wire [RAM_AW-1:0] mem_raddr,
    input wire [15:0] mem_rdata,
    output reg out_valid,
    output reg [15:0] out_rgb565
);
    reg [5:0] pos;
    reg [RAM_AW-1:0] block_x, write_addr, read_addr;
    reg read_wait;
    assign mem_we = pix_valid && !clear && !busy && (pos >= 8);
    assign mem_waddr = write_addr;
    assign mem_wdata = pix_rgb565;
    // Look ahead only when consuming the currently prefetched pixel.
    // A pause re-reads the held address, preserving its synchronous RAM data.
    assign mem_raddr = (busy && read_wait && !pause &&
                       read_addr != FRAME_W * 7 - 1) ? read_addr + 1'b1 : read_addr;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pos <= 0; block_x <= 0; write_addr <= 0; read_addr <= 0;
            busy <= 0; read_wait <= 0; out_valid <= 0; out_rgb565 <= 0;
        end else begin
            out_valid <= 0;
            if (clear) begin
                pos <= 0; block_x <= 0; write_addr <= 0; read_addr <= 0;
                busy <= 0; read_wait <= 0;
            end else if (!busy) begin
                if (pix_valid) begin
                    if (pos < 8) begin
                        out_valid <= 1;
                        out_rgb565 <= pix_rgb565;
                    end
                    if (pos == 63) begin
                        pos <= 0;
                        if (block_x == FRAME_W - 8) begin
                            block_x <= 0; write_addr <= 0;
                            busy <= 1; read_wait <= 0; read_addr <= 0;
                        end else begin
                            block_x <= block_x + 8;
                            write_addr <= block_x + 8;
                        end
                    end else begin
                        pos <= pos + 1'b1;
                        if (pos >= 8) begin
                            if (pos[2:0] == 7) write_addr <= write_addr + (FRAME_W - 7);
                            else write_addr <= write_addr + 1'b1;
                        end
                    end
                end
            end else begin
                // Prime once, then consume one synchronous RAM pixel per
                // cycle. mem_raddr issues the next read on the same edge.
                // Stalls hold both the logical address and prefetched data.
                if (!read_wait) read_wait <= 1;
                else if (!pause) begin
                    out_valid <= 1;
                    out_rgb565 <= mem_rdata;
                    if (read_addr == FRAME_W * 7 - 1) begin
                        busy <= 0; read_addr <= 0; read_wait <= 0;
                    end else read_addr <= read_addr + 1'b1;
                end
            end
        end
    end
endmodule
