# W2 core, 4 harts, one OpenOCD target and gdb per hart (mirrors spike64-2).
import heliodor_sim  # pylint: disable=import-error

class w2_n4(heliodor_sim.HeliodorTarget):  # pylint: disable=invalid-name
    harts = [heliodor_sim.HeliodorHart(trig_n=2) for _ in range(4)]
    openocd_config_path = "../../openocd/heliodor-4.cfg"
    # The 4-hart simulator runs at about 2k cycles/s, ten times slower than
    # the 1-hart one.
    timeout_sec = 1200
