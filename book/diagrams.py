# Generate the block diagrams: python3 book/diagrams.py book/src/img
import sys, os

OUT = sys.argv[1]

STYLE = """<style>
text{font-family:-apple-system,"Segoe UI","Hiragino Sans","Noto Sans CJK JP",Meiryo,Helvetica,Arial,sans-serif;fill:#1f2933}
.grp{font-size:13px;font-weight:700}
.t{font-size:13px;font-weight:600;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.s{font-size:11px;fill:#52606d}
.chip{font-size:11px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.lab{font-size:11px;fill:#52606d;font-style:italic}
.box{fill:#fff;stroke-width:1.4}
.ln{fill:none;stroke:#3e4c59;stroke-width:1.4}
.dash{fill:none;stroke:#3e4c59;stroke-width:1.3;stroke-dasharray:5 4}
</style>
<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#3e4c59"/></marker></defs>"""

C = {
    "front": ("#e8f1fb", "#4a7fc1"),
    "ren": ("#eaf6e6", "#5a9a4a"),
    "exe": ("#f2ebfa", "#8a5cc1"),
    "mem": ("#fcf4dc", "#c19a2e"),
    "cm": ("#fdeee3", "#d4813a"),
    "vu": ("#eef0f2", "#7b8794"),
    "soc": ("#f7f9fb", "#7b8794"),
    "dbg": ("#fdeaea", "#c15050"),
}


def grp(x, y, w, h, k, label, right=False):
    f, s = C[k]
    tx, an = (x + w - 12, "end") if right else (x + 12, "start")
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{f}" stroke="{s}" stroke-width="1.4"/>'
            f'<text class="grp" x="{tx}" y="{y+19}" text-anchor="{an}" style="fill:{s}">{label}</text>')


def box(x, y, w, h, k, title, *subs):
    s = C[k][1]
    o = f'<rect class="box" x="{x}" y="{y}" width="{w}" height="{h}" rx="6" stroke="{s}"/>'
    n = 1 + len(subs)
    top = y + h / 2 - (n - 1) * 8 + 4
    o += f'<text class="t" x="{x+w/2}" y="{top}" text-anchor="middle">{title}</text>'
    for i, t in enumerate(subs):
        o += f'<text class="s" x="{x+w/2}" y="{top+16*(i+1)}" text-anchor="middle">{t}</text>'
    return o


def chip(x, y, w, k, t):
    f, s = C[k]
    return (f'<rect x="{x}" y="{y}" width="{w}" height="20" rx="4" fill="{f}" stroke="{s}" stroke-width="1"/>'
            f'<text class="chip" x="{x+w/2}" y="{y+14}" text-anchor="middle">{t}</text>')


def ar(pts, cls="ln", both=False):
    d = "M" + " L".join(f"{x},{y}" for x, y in pts)
    st = ' marker-start="url(#a)"' if both else ""
    return f'<path class="{cls}" d="{d}" marker-end="url(#a)"{st}/>'


def lab(x, y, t, anchor="start", rot=None):
    r = f' transform="rotate({rot} {x} {y})"' if rot is not None else ""
    return f'<text class="lab" x="{x}" y="{y}" text-anchor="{anchor}"{r}>{t}</text>'


def svg(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">'
            + STYLE + f'<rect width="{w}" height="{h}" fill="#fff"/>' + body + "</svg>\n")


