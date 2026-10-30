// Synchronous byte queue with an output register and ready/valid backpressure.
// Memory pointers count only RAM contents; the output register is one extra
// slot. RAM is never reset. Clear discards both RAM contents and output state.
module codec_byte_queue #(
    parameter integer AW = 10
) (
    input wire clk, clear,
    input wire [7:0] in_data,
    input wire in_valid,
    output wire in_ready,
    output wire [7:0] out_data,
    output reg out_valid,
    input wire out_ready
);
    (* ram_style="bram" *) reg [7:0] mem [0:(1<<AW)-1];
    reg [AW:0] write_ptr, read_ptr;
    reg [7:0] output_byte;
    wire [AW:0] used = write_ptr - read_ptr;
    wire empty = write_ptr == read_ptr;
    wire pop = out_valid && out_ready;
    wire read_enable = !clear && !empty && (!out_valid || pop);
    wire push = in_valid && in_ready;
    assign in_ready = !clear && !used[AW];
    assign out_data = output_byte;
    always @(posedge clk) begin
        if (push) mem[write_ptr[AW-1:0]] <= in_data;
        if (read_enable) output_byte <= mem[read_ptr[AW-1:0]];
    end
    always @(posedge clk) begin
        if (clear) begin
            write_ptr <= 0;
            read_ptr <= 0;
            out_valid <= 0;
        end else begin
            if (push) write_ptr <= write_ptr + 1'b1;
            if (read_enable) read_ptr <= read_ptr + 1'b1;
            if (read_enable) out_valid <= 1;
            else if (pop) out_valid <= 0;
        end
    end
endmodule
