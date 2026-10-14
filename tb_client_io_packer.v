
`timescale 1ns / 1ps

module tb_client_io_packer;

    reg clk, rst, in_valid;
    reg [31:0] ext_data_in;
    reg [1:0] compress_mode;
    reg data_request;
    reg io_mode;
    reg [11:0] coeff_in_a, coeff_in_b;
    reg [1:0] cfg_k_sel;
    reg cfg_valid;

    wire out_valid;
    wire [11:0] coeff_out_a, coeff_out_b;
    wire [31:0] ext_data_out;
    wire buffer_full, out_ready, cfg_ready;

    integer errors;
    integer enc_word_count;
    integer decode_count;
    integer expected_pairs;
    integer i;

    reg [31:0] encoded_words [0:127];
    reg [11:0] expected_a [0:63];
    reg [11:0] expected_b [0:63];

    // Clock: 100 MHz
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Device under test
    client_io_packer dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .ext_data_in(ext_data_in),
        .compress_mode(compress_mode),
        .data_request(data_request),
        .out_valid(out_valid),
        .coeff_out_a(coeff_out_a),
        .coeff_out_b(coeff_out_b),
        .ext_data_out(ext_data_out),
        .buffer_full(buffer_full),
        .out_ready(out_ready),
        .io_mode(io_mode),
        .coeff_in_a(coeff_in_a),
        .coeff_in_b(coeff_in_b),
        .cfg_k_sel(cfg_k_sel),
        .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready)
    );

    // Compression reference
    function [11:0] compress_coeff;
        input [11:0] x;
        input integer d;
        integer scale;
        integer temp;
        begin
            if (d == 12)
                compress_coeff = x;
            else begin
                scale = (1 << d);
                temp = (x * scale + 1664) / 3329;
                temp = temp % scale;
                compress_coeff = temp[11:0];
            end
        end
    endfunction

    // Decompression reference
    function [11:0] decompress_coeff;
        input [11:0] c;
        input integer d;
        integer scale;
        integer temp;
        begin
            if (d == 12)
                decompress_coeff = c;
            else begin
                scale = (1 << d);
                temp = (c * 3329 + (scale / 2)) / scale;
                if (temp > 3328)
                    temp = 3328;
                decompress_coeff = temp[11:0];
            end
        end
    endfunction

    // Reset
    task reset_packer;
        begin
            rst = 1'b1;
            in_valid = 1'b0;
            data_request = 1'b0;
            ext_data_in = 32'd0;
            coeff_in_a = 12'd0;
            coeff_in_b = 12'd0;
            compress_mode = 2'b00;
            io_mode = 1'b0;
            cfg_k_sel = 2'd1;
            cfg_valid = 1'b0;

            repeat (3) @(negedge clk);
            rst = 1'b0;
            repeat (2) @(negedge clk);

            enc_word_count = 0;
            decode_count = 0;
        end
    endtask

    // Change Kyber parameter set
    task switch_k;
        input [1:0] new_k;
        begin
            while (!cfg_ready) @(negedge clk);

            cfg_k_sel = new_k;
            cfg_valid = 1'b1;
            @(negedge clk);
            cfg_valid = 1'b0;

            repeat (1) @(negedge clk);
            $display("K SWITCH: KSEL=%0d", new_k);
        end
    endtask

    // Capture encoder output words
    always @(negedge clk) begin
        if ((io_mode == 1'b0) && out_valid) begin
            encoded_words[enc_word_count] = ext_data_out;

            $display("[ENCODE] word %0d = 0x%08h",
                     enc_word_count, ext_data_out);

            enc_word_count = enc_word_count + 1;
        end
    end

    // Check decoded coefficient pairs
    always @(negedge clk) begin
        if ((io_mode == 1'b1) && out_valid) begin
            if (decode_count < expected_pairs) begin
                if ((coeff_out_a == expected_a[decode_count]) &&
                    (coeff_out_b == expected_b[decode_count])) begin
                    $display("[DECODE] pair %0d PASS: A=%0d B=%0d",
                             decode_count, coeff_out_a, coeff_out_b);
                end
                else begin
                    $display("[DECODE] pair %0d FAIL: got A=%0d B=%0d; expected A=%0d B=%0d",
                             decode_count, coeff_out_a, coeff_out_b,
                             expected_a[decode_count],
                             expected_b[decode_count]);
                    errors = errors + 1;
                end
                decode_count = decode_count + 1;
            end
            else begin
                $display("[DECODE] FAIL: unexpected extra output");
                errors = errors + 1;
            end
        end
    end

    // Submit an encoder coefficient pair
    task send_pair;
        input [11:0] a;
        input [11:0] b;
        begin
            while (!out_ready) @(negedge clk);

            coeff_in_a = a;
            coeff_in_b = b;
            in_valid = 1'b1;

            @(negedge clk);
            in_valid = 1'b0;
            coeff_in_a = 12'd0;
            coeff_in_b = 12'd0;
        end
    endtask

    // Submit one packed decoder word
    task send_decoder_word;
        input [31:0] word;
        begin
            while (!out_ready) @(negedge clk);

            ext_data_in = word;
            in_valid = 1'b1;

            @(negedge clk);
            in_valid = 1'b0;
            ext_data_in = 32'd0;
        end
    endtask

    // Request one decoded pair
    task request_one_pair;
        begin
            data_request = 1'b1;
            @(negedge clk);
            data_request = 1'b0;
            @(negedge clk);
        end
    endtask

    // Run encoder and check output word count
    task run_encode;
        input integer pair_count;
        input integer expected_words;
        integer j;
        begin
            io_mode = 1'b0;
            enc_word_count = 0;

            for (j = 0; j < pair_count; j = j + 1)
                send_pair(expected_a[j], expected_b[j]);

            repeat (4) @(negedge clk);

            $display("ENCODER: actual words=%0d, expected=%0d",
                     enc_word_count, expected_words);

            if (enc_word_count != expected_words)
                errors = errors + 1;
        end
    endtask

    // Run decoder and compare output pairs
    task run_decode;
        input integer word_count;
        input integer pair_count;
        integer w, r;
        begin
            io_mode = 1'b1;
            decode_count = 0;
            expected_pairs = pair_count;

            for (w = 0; w < word_count; w = w + 1) begin
                send_decoder_word(encoded_words[w]);

                // Give decoder time to consume available pairs
                for (r = 0; r < 4; r = r + 1)
                    if (decode_count < expected_pairs)
                        request_one_pair;
            end

            while (decode_count < expected_pairs)
                request_one_pair;

            $display("DECODER: checked %0d/%0d pairs",
                     decode_count, expected_pairs);
        end
    endtask

    // Main tests
    initial begin
        errors = 0;
        enc_word_count = 0;
        decode_count = 0;
        expected_pairs = 0;

        rst = 1'b1;
        in_valid = 1'b0;
        ext_data_in = 32'd0;
        compress_mode = 2'b00;
        data_request = 1'b0;
        io_mode = 1'b0;
        coeff_in_a = 12'd0;
        coeff_in_b = 12'd0;
        cfg_k_sel = 2'd1; // K-768
        cfg_valid = 1'b0;

        $display("==============================================");
        $display("CLIENT I/O PACKER TESTBENCH");
        $display("KSEL: 0=K-512, 1=K-768, 2=K-1024");
        $display("==============================================");

        // TEST 1: 12-bit mode, K-768
        reset_packer;
        compress_mode = 2'b00;

        expected_a[0]=100; expected_b[0]=120;
        expected_a[1]=200; expected_b[1]=300;
        expected_a[2]=400; expected_b[2]=500;
        expected_a[3]=600; expected_b[3]=700;

        $display("\nTEST 1: K-768, 12-bit mode");
        run_encode(4, 3);
        run_decode(3, 4);

        // TEST 2: d_u = 10-bit, K-768
        reset_packer;
        compress_mode = 2'b01;

        expected_a[0]=50;  expected_b[0]=60;
        expected_a[1]=70;  expected_b[1]=80;
        expected_a[2]=100; expected_b[2]=150;
        expected_a[3]=200; expected_b[3]=250;
        expected_a[4]=300; expected_b[4]=350;
        expected_a[5]=400; expected_b[5]=450;
        expected_a[6]=500; expected_b[6]=550;
        expected_a[7]=600; expected_b[7]=650;

        run_encode(8, 5);

        for (i=0; i<8; i=i+1) begin
            expected_a[i] = decompress_coeff(compress_coeff(expected_a[i],10),10);
            expected_b[i] = decompress_coeff(compress_coeff(expected_b[i],10),10);
        end

        reset_packer;
        compress_mode = 2'b01;
        run_decode(5, 8);

        // TEST 3: d_v = 4-bit, K-768
        reset_packer;
        compress_mode = 2'b10;

        expected_a[0]=500;  expected_b[0]=600;
        expected_a[1]=700;  expected_b[1]=800;
        expected_a[2]=900;  expected_b[2]=1000;
        expected_a[3]=1100; expected_b[3]=1200;
        expected_a[4]=1300; expected_b[4]=1400;
        expected_a[5]=1500; expected_b[5]=1600;
        expected_a[6]=1700; expected_b[6]=1800;
        expected_a[7]=1900; expected_b[7]=2000;

        run_encode(8, 2);

        for (i=0; i<8; i=i+1) begin
            expected_a[i] = decompress_coeff(compress_coeff(expected_a[i],4),4);
            expected_b[i] = decompress_coeff(compress_coeff(expected_b[i],4),4);
        end

        reset_packer;
        compress_mode = 2'b10;
        run_decode(2, 8);

        // TEST 4: Runtime K switch and d_u modes
        reset_packer;
        switch_k(2'd0); // K-512
        compress_mode = 2'b01;
        enc_word_count = 0;

        for (i=0; i<8; i=i+1) begin
            expected_a[i] = 100 + i*10;
            expected_b[i] = 200 + i*10;
            send_pair(expected_a[i], expected_b[i]);
        end

        repeat (4) @(negedge clk);

        if (enc_word_count == 5)
            $display("K-512 d_u PASS");
        else begin
            $display("K-512 d_u FAIL: words=%0d", enc_word_count);
            errors = errors + 1;
        end

        // Switch to K-1024
        switch_k(2'd2);
        compress_mode = 2'b01;
        enc_word_count = 0;

        for (i=0; i<16; i=i+1) begin
            expected_a[i] = 300 + i*10;
            expected_b[i] = 500 + i*10;
            send_pair(expected_a[i], expected_b[i]);
        end

        repeat (4) @(negedge clk);

        if (enc_word_count == 11)
            $display("K-1024 d_u PASS");
        else begin
            $display("K-1024 d_u FAIL: words=%0d", enc_word_count);
            errors = errors + 1;
        end

        // TEST 5: K-1024 d_v = 5-bit
        reset_packer;
        switch_k(2'd2);
        compress_mode = 2'b10;

        for (i=0; i<16; i=i+1) begin
            expected_a[i] = 100 + i*200;
            expected_b[i] = 200 + i*200;
        end

        run_encode(16, 5);

        for (i=0; i<16; i=i+1) begin
            expected_a[i] = decompress_coeff(compress_coeff(expected_a[i],5),5);
            expected_b[i] = decompress_coeff(compress_coeff(expected_b[i],5),5);
        end

        reset_packer;
        switch_k(2'd2);
        compress_mode = 2'b10;
        run_decode(5, 16);

        $display("\n==============================================");
        if (errors == 0)
            $display("ALL FUNCTIONAL TESTS PASSED");
        else
            $display("FUNCTIONAL TEST FAILED: errors=%0d", errors);
        $display("==============================================");

        #100;
        $finish;
    end

endmodule