L = {
    "en": dict(
        fetch="fetch · fetch buffer", l1i="L1I 32 KiB · ITLB", iqs="iq  (wakeup · select)  ·  busy_table  ·  wb_resv", prf="prf  (int · fp, read / bypass)", portnote="exec_port × ISSUE_W  (cfg_w4 shown)",
        front="Front end", ren="Decode · rename · dispatch", exe="Schedule · execute",
        mem="Load / store · memory", cm="Commit",
        redirect="redirect (mispredict, trap, flush) · predictor training at commit",
        btb="BTB · RAS", ftq="fetch targets", ifu="I-cache · ITLB", ext="RVC expand · check",
        dec="× FETCH_W lanes", ren_s="RAT · free_list · checkpoints", dis="ROB / IQ / LQ / SQ entries",
        rob="reorder buffer", cmt="≤ COMMIT_W per cycle", wb="write-back · complete",
        mp="AGU · DTLB · PMP/PMA", lsq="load / store queues", sb="store buffer",
        dc="L1D · PTW", l2="to L2 · mem_ctrl · AXI4 (in the SoC)",
        vu1="in order, decoupled", vu2="memory through pipe 0",
        int="int · fp",
        soc_harts="× N_HARTS (1, 2, 4, 8)", core="core (hart h)",
        l2s="128 KiB · coherence directory", mc="coherent home node",
        axi1="AXI4 master", axi2="DRAM · boot ROM",
        mb="memory_bus", mbs="device accesses", irq="timer · software · external interrupts",
        io="I/O", apb1="APB slave", apb2="(debugger)", dmi="DMI", sba="system bus access",
        dmem="debug memory", ext_irq="i_ext_irq_src", tx="UART tx",
    ),
    "ja": dict(
        fetch="フェッチ · バッファ", l1i="L1I 32 KiB · ITLB", iqs="iq (wakeup · select) · busy_table · wb_resv", prf="prf (int · fp、読み出し / バイパス)", portnote="exec_port × ISSUE_W (図は cfg_w4)",
        front="フロントエンド", ren="デコード · リネーム · ディスパッチ", exe="スケジュール · 実行",
        mem="ロード / ストア · メモリ", cm="コミット",
        redirect="リダイレクト(分岐予測ミス、trap、flush) · コミット時の予測器学習",
        btb="BTB · RAS", ftq="フェッチターゲット", ifu="I-cache · ITLB", ext="RVC 展開 · 検査",
        dec="× FETCH_W レーン", ren_s="RAT · free_list · チェックポイント", dis="ROB / IQ / LQ / SQ を確保",
        rob="リオーダバッファ", cmt="≤ COMMIT_W 個 / サイクル", wb="ライトバック · 完了",
        mp="AGU · DTLB · PMP/PMA", lsq="ロード / ストアキュー", sb="ストアバッファ",
        dc="L1D · PTW", l2="L2 · mem_ctrl · AXI4 へ(SoC 内)",
        vu1="インオーダ、分離型", vu2="メモリはパイプ 0 経由",
        int="int · fp",
        soc_harts="× N_HARTS (1, 2, 4, 8)", core="コア (hart h)",
        l2s="128 KiB · コヒーレンスディレクトリ", mc="コヒーレントなホームノード",
        axi1="AXI4 マスタ", axi2="DRAM · ブート ROM",
        mb="memory_bus", mbs="デバイスアクセス", irq="タイマ · ソフトウェア · 外部割り込み",
        io="I/O", apb1="APB スレーブ", apb2="(デバッガ)", dmi="DMI", sba="システムバスアクセス",
        dmem="デバッグメモリ", ext_irq="i_ext_irq_src", tx="UART tx",
    ),
}


