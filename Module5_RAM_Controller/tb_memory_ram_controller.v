`timescale 1ns / 1ps

module tb_memory_ram_controller;

    reg clk = 1'b0;

    always #5 clk = ~clk;

    reg rst;

    reg rd_en;
    reg wr_en;
    reg [1:0] bank_sel;

    reg [7:0] addr_a;
    reg [7:0] addr_b;

    reg [23:0] wr_data_a;
    reg [23:0] wr_data_b;

    reg [6:0] offset;

    wire [23:0] rd_data_a;
    wire [23:0] rd_data_b;

    wire mem_busy;

    reg sample_valid;
    reg [11:0] sample_coeff;
    reg [7:0] sample_addr;
    reg [1:0] sample_bank_sel;

    wire sample_ready;

    integer passed = 0;
    integer failed = 0;


    //========================================================
    // DUT INSTANTIATION
    //========================================================

    memory_ram_controller dut (

        .clk(clk),
        .rst(rst),

        .rd_en(rd_en),
        .wr_en(wr_en),
        .bank_sel(bank_sel),

        .addr_a(addr_a),
        .addr_b(addr_b),

        .wr_data_a(wr_data_a),
        .wr_data_b(wr_data_b),

        .offset(offset),

        .rd_data_a(rd_data_a),
        .rd_data_b(rd_data_b),

        .mem_busy(mem_busy),

        .sample_valid(sample_valid),
        .sample_coeff(sample_coeff),
        .sample_addr(sample_addr),
        .sample_bank_sel(sample_bank_sel),
        .sample_ready(sample_ready)

    );


    //========================================================
    // COMMON TASKS
    //========================================================

    task check24;

        input [255:0] test_name;
        input [23:0] actual;
        input [23:0] expected;

        begin

            if (actual === expected) begin

                $display(
                    "PASS: %0s | Actual = %h",
                    test_name, actual
                );

                passed = passed + 1;

            end else begin

                $display(
                    "FAIL: %0s | Actual = %h Expected = %h",
                    test_name, actual, expected
                );

                failed = failed + 1;

            end

        end

    endtask


    task main_read;

        input [1:0] bank;
        input [7:0] a;
        input [7:0] b;
        input [6:0] off;

        begin

            @(negedge clk);

            bank_sel = bank;
            addr_a = a;
            addr_b = b;
            offset = off;

            rd_en = 1'b1;
            wr_en = 1'b0;

            @(posedge clk);
            #1;

            @(negedge clk);

            rd_en = 1'b0;

        end

    endtask


    task main_writeback;

        input [23:0] da;
        input [23:0] db;

        begin

            @(negedge clk);

            wr_data_a = da;
            wr_data_b = db;

            wr_en = 1'b1;
            rd_en = 1'b0;

            @(posedge clk);
            #1;

            @(negedge clk);

            wr_en = 1'b0;

        end

    endtask


    task send_sample;

        input [1:0] bank;
        input [7:0] address;
        input [11:0] coefficient;

        begin

            @(negedge clk);

            sample_bank_sel = bank;
            sample_addr = address;
            sample_coeff = coefficient;
            sample_valid = 1'b1;

            #1;

            if (sample_ready === 1'b1) begin

                @(posedge clk);
                #1;

            end else begin

                $display(
                    "FAIL: Sampler not ready at address %0d",
                    address
                );

                failed = failed + 1;

            end

            @(negedge clk);

            sample_valid = 1'b0;

        end

    endtask


    //========================================================
    // TEST SEQUENCE
    //========================================================

    initial begin

        // Initial values
        rst = 1'b1;

        rd_en = 1'b0;
        wr_en = 1'b0;

        bank_sel = 2'b00;

        addr_a = 0;
        addr_b = 0;

        wr_data_a = 0;
        wr_data_b = 0;

        offset = 0;

        sample_valid = 1'b0;
        sample_coeff = 0;
        sample_addr = 0;
        sample_bank_sel = 0;


        // Reset
        repeat (2) begin
            @(posedge clk);
            #1;
        end

        @(negedge clk);
        rst = 1'b0;


        //====================================================
        // TEST 1: RAM0 AND RAM1
        //====================================================

        $display("\nTEST 1: RAM0/RAM1");

        main_read(2'b00, 8'd10, 8'd11, 7'd0);

        main_writeback(24'h123456, 24'hABCDEF);

        main_read(2'b00, 8'd10, 8'd11, 7'd0);

        check24("RAM0 readback", rd_data_a, 24'h123456);
        check24("RAM1 readback", rd_data_b, 24'hABCDEF);


        //====================================================
        // TEST 2: RAM2 AND RAM3
        //====================================================

        $display("\nTEST 2: RAM2/RAM3");

        main_read(2'b01, 8'd70, 8'd71, 7'd0);

        main_writeback(24'h2468AC, 24'h13579B);

        main_read(2'b01, 8'd6, 8'd7, 7'd0);

        check24("RAM2 low-six-bit address", rd_data_a, 24'h2468AC);
        check24("RAM3 low-six-bit address", rd_data_b, 24'h13579B);


        //====================================================
        // TEST 3: RAM4
        //====================================================

        $display("\nTEST 3: RAM4");

        main_read(2'b10, 8'd20, 8'd20, 7'd0);

        main_writeback(24'h0A0B0C, 24'hD0D1D2);

        main_read(2'b10, 8'd20, 8'd20, 7'd0);

        check24("RAM4 lower half", rd_data_a, 24'h0A0B0C);
        check24("RAM4 upper half", rd_data_b, 24'hD0D1D2);


        //====================================================
        // TEST 4: RAM4 OFFSET
        //====================================================

        $display("\nTEST 4: RAM4 offset");

        main_read(2'b10, 8'd5, 8'd5, 7'd3);

        main_writeback(24'h112233, 24'h445566);

        main_read(2'b10, 8'd8, 8'd8, 7'd0);

        check24("RAM4 offset lower", rd_data_a, 24'h112233);
        check24("RAM4 offset upper", rd_data_b, 24'h445566);


        //====================================================
        // TEST 5: SAMPLER TO RAM0
        //====================================================

        $display("\nTEST 5: Sampler packing to RAM0");

        send_sample(2'b00, 8'd0, 12'h123);
        send_sample(2'b00, 8'd1, 12'h456);

        main_read(2'b00, 8'd0, 8'd0, 7'd0);

        check24(
            "Sampler RAM0 pair",
            rd_data_a,
            24'h123456
        );


        //====================================================
        // TEST 6: SAMPLER TO RAM1
        //====================================================

        $display("\nTEST 6: Sampler packing to RAM1");

        send_sample(2'b01, 8'd2, 12'hABC);
        send_sample(2'b01, 8'd3, 12'hDEF);

        main_read(2'b00, 8'd1, 8'd1, 7'd0);

        check24(
            "Sampler RAM1 pair",
            rd_data_b,
            24'hABCDEF
        );


        //====================================================
        // TEST 7: UNSUPPORTED SAMPLER BANK
        //====================================================

        $display("\nTEST 7: Unsupported sampler bank");

        @(negedge clk);

        sample_valid = 1'b1;
        sample_bank_sel = 2'b10;
        sample_addr = 8'd4;
        sample_coeff = 12'h111;

        #1;

        if (sample_ready === 1'b0) begin

            $display("PASS: Unsupported sampler bank rejected");
            passed = passed + 1;

        end else begin

            $display("FAIL: Unsupported sampler bank accepted");
            failed = failed + 1;

        end

        @(negedge clk);

        sample_valid = 1'b0;


        //====================================================
        // TEST 8: RESET AND RAM RETENTION
        //====================================================

        $display("\nTEST 8: Reset and RAM retention");

        main_read(2'b00, 8'd10, 8'd11, 7'd0);

        check24("RAM0 before reset", rd_data_a, 24'h123456);

        @(negedge clk);

        rst = 1'b1;

        @(posedge clk);
        #1;

        check24("Reset output A", rd_data_a, 24'h000000);

        @(negedge clk);

        rst = 1'b0;

        main_read(2'b00, 8'd10, 8'd11, 7'd0);

        check24("RAM0 retained after reset", rd_data_a, 24'h123456);


        //====================================================
        // TEST 9: RESERVED BANK
        //====================================================

        $display("\nTEST 9: Reserved bank");

        main_read(2'b11, 8'd0, 8'd0, 7'd0);

        check24("Reserved bank output A", rd_data_a, 24'h000000);
        check24("Reserved bank output B", rd_data_b, 24'h000000);


        //====================================================
        // TEST 10: READ OUTPUT HOLD
        //====================================================

        $display("\nTEST 10: Read output hold");

        main_read(2'b00, 8'd10, 8'd11, 7'd0);

        @(negedge clk);

        addr_a = 8'd99;
        addr_b = 8'd99;

        rd_en = 1'b0;

        @(posedge clk);
        #1;

        check24("Read output holds", rd_data_a, 24'h123456);


        //====================================================
        // FINAL SUMMARY
        //====================================================

        $display("\n==================================");
        $display("TESTS PASSED: %0d", passed);
        $display("TESTS FAILED: %0d", failed);
        $display("==================================");

        if (failed == 0)
            $display("TESTBENCH PASSED");
        else
            $fatal(1, "TESTBENCH FAILED");

        $finish;

    end

endmodule