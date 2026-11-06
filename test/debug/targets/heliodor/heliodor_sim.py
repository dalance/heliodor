"""gdbserver.py targets for the heliodor SoC on Verilator (sim/verilator/tb_soc_dm.sv).

The target classes mirror the riscv-tests spike64 / spike64-2 targets: the
simulator is started per test by create(), listens for OpenOCD's
remote_bitbang connection and ends when OpenOCD quits, after dumping the
firing counters into its log.

Environment:
  HELIODOR_ROOT         repository root (default: three levels up)
  HELIODOR_GG_BUILD     Verilator build directory holding tb_soc_dm
                        (default: sim/verilator/build_dm_<build_name>)
  HELIODOR_GG_LOGDIR    where the simulator logs are kept (default: a temp dir)
  HELIODOR_CMD_TIMEOUT  OpenOCD's RISC-V command timeout, seconds (default 300)
  HELIODOR_GG_TIMEOUT   overrides the target's timeout_sec
"""

import os
import re
import subprocess
import tempfile
import time

import targets  # pylint: disable=import-error
import testlib  # pylint: disable=import-error

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("HELIODOR_ROOT",
                      os.path.abspath(os.path.join(HERE, "..", "..", "..", "..")))

# misa of the new core (RV64 IMAFDC, B, H, V, S, U), read from the hardware.
MISA = 0x80000000003411af


class HeliodorHart(targets.Hart):
    xlen = 64
    ram = 0x80000000
    ram_size = 0x2000000
    bad_address = ram - 8
    reset_vectors = [0x0]
    link_script_path = "heliodor.lds"
    misa = MISA

    def __init__(self, trig_n, **kwargs):
        super().__init__(**kwargs)
        self.instruction_hardware_breakpoint_count = trig_n


class HeliodorSim:
    """One simulator process; owns it and stops it by its saved pid."""

    def __init__(self, target):
        build = os.environ.get("HELIODOR_GG_BUILD",
                               os.path.join(ROOT, "sim", "verilator", "build_dm_" + target.build_name))
        binary = os.path.join(build, "tb_soc_dm")
        logdir = os.environ.get("HELIODOR_GG_LOGDIR") or tempfile.mkdtemp(prefix="heliodor-gg-")
        os.makedirs(logdir, exist_ok=True)
        self.logname = os.path.join(logdir, f"sim-{os.getpid()}-{time.time_ns()}.log")
        self.lognames = [self.logname]
        # pylint: disable-next=consider-using-with
        self.logfile = open(self.logname, "w", encoding="utf-8")
        self.logfile.write(f"+ {binary}\n")
        self.logfile.flush()
        # pylint: disable-next=consider-using-with
        self.process = subprocess.Popen([binary], cwd=ROOT, stdin=subprocess.DEVNULL,
                                        stdout=self.logfile, stderr=subprocess.STDOUT)
        port = None
        for _ in range(600):
            with open(self.logname, encoding="utf-8", errors="ignore") as fd:
                m = re.search(r"Listening for remote bitbang connection on port (\d+)\.",
                              fd.read())
            if m:
                port = m.group(1)
                break
            if self.process.poll() is not None:
                break
            time.sleep(0.1)
        if not port:
            testlib.print_log(self.logname)
            raise testlib.TestLibError("heliodor simulator did not open its remote_bitbang port")
        os.environ["REMOTE_BITBANG_HOST"] = "localhost"
        os.environ["REMOTE_BITBANG_PORT"] = port
        os.environ["WORK_AREA"] = f"0x{target.harts[0].ram:x}"
        os.environ.setdefault("HELIODOR_CMD_TIMEOUT", "300")

    def __del__(self):
        # The simulator dumps its counters and exits once OpenOCD has quit;
        # give it that time before stopping it.
        try:
            self.process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        except (OSError, AttributeError):
            pass

    def wait(self, *args, **kwargs):
        return self.process.wait(*args, **kwargs)


class HeliodorTarget(targets.Target):
    # The Verilator build (sim/verilator/build_dm_<build_name>), the target
    # name unless two targets share a build.
    build_name = None
    # Seconds per gdb operation (remotetimeout, and the suite's per-command
    # timeout is a multiple of it). At about 20k cycles/s a 13 KB memory write
    # packet (the largest gdb sends) takes about 42 s through the program
    # buffer, and DownloadTest's continue (20 operations) runs a bitwise CRC
    # of 256 KiB compiled at -O0: on W2 it retired 77M instructions in 203M
    # cycles, about 2 h 45 min for the whole test.
    timeout_sec = 600
    server_timeout_sec = 600
    implements_custom_test = False
    support_unavailable_control = False
    # mcontrol6 and icount only (no legacy mcontrol, itrigger or etrigger).
    support_mcontrol = False
    support_itrigger = False
    support_etrigger = False
    freertos_binary = None

    def __init__(self, path, parsed):
        super().__init__(path, parsed)
        if os.environ.get("HELIODOR_GG_TIMEOUT"):
            self.timeout_sec = int(os.environ["HELIODOR_GG_TIMEOUT"])

    def create(self):
        if not self.build_name:
            self.build_name = self.name
        return HeliodorSim(self)
