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
        front="Front end", ren="Decode · rename · dispatch", exe="Schedule · execute",
        mem="Load / store · memory", cm="Commit",
        redirect="redirect (mispredict, trap, flush) · predictor training at commit",
        btb="BTB · RAS", ftq="fetch targets", ifu="I-cache · ITLB", ext="RVC expand · check",
        dec="× FETCH_W lanes", ren_s="RAT · free_list · checkpoints", dis="ROB / IQ / LQ / SQ entries",
        rob="reorder buffer", cmt="≤ COMMIT_W per cycle", wb="complete",
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
        front="フロントエンド", ren="デコード · リネーム · ディスパッチ", exe="スケジュール · 実行",
        mem="ロード / ストア · メモリ", cm="コミット",
        redirect="リダイレクト(分岐予測ミス、trap、flush) · コミット時の予測器学習",
        btb="BTB · RAS", ftq="フェッチターゲット", ifu="I-cache · ITLB", ext="RVC 展開 · 検査",
        dec="× FETCH_W レーン", ren_s="RAT · free_list · チェックポイント", dis="ROB / IQ / LQ / SQ を確保",
        rob="リオーダバッファ", cmt="1 サイクル最大 COMMIT_W 個", wb="完了",
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
    b = '<g transform="translate(0,40)">'
    b += grp(20, 0, 700, 100, "front", t["front"], True)
    b += grp(20, 130, 700, 100, "ren", t["ren"], True)
    b += grp(20, 260, 700, 140, "exe", t["exe"], True)
    b += grp(20, 430, 700, 130, "mem", t["mem"], True)
    b += grp(750, 0, 230, 560, "cm", t["cm"])
    # redirect loop
    b += ar([(865, 34), (865, -16), (105, -16), (105, 34)])
    b += lab(485, -22, t["redirect"], "middle")
    # front end
    b += box(40, 34, 130, 50, "front", "bpu", t["btb"])
    b += box(210, 34, 130, 50, "front", "ftq", t["ftq"])
    b += box(380, 34, 140, 50, "front", "ifu", t["ifu"])
    b += box(560, 34, 140, 50, "front", "extract", t["ext"])
    b += ar([(170, 59), (210, 59)]) + ar([(340, 59), (380, 59)]) + ar([(520, 59), (560, 59)])
    b += ar([(630, 84), (630, 114), (130, 114), (130, 164)])
    # rename
    b += box(40, 164, 180, 50, "ren", "decode", t["dec"])
    b += box(260, 164, 180, 50, "ren", "rename", t["ren_s"])
    b += box(480, 164, 220, 50, "ren", "dispatch", t["dis"])
    b += ar([(220, 189), (260, 189)]) + ar([(440, 189), (480, 189)])
    b += ar([(700, 189), (770, 189)])
    b += ar([(590, 214), (590, 245), (115, 245), (115, 294)])
    # execute
    b += box(40, 294, 150, 90, "exe", "iq", "busy_table", "wb_resv")
    s = C["exe"][1]
    b += f'<rect class="box" x="230" y="294" width="290" height="90" rx="6" stroke="{s}"/>'
    b += '<text class="t" x="375" y="314" text-anchor="middle">exec_port × ISSUE_W</text>'
    for i, n in enumerate(["alu", "bru", "mul", "div", "sys"]):
        b += chip(242 + 54 * i, 326, 50, "exe", n)
    for i, n in enumerate(["fma", "fmisc", "fdiv"]):
        b += chip(242 + 66 * i, 354, 62, "exe", n)
    b += box(560, 294, 140, 50, "exe", "prf", t["int"])
    b += ar([(190, 339), (230, 339)])
    b += ar([(520, 319), (560, 319)], both=True)
    # memory
    b += box(40, 464, 170, 60, "mem", "mem_pipe × MEM_W", t["mp"])
    b += box(230, 464, 120, 60, "mem", "lq · sq", t["lsq"])
    b += box(370, 464, 90, 60, "mem", "sb", t["sb"])
    b += box(480, 464, 100, 60, "mem", "atomic_unit", "io_unit")
    b += box(600, 464, 100, 60, "mem", "dcache", t["dc"])
    b += ar([(180, 384), (180, 464)])
    b += ar([(210, 494), (230, 494)], both=True)
    b += ar([(650, 524), (650, 600)])
    b += lab(662, 594, t["l2"])
    # completion
    b += ar([(700, 319), (736, 319), (736, 205), (770, 205)])
    b += f'<path class="ln" d="M700,494 L736,494 L736,319"/>'
    b += lab(731, 420, t["wb"], "middle", -90)
    # commit column
    b += box(770, 34, 190, 50, "cm", "flush_ctrl", "kill · redirect")
    b += box(770, 164, 190, 50, "cm", "rob", t["rob"])
    b += box(770, 244, 190, 50, "cm", "commit", t["cmt"])
    b += box(770, 314, 90, 44, "cm", "trap_unit")
    b += box(870, 314, 90, 44, "cm", "csr")
    b += ar([(865, 214), (865, 244)])
    b += ar([(815, 294), (815, 314)]) + ar([(915, 294), (915, 314)])
    b += ar([(960, 269), (972, 269), (972, 59), (960, 59)])
    b += box(770, 400, 190, 76, "vu", "vector_unit · vrf", t["vu1"], t["vu2"])
    b += "</g>"
    return svg(1000, 660, b)


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
