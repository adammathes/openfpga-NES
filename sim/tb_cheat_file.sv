// End-to-end-ish test: stream the REAL example_smb.gg (and another multi-code
// file) as bytes into cheat_loader + CODES, matching the pulse pattern from
// data_loader on hardware (1-cycle stream_wr, ~4-cycle gap).
//
// Goal: reproduce whatever breaks on the Pocket in simulation.

`timescale 1ns/1ps

module tb_cheat_file;

    reg clk = 0;
    always #5 clk = ~clk;

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

    reg         codes_enable;
    reg  [15:0] cpu_addr;
    reg  [7:0]  cpu_data;
    wire        genie_ovr;
    wire [7:0]  genie_data;
    wire        genie_avail;

    CODES #(
        .ADDR_WIDTH(16),
        .DATA_WIDTH(8),
        .MAX_CODES(4)
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

    integer errors = 0;
    integer tests  = 0;

    // Send one byte with data_loader-like timing: stream_wr high for 1 cycle,
    // then ~4 cycles low before the next byte. (Real data_loader has
    // WRITE_MEM_CLOCK_DELAY=4 gap between pulses.)
    task send_byte_like_hw(input [7:0] b);
        begin
            @(posedge clk);
            stream_data <= b;
            stream_wr   <= 1'b1;
            @(posedge clk);
            stream_wr   <= 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    task probe(input [15:0] addr, input [7:0] data,
               input        expect_ovr, input [7:0] expect_val);
        begin
            tests = tests + 1;
            @(negedge clk);
            cpu_addr = addr;
            cpu_data = data;
            @(negedge clk);
            if (genie_ovr !== expect_ovr) begin
                $display("FAIL[%0d] addr=%04h data=%02h: ovr=%b expected=%b",
                         tests, addr, data, genie_ovr, expect_ovr);
                errors = errors + 1;
            end else if (expect_ovr && genie_data !== expect_val) begin
                $display("FAIL[%0d] addr=%04h data=%02h: val=%02h expected=%02h",
                         tests, addr, data, genie_data, expect_val);
                errors = errors + 1;
            end else begin
                $display("ok[%0d] addr=%04h data=%02h -> ovr=%b val=%02h",
                         tests, addr, data, genie_ovr, genie_data);
            end
        end
    endtask

    // Open a file, stream its bytes through cheat_loader with HW-like timing.
    task stream_file(input [1023:0] path);
        integer fh;
        integer rc;
        reg [7:0] b;
        begin
            loader_reset  = 1'b1;
            stream_active = 1'b0;
            stream_wr     = 1'b0;
            @(posedge clk); @(posedge clk);
            loader_reset  = 1'b0;
            @(posedge clk);
            stream_active = 1'b1;
            @(posedge clk);

            fh = $fopen(path, "rb");
            if (fh == 0) begin
                $display("FAIL: could not open %0s", path);
                errors = errors + 1;
                $finish;
            end
            rc = $fgetc(fh);
            while (rc >= 0) begin
                b = rc[7:0];
                send_byte_like_hw(b);
                rc = $fgetc(fh);
            end
            $fclose(fh);

            // Match HW: cheat_download falls some cycles after last byte.
            repeat (10) @(posedge clk);
            stream_active = 1'b0;
            repeat (20) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_cheat_file.vcd");
        $dumpvars(0, tb_cheat_file);

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

        // --- example_smb.gg: contains two 6-letter codes ---
        $display("=== Streaming example_smb.gg ===");
        stream_file("../pkg/pocket/Assets/nes/common/cheats/example_smb.gg");
        $display("cheat_count=%0d (expected 2)", cheat_count);
        if (cheat_count !== 6'd2) begin
            $display("FAIL: expected cheat_count=2, got %0d", cheat_count);
            errors = errors + 1;
        end

        // SXIOPO -> 0x91D9 / data 0xAD (no compare)
        probe(16'h91D9, 8'hAA, 1'b1, 8'hAD);
        probe(16'h91DA, 8'h00, 1'b0, 8'h00);

        // AATOZA -> verify decoded address. AATOZA = 0,0,6,9,2,0
        // t0=0 t1=0 t2=6 t3=9 t4=2 t5=0
        // addr = {1, t3[2:0], t4[3], t5[2:0], t1[3], t2[2:0], t3[3], t4[2:0]}
        //      = {1, 001, 0, 000, 0, 110, 1, 010}
        //      = 1001_0000_0_110_1_010 = 16'h906A
        // data = {t0[3], t1[2:0], t5[3], t0[2:0]}
        //      = {0, 000, 0, 000} = 0x00
        probe(16'h906A, 8'hFF, 1'b1, 8'h00);

        // --- custom big file: 5 codes, should see only the first 4 ---
        $display("=== Streaming overflow test (5 codes, MAX=4) ===");
        begin : dump_file
            integer fh;
            fh = $fopen("overflow.gg", "w");
            $fwrite(fh, "# five codes\n");
            $fwrite(fh, "SXIOPO\n");          // 0x91D9 / 0xAD
            $fwrite(fh, "AATOZA\n");          // 0x906A / 0x00
            $fwrite(fh, "GXXZPOVG\n");        // 0xA1A1 / 0x24 (compare 0xCE)
            $fwrite(fh, "NNNNNN\n");          // 0xFFFF / 0xFF
            $fwrite(fh, "PPPPPP\n");          // this one should be dropped
            $fclose(fh);
        end
        stream_file("overflow.gg");
        $display("cheat_count=%0d (expected >=4)", cheat_count);
        probe(16'h91D9, 8'h00, 1'b1, 8'hAD);
        probe(16'h906A, 8'h00, 1'b1, 8'h00);
        probe(16'hA1A1, 8'hCE, 1'b1, 8'h24);
        probe(16'hFFFF, 8'h00, 1'b1, 8'hFF);

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