def core(t):
    b = ""
    # groups
    b += grp(20, 50, 960, 140, "front", t["front"], True)
    b += grp(20, 220, 760, 100, "ren", t["ren"], True)
    b += grp(800, 220, 180, 250, "cm", t["cm"], True)
    b += grp(20, 350, 760, 320, "exe", t["exe"], True)
    b += grp(20, 700, 760, 130, "mem", t["mem"])
    # redirect
    b += ar([(890, 230), (890, 22), (115, 22), (115, 74)])
    b += lab(500, 16, t["redirect"], "middle")
    # front end
    b += box(40, 74, 150, 50, "front", "bpu", t["btb"])
    b += box(240, 74, 150, 50, "front", "ftq", t["ftq"])
    b += box(440, 74, 150, 50, "front", "ifu", t["fetch"])
    b += box(640, 74, 150, 50, "front", "extract", t["ext"])
    b += box(440, 138, 150, 40, "front", t["l1i"])
    b += ar([(190, 99), (240, 99)]) + ar([(390, 99), (440, 99)]) + ar([(590, 99), (640, 99)])
    b += ar([(515, 124), (515, 138)], both=True)
    b += ar([(715, 124), (715, 205), (130, 205), (130, 244)])
    # decode / rename / dispatch
    s = C["ren"][1]
    b += f'<rect class="box" x="40" y="244" width="250" height="56" rx="6" stroke="{s}"/>'
    b += '<text class="t" x="165" y="262" text-anchor="middle">decode</text>'
    for i in range(4):
        b += chip(52 + 58 * i, 272, 52, "ren", f"lane {i}" if i < 3 else "…")
    b += box(330, 244, 200, 56, "ren", "rename", t["ren_s"])
    b += box(570, 244, 190, 56, "ren", "dispatch", t["dis"])
    b += ar([(290, 272), (330, 272)]) + ar([(530, 272), (570, 272)])
    b += ar([(760, 272), (820, 272)])
    # commit column
    b += box(820, 250, 140, 44, "cm", "rob", t["rob"])
    b += box(820, 318, 140, 44, "cm", "commit", t["cmt"])
    b += box(820, 386, 66, 36, "cm", "trap")
    b += box(894, 386, 66, 36, "cm", "csr")
    b += box(820, 430, 140, 30, "cm", "flush_ctrl")
    b += ar([(890, 294), (890, 318)])
    b += ar([(853, 362), (853, 386)]) + ar([(927, 362), (927, 386)])
    # schedule / register read / execute
    b += box(40, 380, 720, 44, "exe", t["iqs"])
    b += ar([(665, 300), (665, 380)])
    b += box(40, 446, 720, 30, "exe", t["prf"])
    b += ar([(400, 424), (400, 446)])
    cols = [("P0", ["ALU", "BRU"]), ("P1", ["ALU", "BRU"]), ("P2", ["ALU", "MUL"]),
            ("P3", ["ALU", "SYS", "DIV"]), ("P4", ["FMA", "FMISC"]), ("P5", ["FMA", "FDIV"]),
            ("M0", ["AGU", "DTLB", "PMP"]), ("M1", ["AGU", "DTLB", "PMP"])]
    for i, (p, fus) in enumerate(cols):
        x = 40 + 92 * i
        k = "mem" if p[0] == "M" else "exe"
        sc = C[k][1]
        b += ar([(x + 40, 476), (x + 40, 498)])
        b += f'<rect class="box" x="{x}" y="498" width="80" height="112" rx="6" stroke="{sc}"/>'
        b += f'<text class="t" x="{x+40}" y="516" text-anchor="middle">{p}</text>'
        for j, f in enumerate(fus):
            b += chip(x + 8, 526 + 26 * j, 64, k, f)
        b += f'<path class="ln" d="M{x+40},610 L{x+40},632"/>'
    b += lab(40 + 92 * 3 + 40, 492 - 0, "", "middle")
    b += f'<text class="s" x="290" y="656" text-anchor="middle">{t["portnote"]}</text>'
    b += f'<text class="s" x="682" y="656" text-anchor="middle">mem_pipe × MEM_W</text>'
    b += f'<path class="ln" d="M80,632 L775,632"/>'
    b += lab(560, 627, t["wb"], "middle")
    b += ar([(775, 632), (790, 632), (790, 461), (760, 461)])
    b += ar([(790, 461), (790, 284), (820, 284)])
    # memory
    b += box(40, 754, 160, 56, "mem", "lq · sq", t["lsq"])
    b += box(220, 754, 120, 56, "mem", "sb", t["sb"])
    b += box(360, 754, 160, 56, "mem", "atomic_unit", "io_unit")
    b += box(540, 754, 220, 56, "mem", "dcache", t["dc"])
    b += '<path class="ln" d="M678,610 L678,736 M120,736 L678,736"/>'
    for x in (120, 280, 440, 650):
        b += ar([(x, 736), (x, 754)])
    b += ar([(650, 810), (650, 860)])
    b += lab(662, 852, t["l2"])
    # vector unit
    b += box(810, 498, 160, 112, "vu", "vector_unit", "vrf", t["vu1"], t["vu2"])
    return svg(1000, 880, b)


