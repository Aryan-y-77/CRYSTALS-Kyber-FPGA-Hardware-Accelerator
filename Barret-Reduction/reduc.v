module reduc (
    input wire clk,
    input wire rst,
    input wire in_valid,
    input wire [23:0] prod,
    output reg out_valid,
    output reg [11:0] res,
    output reg [11:0] quo,
    output wire in_ready
);

// quotient approximation
wire [11:0] t0 = prod[23:12];
wire [11:0] t1 = {2'b00, prod[23:14]};
wire [11:0] t2 = {6'b000000, prod[23:18]};
wire [11:0] t3 = {8'b00000000, prod[23:20]};
reg  [11:0] quo_approx;

always@(*)begin
    quo_approx = t0 + t1 - t2 - t3;
end

// difference 15-bit signed exact
wire [14:0] x15 = {3'b000, quo_approx};
wire [14:0] qprod = (x15 << 11) + (x15 << 10) + (x15 << 8) + x15;
reg signed [14:0] diff;
always@(*) begin
    diff = prod[14:0] - qprod;
end

// switch correction
reg signed [14:0] qmux;
reg [11:0] quo_corr;

always @(*)begin
    case (diff[14:12])
        3'b000 : begin qmux =  15'sd0;     quo_corr = quo_approx;           end 
        3'b001:  begin qmux = -15'sd3329;  quo_corr = quo_approx + 12'd1;   end
        3'b101:  begin qmux =  15'sd9987;  quo_corr = quo_approx - 12'd3;   end
        3'b110:  begin qmux =  15'sd9987;  quo_corr = quo_approx - 12'd3;   end
        3'b111:  begin qmux =  15'sd6658;  quo_corr = quo_approx - 12'd2;   end
        default: begin qmux =  15'sd0;     quo_corr = quo_approx;           end
    endcase
end

reg [14:0] sum15;
reg [13:0] res_comb;
always @(*) begin
    sum15 = diff + qmux;
    res_comb = sum15[13:0];
end

// final single-subtract guard
reg [13:0] res_final;
reg [11:0] quo_final;
always @(*) begin
    if (res_comb >= 14'd3329) begin
        res_final = res_comb - 14'd3329;
        quo_final = quo_corr + 12'd1;
    end else begin
        res_final = res_comb;
        quo_final = quo_corr;
    end
end

// output registration
always @(posedge clk) begin
    if (rst) begin
        out_valid <= 1'b0;
        res <= 12'b0;
        quo <= 12'b0;
    end else begin
        out_valid <= in_valid;
        if (in_valid) begin
            res <= res_final[11:0];
            quo <= quo_final[11:0];
        end
    end
end

assign in_ready = 1'b1;

endmodule