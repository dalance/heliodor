# W2 core, 1 hart (mirrors spike64).
import heliodor_sim  # pylint: disable=import-error

class w2_n1(heliodor_sim.HeliodorTarget):  # pylint: disable=invalid-name
    harts = [heliodor_sim.HeliodorHart(trig_n=2)]
    openocd_config_path = "../../openocd/heliodor-1.cfg"
