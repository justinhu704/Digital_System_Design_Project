# Change this period when CLK_FREQ changes. 24 MHz = 41.666667 ns.
create_clock -name clk -period 41.666667 [get_ports {clk}]
derive_clock_uncertainty
