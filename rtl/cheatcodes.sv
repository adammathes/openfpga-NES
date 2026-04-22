// Cheat Code handling by Kitrinx
// Apr 21, 2019

// Code layout:
// {clock bit, 32'bcode flags, 32'b address, 32'b compare, 32'b replace}
//  128        127:96          95:64         63:32         31:0
// Integer values are in BIG endian byte order, so it up to the loader
// or generator of the code to re-arrange them correctly.

module CODES(
	input  clk,        // Best to not make it too high speed for timing reasons
	input  reset,      // This should only be triggered when a new rom is loaded or before new codes load, not warm reset
	input  enable,
	output available,
	input  [ADDR_WIDTH - 1:0] addr_in,
	input  [DATA_WIDTH - 1:0] data_in,
	input  [128:0] code,
	output logic genie_ovr,
	output logic [DATA_WIDTH - 1:0] genie_data
);

parameter ADDR_WIDTH   = 16; // Not more than 32
parameter DATA_WIDTH   = 8;  // Not more than 32
parameter MAX_CODES    = 32;

localparam INDEX_SIZE  = $clog2(MAX_CODES-1); // Number of bits for index, must accomodate MAX_CODES

localparam DATA_S      = DATA_WIDTH - 1;
localparam COMP_S      = DATA_S + DATA_WIDTH;
localparam ADDR_S      = COMP_S + ADDR_WIDTH;
localparam COMP_F_S    = ADDR_S + 1;
localparam ENA_F_S     = COMP_F_S + 1;

reg [ENA_F_S:0] codes[MAX_CODES];

wire [ADDR_WIDTH-1: 0] code_addr    = code[64+:ADDR_WIDTH];
wire [DATA_WIDTH-1: 0] code_compare = code[32+:DATA_WIDTH];
wire [DATA_WIDTH-1: 0] code_data    = code[0+:DATA_WIDTH];
wire code_comp_f = code[96];

wire [COMP_F_S:0] code_trimmed = {code_comp_f, code_addr, code_compare, code_data};

reg [INDEX_SIZE:0] index = '0;

assign available = |index;

reg code_change;
always_ff @(posedge clk) begin
	int x;
	if (reset) begin
		index <= 0;
		code_change <= 0;
		for (x = 0; x < MAX_CODES; x = x + 1) codes[x] <= '0;
	end else begin
		code_change <= code[128];
		if (code[128] && ~code_change && (index < MAX_CODES)) begin // detect posedge
			codes[index] <= {1'b1, code_trimmed};
			index <= index + 1'b1;
		end
	end
end

// --- Fan-out each code's fields onto continuous wires so the match loop
// --- doesn't need indexed part-selects inside the always_comb (cleaner for
// --- simulators and helps synthesis flatten the bit-picking).
wire                          code_ena [MAX_CODES];
wire                          code_cf  [MAX_CODES];
wire [ADDR_WIDTH - 1:0]       code_a   [MAX_CODES];
wire [DATA_WIDTH - 1:0]       code_c   [MAX_CODES];
wire [DATA_WIDTH - 1:0]       code_d   [MAX_CODES];

genvar gi;
generate
	for (gi = 0; gi < MAX_CODES; gi = gi + 1) begin : g_code_split
		assign code_ena[gi] = codes[gi][ENA_F_S];
		assign code_cf [gi] = codes[gi][COMP_F_S];
		assign code_a  [gi] = codes[gi][ADDR_S   -: ADDR_WIDTH];
		assign code_c  [gi] = codes[gi][COMP_S   -: DATA_WIDTH];
		assign code_d  [gi] = codes[gi][DATA_S   -: DATA_WIDTH];
	end
endgenerate

always_comb begin
	int x;
	genie_ovr = 0;
	genie_data = '0;

	if (enable) begin
		for (x = 0; x < MAX_CODES; x = x + 1) begin
			if (code_ena[x] && code_a[x] == addr_in) begin
				if (!code_cf[x] || (code_c[x] == data_in)) begin
					genie_ovr = 1;
					genie_data = code_d[x];
				end
			end
		end
	end
end

endmodule
