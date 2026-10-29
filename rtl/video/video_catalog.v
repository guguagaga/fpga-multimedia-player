// Four numbered video/audio pairs. Directory order never determines pairing.
// A slot is playable only when both M<n>*.VID and V<n>*.VAU exist (n=1..4).
// Duplicate identifiers keep the first entry; a sticky flag exposes ambiguity.
module video_catalog (
    input wire clk, rst, clear,
    input wire entry_valid, entry_audio,
    input wire [15:0] entry_prefix,
    input wire [31:0] entry_sector,
    input wire [1:0] index,
    input wire [31:0] legacy_video, legacy_audio,
    output reg [3:0] available,
    output reg [31:0] selected_video, selected_audio,
    output reg duplicate_seen
);
    reg [31:0] video_lba[0:3], audio_lba[0:3];
    reg [3:0] video_valid, audio_valid;
    wire prefix_ok = entry_audio ? ((entry_prefix[15:8] | 8'h20) == 8'h76)
                                 : ((entry_prefix[15:8] | 8'h20) == 8'h6d);
    wire id_ok = entry_prefix[7:0] >= 8'h31 && entry_prefix[7:0] <= 8'h34;
    wire [1:0] slot = entry_prefix[1:0] - 2'd1;
    wire legacy = video_valid == 0;
    // Directory contents settle before list_ready. Register the mask so the
    // legacy 64-bit address comparison does not enter the switch FSM path.
    always @(posedge clk or posedge rst) begin
        if (rst) available <= 0;
        else if (clear) available <= 0;
        else available <= legacy ? {3'b0,(legacy_video != 0 && legacy_audio != 0)}
                                 : video_valid & audio_valid;
    end
    // Only validity bits need reset. Unwritten entries cannot be selected.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            video_valid <= 0; audio_valid <= 0; duplicate_seen <= 0;
        end else if (clear) begin
            video_valid <= 0; audio_valid <= 0; duplicate_seen <= 0;
        end else if (entry_valid && prefix_ok && id_ok && entry_sector != 0) begin
            if (entry_audio) begin
                if (!audio_valid[slot]) begin
                    audio_lba[slot] <= entry_sector;
                    audio_valid[slot] <= 1;
                end else duplicate_seen <= 1;
            end else begin
                if (!video_valid[slot]) begin
                    video_lba[slot] <= entry_sector;
                    video_valid[slot] <= 1;
                end else duplicate_seen <= 1;
            end
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin selected_video <= 0; selected_audio <= 0; end
        else if (clear || !available[index]) begin selected_video <= 0; selected_audio <= 0; end
        else if (legacy) begin selected_video <= legacy_video; selected_audio <= legacy_audio; end
        else begin selected_video <= video_lba[index]; selected_audio <= audio_lba[index]; end
    end
endmodule