def soc(t):
    b = grp(120, 20, 760, 490, "soc", "heliodor_soc_smp")
    # harts
    for d in (16, 8):
        b += f'<rect x="{150+d}" y="{80+d}" width="200" height="100" rx="6" fill="#f2ebfa" stroke="#8a5cc1" stroke-width="1.2"/>'
    b += f'<rect class="box" x="150" y="80" width="200" height="100" rx="6" stroke="#8a5cc1"/>'
    b += '<text class="t" x="250" y="102" text-anchor="middle">' + t["core"] + "</text>"
    b += chip(160, 120, 56, "exe", "L1I 32K") + chip(222, 120, 56, "exe", "L1D 16K") + chip(284, 120, 56, "exe", "TLB")
    b += lab(270, 214, t["soc_harts"], "middle")
    # l2 / mem_ctrl
    b += box(430, 80, 200, 60, "mem", "l2cache", t["l2s"])
    b += box(430, 170, 200, 60, "mem", "mem_ctrl", t["mc"])
    b += ar([(366, 110), (430, 110)], both=True)
    b += ar([(530, 140), (530, 170)], both=True)
    b += ar([(630, 200), (960, 200)], both=True)
    b += f'<text class="t" x="890" y="190">{t["axi1"]}</text>'
    b += f'<text class="s" x="890" y="220">{t["axi2"]}</text>'
    # memory bus + devices
    b += box(430, 290, 140, 50, "front", "memory_bus", t["mbs"])
    b += ar([(250, 196), (250, 315), (430, 315)])
    b += lab(258, 300, t["io"])
    devs = [("CLINT", 262), ("PLIC", 306), ("UART", 350), (t["dmem"], 394)]
    for n, y in devs:
        b += box(700, y, 130, 34, "front", n)
        b += ar([(570, 315), (665, 315), (665, y + 17), (700, y + 17)])
    b += ar([(960, 330), (830, 330)])
    b += f'<text class="s" x="890" y="323">{t["ext_irq"]}</text>'
    b += ar([(830, 367), (960, 367)])
    b += f'<text class="s" x="890" y="360">{t["tx"]}</text>'
    b += f'<path class="dash" d="M765,262 L765,56 L250,56 L250,80" marker-end="url(#a)"/>'
    b += lab(508, 50, t["irq"], "middle")
    # debug
    b += box(150, 440, 100, 50, "dbg", "dmi_apb")
    b += box(280, 440, 100, 50, "dbg", "dm")
    b += box(430, 440, 200, 50, "dbg", "dm_sba", t["sba"])
    b += ar([(20, 465), (150, 465)])
    b += f'<text class="t" x="20" y="452">{t["apb1"]}</text>'
    b += f'<text class="s" x="20" y="485">{t["apb2"]}</text>'
    b += ar([(250, 465), (280, 465)]) + ar([(380, 465), (430, 465)])
    b += lab(265, 457, t["dmi"], "middle")
    b += ar([(600, 440), (600, 230)])
    b += f'<path class="dash" d="M830,314 L848,314 L848,56 L765,56"/>'
    return svg(1080, 530, b)


os.makedirs(OUT, exist_ok=True)
for lang, t in L.items():
    sfx = "" if lang == "en" else ".ja"
    open(f"{OUT}/core{sfx}.svg", "w").write(core(t))
    open(f"{OUT}/soc{sfx}.svg", "w").write(soc(t))
