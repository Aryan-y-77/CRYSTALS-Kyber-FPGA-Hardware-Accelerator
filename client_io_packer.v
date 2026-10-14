
`timescale 1ns / 1ps

module client_io_packer (
    input  wire        clk,
    input  wire        rst,             // Synchronous active-high reset
    input  wire        in_valid,
    input  wire [31:0] ext_data_in,
    input  wire [1:0]  compress_mode,
    input  wire        data_request,

    output reg         out_valid,
    output reg  [11:0] coeff_out_a,
    output reg  [11:0] coeff_out_b,
    output reg  [31:0] ext_data_out,

    output wire        buffer_full,
    output wire        out_ready,

    // Additional standalone interface:
    // io_mode = 0: encode; io_mode = 1: decode
    input  wire        io_mode,
    input  wire [11:0] coeff_in_a,
    input  wire [11:0] coeff_in_b,

    // cfg_k_sel: 0 = K-512, 1 = K-768, 2 = K-1024
    input  wire [1:0]  cfg_k_sel,
    input  wire        cfg_valid,
    output wire        cfg_ready
);

    localparam integer Q = 3329;

    reg [1:0]  k_sel;
    reg [51:0] shift_reg;
    reg [5:0]  bit_count;
    reg [5:0]  bit_width;

    wire [5:0] pair_bits;
    assign pair_bits = bit_width << 1;

    // ------------------------------------------------------------
    // Active coefficient width
    // ------------------------------------------------------------
    always @(*) begin
        case (compress_mode)
            2'b00: bit_width = 6'd12;
            2'b01: bit_width = (k_sel == 2'd2) ? 6'd11 : 6'd10;
            2'b10: bit_width = (k_sel == 2'd2) ? 6'd5  : 6'd4;
            default: bit_width = 6'd12;
        endcase
    end

    // ------------------------------------------------------------
    // Kyber coefficient compression
    // Compress x in [0, 3328] to d bits:
    // round(x * 2^d / Q), modulo 2^d.
    // ------------------------------------------------------------
    function [11:0] compress_coeff;
        input [11:0] x;
        input [5:0] d;
        reg [31:0] scale;
        reg [31:0] temp;
        begin
            if (d == 6'd12) begin
                compress_coeff = x;
            end else begin
                scale = (32'd1 << d);
                temp = ((x * scale) + (Q / 2)) / Q;
                temp = temp % scale;
                compress_coeff = temp[11:0];
            end
        end
    endfunction

    // ------------------------------------------------------------
    // Kyber coefficient decompression
    // round(c * Q / 2^d)
    // ------------------------------------------------------------
    function [11:0] decompress_coeff;
        input [11:0] c;
        input [5:0] d;
        reg [31:0] scale;
        reg [31:0] temp;
        begin
            if (d == 6'd12) begin
                decompress_coeff = c;
            end else begin
                scale = (32'd1 << d);
                temp = ((c * Q) + (scale / 2)) / scale;

                if (temp > 32'd3328)
                    temp = 32'd3328;

                decompress_coeff = temp[11:0];
            end
        end
    endfunction

    // ------------------------------------------------------------
    // Coefficient pair packing
    // B occupies the lower d bits; A follows B.
    // ------------------------------------------------------------
    wire [11:0] comp_a;
    wire [11:0] comp_b;
    wire [23:0] pair_data;

    assign comp_a = compress_coeff(coeff_in_a, bit_width);
    assign comp_b = compress_coeff(coeff_in_b, bit_width);

    assign pair_data =
        ({12'd0, comp_a} << bit_width) |
        {12'd0, comp_b};

    // ------------------------------------------------------------
    // Next-buffer values
    // ------------------------------------------------------------
    wire [51:0] encoder_next;
    wire [51:0] decoder_next;

    assign encoder_next =
        shift_reg | ({28'd0, pair_data} << bit_count);

    assign decoder_next =
        shift_reg | ({20'd0, ext_data_in} << bit_count);

    // ------------------------------------------------------------
    // Handshake and status
    // Prevent simultaneous decoder load and pair consumption.
    // ------------------------------------------------------------
    assign out_ready =
        (io_mode == 1'b0)
        ? ((52 - bit_count) >= pair_bits)
        : (((52 - bit_count) >= 32) &&
           !(data_request && (bit_count >= pair_bits)));

    assign buffer_full = (bit_count >= 6'd32);

    assign cfg_ready =
        (bit_count == 6'd0) && (out_valid == 1'b0);

    // ------------------------------------------------------------
    // Decoder field extraction
    // ------------------------------------------------------------
    wire [11:0] coeff_mask;
    wire [11:0] raw_b;
    wire [11:0] raw_a;

    assign coeff_mask =
        (bit_width == 6'd12) ? 12'hFFF :
        (bit_width == 6'd11) ? 12'h7FF :
        (bit_width == 6'd10) ? 12'h3FF :
        (bit_width == 6'd5)  ? 12'h01F :
        (bit_width == 6'd4)  ? 12'h00F : 12'h000;

    assign raw_b = shift_reg[11:0] & coeff_mask;
    assign raw_a = (shift_reg >> bit_width) & coeff_mask;

    // ------------------------------------------------------------
    // Sequential encoder / decoder
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            shift_reg    <= 52'd0;
            bit_count    <= 6'd0;
            out_valid    <= 1'b0;
            coeff_out_a  <= 12'd0;
            coeff_out_b  <= 12'd0;
            ext_data_out <= 32'd0;
            k_sel        <= 2'd1; // Default K-768
        end else begin
            out_valid <= 1'b0;

            // Change K only when the buffer is empty.
            if (cfg_valid && cfg_ready && (cfg_k_sel <= 2'd2))
                k_sel <= cfg_k_sel;

            if (io_mode == 1'b0) begin
                // ENCODER: accept a coefficient pair.
                if (in_valid && out_ready) begin
                    if ((bit_count + pair_bits) >= 32) begin
                        ext_data_out <= encoder_next[31:0];
                        out_valid    <= 1'b1;
                        shift_reg    <= encoder_next >> 32;
                        bit_count    <= bit_count + pair_bits - 32;
                    end else begin
                        shift_reg <= encoder_next;
                        bit_count <= bit_count + pair_bits;
                    end
                end
            end else begin
                // DECODER: load a 32-bit word when requested space allows.
                if (in_valid && out_ready) begin
                    shift_reg <= decoder_next;
                    bit_count <= bit_count + 32;
                end

                // Consume an available coefficient pair.
                if (data_request && (bit_count >= pair_bits)) begin
                    coeff_out_b <= decompress_coeff(raw_b, bit_width);
                    coeff_out_a <= decompress_coeff(raw_a, bit_width);
                    out_valid   <= 1'b1;
                    shift_reg   <= shift_reg >> pair_bits;
                    bit_count   <= bit_count - pair_bits;
                end
            end
        end
    end

endmodule
