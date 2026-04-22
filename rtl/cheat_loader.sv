// NES cheat code loader
// ---------------------
// Parses a stream of ASCII Game Genie codes (one per line) and feeds the
// decoded 129-bit codes to the upstream CODES module (rtl/upstream/cheatcodes.sv).
//
// Intended to be fully compatible with the text cheat files used by
// MiSTer FPGA / RetroArch:
//   - One Game Genie code per line (6 or 8 letters from APZLGITYEOXUKSVN).
//   - Anything after the code on the line (e.g. descriptive name) is ignored.
//   - Lines starting with '#' or ';' are comments.
//   - Empty lines are skipped.
//   - Case-insensitive.
//
// The hardware decoder is a direct port of the canonical algorithm used by
// FCEUX (FCEUI_DecodeGG in src/cheat.cpp).
//
// On every successfully parsed code we pulse bit 128 of gg_code for one clock
// to trigger the CODES module to latch the new entry.  The module tracks the
// count of codes loaded (for UI/debug display) and supports a reset that
// clears the internal state (tied to ROM / cheat-file load).
//
// Alphabet:  A=0 P=1 Z=2 L=3 G=4 I=5 T=6 Y=7
//            E=8 O=9 X=A U=B K=C S=D V=E N=F
//

module cheat_loader (
    input  wire         clk,
    input  wire         reset,          // clears all parser state

    // ioctl-style byte stream (bytes only arrive while stream_active is high)
    input  wire         stream_active,  // high during the cheat-file download
    input  wire         stream_wr,      // one-cycle strobe per valid byte
    input  wire [7:0]   stream_data,

    // Code output to CODES module.  Bit 128 is the strobe; other bits hold the
    // decoded cheat.  Layout (matches rtl/upstream/cheatcodes.sv):
    //     [128]        : posedge strobe
    //     [127:97]     : unused
    //     [96]         : compare flag
    //     [95:80]      : unused
    //     [79:64]      : 16-bit address
    //     [63:40]      : unused
    //     [39:32]      : 8-bit compare
    //     [31:8]       : unused
    //     [7:0]        : 8-bit replacement data
    output reg  [128:0] gg_code,

    // Number of cheats successfully parsed since last reset (saturates at 63).
    output reg  [5:0]   cheat_count
);

    // ------------------------------------------------------------------
    // Alphabet decode helper.
    // Returns {valid, 4-bit nibble}.  valid=0 means the char is not a
    // Game-Genie letter.
    // ------------------------------------------------------------------
    function [4:0] gg_decode;
        input [7:0] c;
        reg   [7:0] uc;
        begin
            // Uppercase ASCII
            if (c >= 8'h61 && c <= 8'h7a) uc = c - 8'd32; else uc = c;
            case (uc)
                8'h41: gg_decode = 5'b1_0000; // A = 0
                8'h50: gg_decode = 5'b1_0001; // P = 1
                8'h5A: gg_decode = 5'b1_0010; // Z = 2
                8'h4C: gg_decode = 5'b1_0011; // L = 3
                8'h47: gg_decode = 5'b1_0100; // G = 4
                8'h49: gg_decode = 5'b1_0101; // I = 5
                8'h54: gg_decode = 5'b1_0110; // T = 6
                8'h59: gg_decode = 5'b1_0111; // Y = 7
                8'h45: gg_decode = 5'b1_1000; // E = 8
                8'h4F: gg_decode = 5'b1_1001; // O = 9
                8'h58: gg_decode = 5'b1_1010; // X = 10
                8'h55: gg_decode = 5'b1_1011; // U = 11
                8'h4B: gg_decode = 5'b1_1100; // K = 12
                8'h53: gg_decode = 5'b1_1101; // S = 13
                8'h56: gg_decode = 5'b1_1110; // V = 14
                8'h4E: gg_decode = 5'b1_1111; // N = 15
                default: gg_decode = 5'b0_0000;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // Per-letter nibble accumulator and count.
    // ------------------------------------------------------------------
    reg [3:0] t0, t1, t2, t3, t4, t5, t6, t7;
    reg [3:0] count;

    // ------------------------------------------------------------------
    // Combinational decode of the current accumulator into the 16-bit
    // address, 8-bit data and 8-bit compare.  Values are meaningful only
    // when count is 6 or 8.
    //
    // See FCEUX FCEUI_DecodeGG() in fceux/src/cheat.cpp for the source.
    // ------------------------------------------------------------------
    wire        is_eight   = (count == 4'd8);

    wire [15:0] dec_addr   = {
        1'b1,           // [15] always set (Game Genie only patches $8000-$FFFF)
        t3[2:0],        // [14:12]
        t4[3],          // [11]
        t5[2:0],        // [10:8]
        t1[3],          // [7]
        t2[2:0],        // [6:4]
        t3[3],          // [3]
        t4[2:0]         // [2:0]
    };

    wire [7:0] dec_data    = {
        t0[3],                        // [7]
        t1[2:0],                      // [6:4]
        is_eight ? t7[3] : t5[3],     // [3]
        t0[2:0]                       // [2:0]
    };

    wire [7:0] dec_compare = {
        t6[3],          // [7]
        t7[2:0],        // [6:4]
        t5[3],          // [3]
        t6[2:0]         // [2:0]
    };

    // ------------------------------------------------------------------
    // Simple line parser FSM.
    // ------------------------------------------------------------------
    localparam S_IDLE = 2'd0; // Looking for start of next code on a new line
    localparam S_READ = 2'd1; // Accumulating letters
    localparam S_SKIP = 2'd2; // Rest of line (name/comment) -> discard to newline

    reg [1:0] state;

    // Classify incoming byte (only valid on cycles where stream_wr=1).
    wire [4:0] dec          = gg_decode(stream_data);
    wire       letter_valid = dec[4];
    wire [3:0] letter       = dec[3:0];
    wire       is_newline   = (stream_data == 8'h0A) || (stream_data == 8'h0D);
    wire       is_space     = (stream_data == 8'h20) || (stream_data == 8'h09);
    wire       is_comment   = (stream_data == 8'h23) || (stream_data == 8'h3B); // '#' ';'

    // Internal helpers.
    reg        pending_emit;            // set high for one cycle when a code
                                        // should be latched into gg_code
    reg        strobe_active;           // gg_code[128] currently high
    reg [15:0] pending_addr;
    reg [7:0]  pending_data;
    reg [7:0]  pending_compare;
    reg        pending_cf;

    // Previous stream_active for end-of-stream detection (flush partial line).
    reg prev_stream_active;

    // ------------------------------------------------------------------
    // Shifting a letter into the accumulator.  We keep letters in t0..t7,
    // where tN is the N-th letter seen on the current line.
    // ------------------------------------------------------------------
    task accum_letter;
        input [3:0] idx;
        input [3:0] val;
        begin
            case (idx)
                4'd0: t0 <= val;
                4'd1: t1 <= val;
                4'd2: t2 <= val;
                4'd3: t3 <= val;
                4'd4: t4 <= val;
                4'd5: t5 <= val;
                4'd6: t6 <= val;
                4'd7: t7 <= val;
                default: ;
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            state              <= S_IDLE;
            count              <= 4'd0;
            {t0,t1,t2,t3,t4,t5,t6,t7} <= 32'd0;
            gg_code            <= 129'd0;
            cheat_count        <= 6'd0;
            pending_emit       <= 1'b0;
            strobe_active      <= 1'b0;
            pending_addr       <= 16'd0;
            pending_data       <= 8'd0;
            pending_compare    <= 8'd0;
            pending_cf         <= 1'b0;
            prev_stream_active <= 1'b0;
        end else begin
            prev_stream_active <= stream_active;

            // 1) Finish any previous strobe: pull bit[128] low for the next
            //    cycle so CODES will detect the next rising edge.
            if (strobe_active) begin
                gg_code[128]  <= 1'b0;
                strobe_active <= 1'b0;
            end

            // 2) If we queued an emit last cycle, push it onto the wire now.
            //    Splitting the emit across two cycles gives the CODES module
            //    a clean 0->1 transition on gg_code[128].
            if (pending_emit) begin
                gg_code        <= {1'b1, 31'd0, pending_cf,
                                   16'd0, pending_addr,
                                   24'd0, pending_compare,
                                   24'd0, pending_data};
                strobe_active  <= 1'b1;
                pending_emit   <= 1'b0;
                if (cheat_count != 6'd63) cheat_count <= cheat_count + 6'd1;
            end

            // 3) End-of-stream flush: the final line may not have a trailing
            //    newline.  On the falling edge of stream_active, commit any
            //    fully-formed code sitting in the accumulator.
            if (prev_stream_active && !stream_active) begin
                if (state == S_READ && (count == 4'd6 || count == 4'd8)) begin
                    pending_addr    <= dec_addr;
                    pending_data    <= dec_data;
                    pending_compare <= dec_compare;
                    pending_cf      <= is_eight;
                    pending_emit    <= 1'b1;
                end
                state <= S_IDLE;
                count <= 4'd0;
            end

            // 4) Main byte handler.
            if (stream_wr) begin
                case (state)
                    S_IDLE: begin
                        if (letter_valid) begin
                            accum_letter(4'd0, letter);
                            count <= 4'd1;
                            state <= S_READ;
                        end else if (is_newline || is_space) begin
                            // Ignore leading whitespace, stay idle.
                        end else if (is_comment) begin
                            state <= S_SKIP;
                        end else begin
                            // Anything else (weird BOM, digits, punctuation)
                            // treat as comment to end-of-line.
                            state <= S_SKIP;
                        end
                    end

                    S_READ: begin
                        if (letter_valid && count < 4'd8) begin
                            accum_letter(count, letter);
                            count <= count + 4'd1;
                        end else begin
                            // Code terminated.  Emit if length is valid.
                            if (count == 4'd6 || count == 4'd8) begin
                                pending_addr    <= dec_addr;
                                pending_data    <= dec_data;
                                pending_compare <= dec_compare;
                                pending_cf      <= is_eight;
                                pending_emit    <= 1'b1;
                            end
                            count <= 4'd0;
                            state <= is_newline ? S_IDLE : S_SKIP;
                        end
                    end

                    S_SKIP: begin
                        if (is_newline) state <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
