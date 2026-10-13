`timescale 1ns / 1ps

module memory_ram_controller (

    input  wire        clk,
    input  wire        rst,

    // Main memory control
    input  wire        rd_en,
    input  wire        wr_en,
    input  wire [1:0]  bank_sel,

    // Memory addresses
    input  wire [7:0]  addr_a,
    input  wire [7:0]  addr_b,

    // Main write data
    input  wire [23:0] wr_data_a,
    input  wire [23:0] wr_data_b,

    // RAM4 address offset
    input  wire [6:0]  offset,

    // Memory read outputs
    output reg  [23:0] rd_data_a,
    output reg  [23:0] rd_data_b,

    // Controller status
    output wire        mem_busy,

    // Sampler interface
    input  wire        sample_valid,
    input  wire [11:0] sample_coeff,
    input  wire [7:0]  sample_addr,
    input  wire [1:0]  sample_bank_sel,
    output wire        sample_ready
);

    //========================================================
    // 1. MEMORY DECLARATIONS
    //========================================================

    reg [23:0] RAM0 [0:255];
    reg [23:0] RAM1 [0:255];

    reg [23:0] RAM2 [0:63];
    reg [23:0] RAM3 [0:63];

    reg [47:0] RAM4 [0:127];


    //========================================================
    // 2. PREVIOUS READ ADDRESS REGISTERS
    //========================================================

    reg [7:0] last_addr_a;
    reg [7:0] last_addr_b;

    reg [1:0] last_bank_sel;
    reg [6:0] last_offset;

    reg last_read_valid;


    //========================================================
    // 3. SAMPLER PAIR BUFFER
    //========================================================

    reg        sample_pair_pending;
    reg [11:0] sample_even_coeff;
    reg [7:0]  sample_even_addr;
    reg [1:0]  sample_even_bank;


    //========================================================
    // 4. ADDRESS CALCULATION
    //========================================================

    wire [7:0] ram4_read_addr_full;
    wire [7:0] ram4_write_addr_full;

    assign ram4_read_addr_full =
        {1'b0, addr_a[6:0]} + {1'b0, offset};

    assign ram4_write_addr_full =
        {1'b0, last_addr_a[6:0]} + {1'b0, last_offset};


    //========================================================
    // 5. SAMPLER HANDSHAKE
    //========================================================

    wire sample_bank_supported;

    assign sample_bank_supported =
        (sample_bank_sel == 2'b00) ||
        (sample_bank_sel == 2'b01);

    wire sample_pair_matches;

    assign sample_pair_matches =
        sample_pair_pending &&
        sample_addr[0] &&
        (sample_addr == sample_even_addr + 8'd1) &&
        (sample_bank_sel == sample_even_bank);

    // Main writeback takes priority over sampler writes to RAM0/RAM1.
    wire main_write_active;

    assign main_write_active =
        wr_en && last_read_valid &&
        (last_bank_sel == 2'b00);

    // Accept an even coefficient into the pair buffer.
    // Accept an odd coefficient only if it matches the buffered pair.
    assign sample_ready =
        sample_bank_supported &&
        (
            (!sample_addr[0] && !sample_pair_pending) ||
            (sample_addr[0] &&
             sample_pair_matches &&
             !main_write_active)
        );

    assign mem_busy = sample_valid && !sample_ready;


    //========================================================
    // 6. SYNCHRONOUS MEMORY CONTROLLER
    //========================================================

    always @(posedge clk) begin

        if (rst) begin

            // Reset controller state and output registers.
            // Do not clear the RAM arrays.

            rd_data_a <= 24'b0;
            rd_data_b <= 24'b0;

            last_addr_a <= 8'b0;
            last_addr_b <= 8'b0;

            last_bank_sel <= 2'b00;
            last_offset <= 7'b0;

            last_read_valid <= 1'b0;

            sample_pair_pending <= 1'b0;
            sample_even_coeff <= 12'b0;
            sample_even_addr <= 8'b0;
            sample_even_bank <= 2'b00;

        end
        else begin

            //------------------------------------------------
            // A. SYNCHRONOUS READ
            //------------------------------------------------

            if (rd_en) begin

                case (bank_sel)

                    // RAM0 and RAM1
                    2'b00: begin

                        rd_data_a <= RAM0[addr_a];
                        rd_data_b <= RAM1[addr_b];

                    end

                    // RAM2 and RAM3
                    2'b01: begin

                        rd_data_a <= RAM2[addr_a[5:0]];
                        rd_data_b <= RAM3[addr_b[5:0]];

                    end

                    // RAM4: both outputs from the same 48-bit word
                    2'b10: begin

                        if (ram4_read_addr_full < 128) begin

                            rd_data_a <=
                                RAM4[ram4_read_addr_full[6:0]][23:0];

                            rd_data_b <=
                                RAM4[ram4_read_addr_full[6:0]][47:24];

                        end
                        else begin

                            rd_data_a <= 24'b0;
                            rd_data_b <= 24'b0;

                        end

                    end

                    // Reserved bank
                    default: begin

                        rd_data_a <= 24'b0;
                        rd_data_b <= 24'b0;

                    end

                endcase

                // Capture address context for the following writeback.
                last_addr_a <= addr_a;
                last_addr_b <= addr_b;

                last_bank_sel <= bank_sel;
                last_offset <= offset;

                last_read_valid <= 1'b1;

            end


            //------------------------------------------------
            // B. MAIN WRITEBACK
            //------------------------------------------------

            if (wr_en && last_read_valid) begin

                case (last_bank_sel)

                    // RAM0 and RAM1
                    2'b00: begin

                        RAM0[last_addr_a] <= wr_data_a;
                        RAM1[last_addr_b] <= wr_data_b;

                    end

                    // RAM2 and RAM3
                    2'b01: begin

                        RAM2[last_addr_a[5:0]] <= wr_data_a;
                        RAM3[last_addr_b[5:0]] <= wr_data_b;

                    end

                    // RAM4: one 48-bit word
                    2'b10: begin

                        if (ram4_write_addr_full < 128) begin

                            RAM4[ram4_write_addr_full[6:0]]
                                <= {wr_data_b, wr_data_a};

                        end

                    end

                    default: begin
                    end

                endcase

                // Consume the pending writeback context.
                // A new read in the same cycle establishes a new context.
                if (!rd_en)
                    last_read_valid <= 1'b0;

            end


            //------------------------------------------------
            // C. SAMPLER COEFFICIENT PAIR PACKING
            //------------------------------------------------

            if (sample_valid && sample_ready) begin

                // Buffer an even-indexed coefficient.
                if (!sample_addr[0]) begin

                    sample_even_coeff <= sample_coeff;
                    sample_even_addr <= sample_addr;
                    sample_even_bank <= sample_bank_sel;

                    sample_pair_pending <= 1'b1;

                end

                // Commit the matching odd-indexed coefficient.
                else begin

                    case (sample_even_bank)

                        // RAM0
                        2'b00: begin

                            RAM0[sample_even_addr[7:1]]
                                <= {sample_even_coeff, sample_coeff};

                        end

                        // RAM1
                        2'b01: begin

                            RAM1[sample_even_addr[7:1]]
                                <= {sample_even_coeff, sample_coeff};

                        end

                        default: begin
                        end

                    endcase

                    sample_pair_pending <= 1'b0;

                end

            end

        end

    end

endmodule