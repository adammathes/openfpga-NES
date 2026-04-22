// Testbench for cheat_loader + upstream CODES module
//
// Feeds a stream of ASCII bytes (representing real cheat files) into the
// parser, then exercises the CODES module with CPU-style address/data probes
// to make sure the correct overrides fire.
//
// Covers:
//   * 6-letter codes (no compare)
//   * 8-letter codes (with compare)
//   * Multiple codes in a single file (incl. reset between files)
//   * Comments (# and ;), trailing names, blank lines, CRLF vs LF
//   * Case-insensitivity
//   * EOF flush (no trailing newline)
//   * Enable/disable gating
//   * Compare mismatch -> no override
//
// Reference vectors come from tools/gg_decode.py (FCEUX algorithm).

`timescale 1ns/1ps

module tb_cheat_loader;

    reg clk = 0;
    always #5 clk = ~clk;   // 100 MHz test clock (arbitrary)

    // ---- Loader <-> CODES wiring ------------------------------------
    reg          loader_reset;
    reg          stream_active;
    reg          stream_wr;
    reg  [7:0]   stream_data;

    wire [128:0] gg_code;
    wire [5:0]   cheat_count;

    cheat_loader loader (
        .clk          (clk),
        .reset        (loader_reset),
        .stream_active(stream_active),
        .stream_wr    (stream_wr),
        .stream_data  (stream_data),
        .gg_code      (gg_code),
        .cheat_count  (cheat_count)
    );

    // Codes module under test
    reg         codes_enable;
    reg  [15:0] cpu_addr;
    reg  [7:0]  cpu_data;
    wire        genie_ovr;
    wire [7:0]  genie_data;
    wire        genie_avail;

    // Must match the instantiation in rtl/upstream/nes.v so the sim exercises
    // the same storage depth the real core sees.
    localparam TB_MAX_CODES = 4;

    CODES #(
        .ADDR_WIDTH(16),
        .DATA_WIDTH(8),
        .MAX_CODES(TB_MAX_CODES)
    ) codes (
        .clk       (clk),
        .reset     (loader_reset),
        .enable    (codes_enable),
        .available (genie_avail),
        .addr_in   (cpu_addr),
        .data_in   (cpu_data),
        .code      (gg_code),
        .genie_ovr (genie_ovr),
        .genie_data(genie_data)
    );

    // ---- Helpers ----------------------------------------------------
    integer errors = 0;
    integer tests  = 0;

    task send_byte(input [7:0] b);
        begin
            @(posedge clk);
            stream_data <= b;
            stream_wr   <= 1'b1;
            @(posedge clk);
            stream_wr   <= 1'b0;
        end
    endtask

    task send_string(input [8191:0] s);
        integer i;
        integer top;
        reg [7:0] b;
        reg       started;
        begin
            // Find the highest index that holds the first character of the
            // string (Verilog packs string literals into the MSBs).
            top     = 1023;
            started = 0;
            for (i = 1023; i >= 0; i = i - 1) begin
                if (!started && s[i*8 +: 8] != 8'h00) begin
                    top     = i;
                    started = 1;
                end
            end
            if (!started) top = -1;
            for (i = top; i >= 0; i = i - 1) begin
                b = s[i*8 +: 8];
                send_byte(b);
            end
        end
    endtask

    task begin_file;
        begin
            loader_reset  = 1'b1;
            stream_active = 1'b0;
            stream_wr     = 1'b0;
            stream_data   = 8'd0;
            @(posedge clk); @(posedge clk);
            loader_reset  = 1'b0;
            @(posedge clk);
            stream_active = 1'b1;
            @(posedge clk);
        end
    endtask

    task end_file;
        begin
            repeat (4) @(posedge clk);
            stream_active = 1'b0;
            repeat (8) @(posedge clk);
        end
    endtask

    // Convenience: reset + stream a single contiguous string + end-of-stream.
    task send_file(input [8191:0] s);
        begin
            begin_file;
            send_string(s);
            end_file;
        end
    endtask

    task probe(input [15:0] addr, input [7:0] data,
               input        expect_ovr, input [7:0] expect_val);
        begin
            tests = tests + 1;
            @(negedge clk);
            cpu_addr = addr;
            cpu_data = data;
            @(negedge clk); // let combinational override settle
            if (genie_ovr !== expect_ovr) begin
                $display("FAIL[%0d] probe addr=%04h data=%02h: ovr=%b expected=%b",
                         tests, addr, data, genie_ovr, expect_ovr);
                errors = errors + 1;
            end else if (expect_ovr && genie_data !== expect_val) begin
                $display("FAIL[%0d] probe addr=%04h data=%02h: val=%02h expected=%02h",
                         tests, addr, data, genie_data, expect_val);
                errors = errors + 1;
            end else begin
                $display("ok[%0d] probe addr=%04h data=%02h -> ovr=%b val=%02h",
                         tests, addr, data, genie_ovr, genie_data);
            end
        end
    endtask

    // ---- Main test sequence -----------------------------------------
    initial begin
        // Log dump for post-mortem if needed.
        $dumpfile("tb_cheat_loader.vcd");
        $dumpvars(0, tb_cheat_loader);

        loader_reset  = 1;
        stream_active = 0;
        stream_wr     = 0;
        stream_data   = 0;
        codes_enable  = 1;
        cpu_addr      = 0;
        cpu_data      = 0;

        repeat (4) @(posedge clk);
        loader_reset = 0;
        repeat (2) @(posedge clk);

        // -------------------------------------------------------------
        // Test 1: single 6-letter SMB "infinite lives" code SXIOPO
        // Expected: addr=0x91D9, value=0xAD, no compare.
        // -------------------------------------------------------------
        $display("=== Test 1: 6-letter SXIOPO ===");
        send_file("SXIOPO\n");
        if (cheat_count !== 6'd1) begin
            $display("FAIL: cheat_count=%0d expected 1", cheat_count); errors=errors+1;
        end
        probe(16'h91D9, 8'hAA, 1'b1, 8'hAD); // any data, override fires
        probe(16'h91DA, 8'h00, 1'b0, 8'h00);
        probe(16'h91D8, 8'h00, 1'b0, 8'h00);

        // -------------------------------------------------------------
        // Test 2: 8-letter GXXZPOVG with compare
        // Expected: addr=0xA1A1, value=0x24, compare=0xCE.
        // -------------------------------------------------------------
        $display("=== Test 2: 8-letter GXXZPOVG ===");
        send_file("GXXZPOVG\n");
        if (cheat_count !== 6'd1) begin
            $display("FAIL: cheat_count=%0d expected 1", cheat_count); errors=errors+1;
        end
        probe(16'hA1A1, 8'hCE, 1'b1, 8'h24); // data matches compare -> override
        probe(16'hA1A1, 8'h00, 1'b0, 8'h00); // data differs -> no override
        probe(16'hA1A1, 8'hCF, 1'b0, 8'h00);

        // -------------------------------------------------------------
        // Test 3: multiple codes with comments, names, blank lines, CRLF
        // -------------------------------------------------------------
        $display("=== Test 3: mixed file, comments, names, CRLF ===");
        begin : mixed_file
            loader_reset = 1; @(posedge clk); @(posedge clk);
            loader_reset = 0; @(posedge clk);
            stream_active = 1; @(posedge clk);
            send_string("# SMB cheats collection");
            send_byte(8'h0D); send_byte(8'h0A);
            send_string("SXIOPO  Infinite lives");
            send_byte(8'h0D); send_byte(8'h0A);
            send_byte(8'h0D); send_byte(8'h0A);
            send_string("; a comment line");
            send_byte(8'h0D); send_byte(8'h0A);
            send_string("GXXZPOVG Metroid infinite energy");
            send_byte(8'h0A);
            send_string("aaaaaa all-A sanity code");
            send_byte(8'h0A);
            send_string("NNNNNN all-N");
            send_byte(8'h0A);
            repeat (8) @(posedge clk);
            stream_active = 0;
            repeat (8) @(posedge clk);
        end
        if (cheat_count !== 6'd4) begin
            $display("FAIL: cheat_count=%0d expected 4", cheat_count); errors=errors+1;
        end
        probe(16'h91D9, 8'hAA, 1'b1, 8'hAD); // SXIOPO
        probe(16'hA1A1, 8'hCE, 1'b1, 8'h24); // GXXZPOVG (compare match)
        probe(16'hA1A1, 8'hCD, 1'b0, 8'h00); // GXXZPOVG (compare miss)
        probe(16'h8000, 8'hFF, 1'b1, 8'h00); // aaaaaa
        probe(16'hFFFF, 8'h00, 1'b1, 8'hFF); // NNNNNN

        // -------------------------------------------------------------
        // Test 4: EOF without trailing newline
        // -------------------------------------------------------------
        $display("=== Test 4: EOF without trailing newline ===");
        send_file("SXIOPO");
        if (cheat_count !== 6'd1) begin
            $display("FAIL: cheat_count=%0d expected 1 (EOF flush)", cheat_count);
            errors = errors + 1;
        end
        probe(16'h91D9, 8'h00, 1'b1, 8'hAD);

        // -------------------------------------------------------------
        // Test 5: invalid lengths are ignored
        // -------------------------------------------------------------
        $display("=== Test 5: invalid length lines are ignored ===");
        send_file("SX\nABCDE\nSXIOPO\n");
        if (cheat_count !== 6'd1) begin
            $display("FAIL: cheat_count=%0d expected 1 (invalid skipped)", cheat_count);
            errors = errors + 1;
        end
        probe(16'h91D9, 8'h00, 1'b1, 8'hAD);

        // -------------------------------------------------------------
        // Test 6: disable gating
        // -------------------------------------------------------------
        $display("=== Test 6: disable gating ===");
        send_file("SXIOPO\n");
        codes_enable = 1'b0;
        @(posedge clk); @(posedge clk);
        probe(16'h91D9, 8'h00, 1'b0, 8'h00); // disabled -> no override
        codes_enable = 1'b1;
        @(posedge clk); @(posedge clk);
        probe(16'h91D9, 8'h00, 1'b1, 8'hAD);

        // -------------------------------------------------------------
        // Test 7: reset clears the code table
        // -------------------------------------------------------------
        $display("=== Test 7: reset clears cheat table ===");
        loader_reset = 1;
        @(posedge clk); @(posedge clk);
        loader_reset = 0;
        @(posedge clk);
        if (cheat_count !== 6'd0) begin
            $display("FAIL: cheat_count=%0d expected 0 after reset", cheat_count);
            errors = errors + 1;
        end
        probe(16'h91D9, 8'h00, 1'b0, 8'h00);

        // -------------------------------------------------------------
        // Test 8: code appears mid-file with leading spaces/tabs
        // -------------------------------------------------------------
        $display("=== Test 8: leading whitespace ===");
        send_file("\t  SXIOPO\n");
        if (cheat_count !== 6'd1) begin
            $display("FAIL: cheat_count=%0d expected 1", cheat_count); errors=errors+1;
        end
        probe(16'h91D9, 8'h00, 1'b1, 8'hAD);

        // -------------------------------------------------------------
        // Test 9: capacity + overflow.
        // Stream more codes than MAX_CODES can hold.  The parser keeps
        // counting (so cheat_count reflects everything it saw), the CODES
        // table saturates at TB_MAX_CODES, and the first code to arrive is
        // still active when the CPU probes for it.
        // -------------------------------------------------------------
        $display("=== Test 9: capacity + overflow (MAX_CODES=%0d) ===", TB_MAX_CODES);
        begin : big_load
            integer k;
            integer over;
            over = TB_MAX_CODES + 4;
            loader_reset = 1; @(posedge clk); @(posedge clk);
            loader_reset = 0; @(posedge clk);
            stream_active = 1; @(posedge clk);
            for (k = 0; k < over; k = k + 1) begin
                send_byte("S"); send_byte("X"); send_byte("I");
                send_byte("O"); send_byte("P"); send_byte("O");
                send_byte(8'h0A);
            end
            repeat (8) @(posedge clk);
            stream_active = 0;
            repeat (8) @(posedge clk);
        end
        if (cheat_count < TB_MAX_CODES[5:0]) begin
            $display("FAIL: cheat_count=%0d expected >=%0d",
                     cheat_count, TB_MAX_CODES);
            errors = errors + 1;
        end
        probe(16'h91D9, 8'h00, 1'b1, 8'hAD);

        // -------------------------------------------------------------
        $display("========================================");
        $display("TESTS: %0d   ERRORS: %0d", tests, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
