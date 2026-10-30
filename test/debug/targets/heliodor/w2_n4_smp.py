# W2 core, 4 harts as one OpenOCD SMP target, each hart a hwthread
# (mirrors spike64-2-hwthread).
import heliodor_sim  # pylint: disable=import-error

class w2_n4_smp(heliodor_sim.HeliodorTarget):  # pylint: disable=invalid-name
    harts = [heliodor_sim.HeliodorHart(trig_n=2) for _ in range(4)]
    openocd_config_path = "../../openocd/heliodor-4-hwthread.cfg"
    build_name = "w2_n4"
    # The 4-hart simulator runs at about 2k cycles/s, ten times slower than
    # the 1-hart one.
    timeout_sec = 1200
