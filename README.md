# axi4-write-back-cache

[![simulation](https://github.com/me-in-git/axi4-write-back-cache/actions/workflows/sim.yml/badge.svg)](https://github.com/me-in-git/axi4-write-back-cache/actions/workflows/sim.yml)

4-way set-associative write-back / write-allocate cache in SystemVerilog with an AXI4 master port.

- 64 sets, 16-byte lines (4 KiB)
- tree pseudo-LRU, invalid ways filled first
- dirty victims written back as a 4-beat INCR burst, refills are 4-beat INCR reads
- blocking: one request at a time

`rtl/axi_ram_slave.sv` is a simple AXI4 memory model for simulation.

## Tests

```
make test      # needs icarus verilog 12+
```

The testbench first runs directed checks: fill a set, make sure nothing is evicted while a way is free, force an eviction of the LRU dirty line and check memory after the write-back. Then 2000 random reads/writes over 3 sets x 6 tags (so lines keep getting evicted) are checked against a software copy of memory. A monitor also checks that ARVALID drops after the address handshake.

```
PASS: 4 lines in a 4-way set: no write-back
PASS: exactly one write-back burst
PASS: dirty line written back @0x1004
PASS: re-read evicted line @0x1004 from memory
random phase: 976 reads, 1024 writes, 1348 hits, 496 write-backs
PASS: random phase: every read matched the memory model
=== CACHE_TEST: 0 error(s) ===
```

## Not done yet

- byte-enable writes from the CPU side
- AXI error responses
- synthesis
