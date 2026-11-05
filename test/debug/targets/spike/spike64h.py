# spike64 with the H and V extensions and the new core's misa: the spike
# reference for the GG run after M5 (run_spike_ref.sh accepts this path).
import os

import targets  # pylint: disable=import-error
import testlib  # pylint: disable=import-error

RISCV = os.path.join(os.path.dirname(os.path.abspath(targets.__file__)), "targets", "RISC-V")


class spike64h_hart(targets.Hart):  # pylint: disable=invalid-name
    xlen = 64
    ram = 0x1212340000
    ram_size = 0x10000000
    bad_address = ram - 8
    instruction_hardware_breakpoint_count = 4
    reset_vectors = [0x1000]
    link_script_path = os.path.join(RISCV, "spike64.lds")
    misa = 0x80000000003411ad


class spike64h(targets.Target):  # pylint: disable=invalid-name
    harts = [spike64h_hart()]
    openocd_config_path = os.path.join(RISCV, "spike-1.cfg")
    timeout_sec = 180
    implements_custom_test = True
    support_unavailable_control = True

    def create(self):
        return testlib.Spike(self, isa="RV64IMAFDCVH", progbufsize=0,
                             abstract_rti=30, support_abstract_csr=True,
                             support_abstract_fpr=True)
