# Phase 15 新コア設計書

## 目次

- 第 0 部: 位置づけ・目標・構成・横断契約
- 1. 文書の位置づけ
- 2. 目標・非目標・成功基準
- 3. 支援構成とパラメータ軸
- 4. 全体構造
- 5. 横断契約
- §F フロントエンド
- §R decode・rename・dispatch
- §X スケジューラと実行
- §C ROB・commit・トラップ・CSR
- §L LSU・LSQ・アトミック・I/O
- §M dcache/MMU の CPU 側・TLB・PTW・PMP/PMA
- §S SoC とプラットフォーム
- §V ベクトルユニットの統合
- リスクと未決事項
- マイルストーン計画
- 付録: 旧コアの経緯と防ぐバグ類

---

## 第 0 部: 位置づけ・目標・構成・横断契約

本書は `doc/phase15_core_design.md` の第 0 部であり、他のすべての章が従う契約を定める。他章は本書に反する設計を書いてはならない。反する必要が生じた場合は、先に本書を改訂する。旧コアの行番号はすべて凍結コミット `b0f4668` のものである。

---

## 1. 文書の位置づけ

### 1.1 目的と読者

- 目的: Phase 15 で新しく設計するコアパイプライン (front end, rename, scheduler, ROB, LSQ, 実行部の配線) と、再構築する dcache/MMU の CPU 側ポート構造について、全章に共通する型・識別子・プロトコル・規約を一か所で確定させる。
- 読者: プロセッサアーキテクトで、heliodor の経緯を知らない人を想定する。OoO の一般論は書かない。書くのは、この設計に固有の選択とその理由だけである。
- 旧コアへの参照 (`file:line`, commit) は根拠として使う。ただし本書は旧コアを読まなくても理解できるように書く。

### 1.2 マークの読み方

| マーク | 意味 |
|---|---|
| 【決定】 | 決定済み。理由を 1 行で添える。 |
| 【M<n> で決定】 | マイルストーン M<n> で決める。何を測って決めるかを明記する。それまでの暫定値がある場合は併記する。 |
| 【要判断】 | ユーザの判断が必要。選択肢と推奨を併記する。本書では極力使わない。 |
| 無印 | 契約 (レビューで検査できる不変条件) または事実。 |

契約は「X は Y の前に必ず Z」の形で書き、その契約を守る責任を負うモジュール (所有者) を明記する。

### 1.3 関連文書と章ラベル

| 文書 | 内容 |
|---|---|
| `doc/phase15_core_design.md` | 設計本文。本書はその第 0 部。 |
| `doc/phase15_verification_plan.md` | golden モデル (D1)、割込み replay (D2)、ハーネスの載せ替え (D3)、trace diff と allow-list (D4)、ゲート表。 |
| `doc/phase15_old_core_inventory.md` | 旧コアの概念インベントリ (行範囲付き)。移植元を探すときの索引。 |

【決定】本文の章ラベルを次のように固定し、所有者の表示に使う。理由: 他章の起草者が相互参照に使う安定した名前が必要なため。

| ラベル | 範囲 |
|---|---|
| §0 | 本書 (横断契約) |
| §F | フロントエンド (BPU, FTQ, fetch, extract, icache CPU 側) |
| §R | decode, rename, dispatch |
| §X | スケジューラ (IQ, busy table, WB 予約) と実行部 (FU, PRF, bypass) |
| §L | LSU と LSQ (memory pipe, LQ, SQ, SB, atomic_unit, io_unit, ポート調停) |
| §M | dcache/MMU の CPU 側、TLB, PTW, PMP, PMA |
| §C | ROB, commit, trap, flush 制御, CSR 接続 |
| §V | ベクトルユニットの統合 (M5) |
| §S | SoC とプラットフォーム (CLINT, PLIC, UART, L2, mem_ctrl) |

### 1.4 M0 でのユーザ決定 (2026-10-11 と 10-12, 拘束力あり)

| ID | 決定内容 |
|---|---|
| D1 | golden モデル = `b0f4668` + 観測専用パッチ。パッチの中身は、lane ごとの RVFI 風 retire adapter、CLINT の `i_tick` 入力、割込みスケジュールの printer。パッチは専用ブランチに置き、veryl を `fbd14729` に固定した別 worktree でビルドする。受入条件: 既定パラメータで dhrystone/coremark の cycles と instret が、パッチ前の `b0f4668` とビット一致すること。パッチを変更したら、golden 成果物をすべて再生成する。 |
| D2 | 割込みの lockstep は schedule replay で行う。golden は自由走行し、割込みごとに (retire 順位, cause) を出力する。新コアはデバッグ入力 (retire limit, irq allow/mask) でそのスケジュールを再生し、その cause が自コアでも実際に pending であることを assert する。新コア自身は flush-at-head で割込みを受け付け、pending は 1 サイクル登録してから使う。WFI は両コアとも NOP (lockstep モード)。 |
| D3 | bare flat-memory ハーネス (arch suite, ACT4, bench: 約 936 テスト) を、パラメータ化した 1 つの SoC に載せ替える。`heliodor_soc` を `heliodor_soc_smp` に統合し、`N_HARTS>=1`、tb DRAM、PMA map をパラメータとする。pass は retire port (tohost への store、x3 への書き込み) から検出し、早期終了する。まず約 20 テストで時間を測り、遅すぎれば mem_ctrl の accept + 8-beat プロトコルを話す flat-memory slot adapter に切り替える。新コアの外部メモリプロトコルは 1 つだけとし、ID_SPLIT/COHERENT_IFETCH/PMA_FAULT のような knob も、tohost の write-through 窓も持たない。 |
| D4 | 旧コアの仕様逸脱について: 新コアはアーキテクチャ的に正しく作る。既知の差異は trace diff の allow-list (MASK/allowlist タグ) で吸収する。lockstep の対象は 5.15 N=1 boot (ADUE off) とし、7.1+ADUE と SMP は pass/fail のみで判定する。推定段階の旧コアバグは、M2 の前に golden 上の directed test で確認する。 |
| D5 | LSQ は新規設計とし、旧コアのアルゴリズムを移植する。新しいパラメータ化モジュールとして LQ/SQ/SB を作り、PA 完全一致比較、CoRR の line scan、SB の line write-combining、drain shadow、ordering-empty と resource-empty の区別を移植する。store は execute で翻訳し、forwarding 網は PA キーの 1 つだけとする。順序違反の回復はまず commit 時 replay で行い、依存予測器は持たない。atomics は M4 まで既存方式のまま、独立した `atomic_unit` に置く。 |
| D6 | M6 まで master 上で旧コアと共存させる。旧コアの private モジュールは今すぐ機械的に改名し (prefix `v14_`)、新コアは最終名を使う。SoC には `CORE` パラメータを設け、generate-if で切り替える。M6 で行うのは旧コアの削除だけ。 |
| D7 | 支援構成は 2-2-2-1-2 と 4-4-6-2-4 (fetch/decode - rename/dispatch - issue - memory ports - commit)。N=4 で生じる per-hart シミュレーション速度の約 8 倍の崖 (N=4 boot 4408 s) は M3 までに原因を特定し、その結果を見て N=4 boot ゲートを両構成で回すかを決める。 |
| D8 (2026-10-12) | AMO/SC は §L L.11 の方式 B とする。op は最古のまま LOAD_EXCL → 演算 → STORE_EXCL を連続して行い、rd は PASS の後にだけ書く。FAIL または watch の hit は `atomic_unit` の内部で、hart id 全体を seed にした backoff 付きで再試行する。SC の rd は PASS で 0、FAIL で 1。dcache 契約と D5 の待ち行列方式は変えない。帰結: REPLAY の発生源は `lq` だけになる (§5.12 C7)。 |

D3 の補足: D3 の載せ替えは新コアに適用する。新コアのハーネスの arm は統合 SoC の上に載せ替える。V14 の arm は M6 まで旧来の bare ハーネス本体をそのまま保つ。理由: D6 の共存と、`v14_` 改名のビット一致受入 (§4.4) に必要なため。

運用 (採用済み): 2 つの構成は、別々の git worktree で並行に回す (worktree ごとに `.build` を持つ。veryl は 1 つの木で同時に 1 起動しか許さないため)。

注 (D7): 崖の倍率そのものが測定ごとに食い違っている。約 8 倍という値は、N=4 boot の 4408 s (2026-08-05 の実測) を、測定日のない N=2 の壁時間と比べたものである。`.build/test_timings` の値 (N=4 3793.2 s、検証計画 §6.1) を hart-cycle あたりに直すと約 2.7 倍であり、2026-06-11 に同じ木で直列に測った値 (251k/118k/50.6k cy/s) はほぼ線形だった。したがって M3 の最初の作業は、同一の木・同一のマシンで `VERYL_AOT_C_ASYNC=0` として N=1/2/4 を直列に matched 測定することである。原因の特定はその後に行う。

### 1.5 既に承認済みの原則

| 区分 | 内容 |
|---|---|
| 目標 1 (同格) | パラメータ化: fetch/decode 幅、rename/dispatch 幅、issue 幅と FU/IQ トポロジ、メモリポート数、commit 幅を最初からパラメータにする。サイズの参照は所有モジュール内に閉じ、外に漏れるのはタグ幅だけ (1 つのパッケージと 1 つの wrap/age helper 経由)。段の追加は局所変更で済むこと。 |
| 目標 2 (同格) | モジュラリティ: 1 概念 = 1 モジュール。top は配線のみ。予測器と FU は契約の背後で差し替え可能にする。 |
| 目標 3 (同格) | 第三者のアーキテクトが読める: 標準用語を使う。OoO の解説は書かない。コメントは設計固有の理由だけ。bit knob を持たない (実験はブランチで行う)。lane は一様な for-generate で書き、slot ごとの特例を作らない。各モジュールの先頭にポートのタイミング契約を書く。命名規約 (段 prefix, `_q`, valid/ready) に従う。 |
| 非目標 | 旧コアとの性能パリティ。代わりに構造的な伸びしろを求める: 天井はすべてパラメータであり、幅・ポート数・窓の sweep で IPC が期待どおりの方向に動くこと。 |
| 深さ規則 1 | FU はレイテンシをパラメータとして公表し、スケジューラはそれだけを見る。 |
| 深さ規則 2 | 各 writeback ポートを予約制にするか調停制にするかは設計時に決める。 |
| 深さ規則 3 | op の識別子は op と一緒に運ぶ。ROB head のような生きた状態から読まない。 |
| マイルストーン | M0 設計文書 → M1 walking skeleton (最終構造 + 最も単純な policy, rv64ui の trace 一致。M0 のレビューで M1a 基盤と M1b 歩く骨格に分けた、§2.5) → M2 スカラ ISA 全体 (arch suite, ACT4, 1-hart Linux lockstep) → M3 幅とポート (2-2-2-1-2 → 4-4-6-2-4, dcache/MMU 2 ポート, sweep) → M4 SMP → M5 H/V → M6 既定コアの切替。 |
| 再利用 | dcache/MMU は内部ロジックを再利用し、CPU 側を N ポートで作り直す (インタフェースは最初から N ポート、実装は M1-M2 で 1 ポート、M3 で 2 ポート)。ロジックとして再利用するもの: L2/coherence/mem_ctrl/bus, CSR, FPU, VU, decoder, 周辺, パッケージ, 検証資産。 |
| golden | `b0f4668`。mtime を retire 命令数で進めるモードと、RVFI 寄せの retire ポートを使う (具体化は D1/D2)。 |

### 1.6 用語集

本書に固有の語だけを挙げる。標準語彙 (§2.3 R1) は挙げない。

| 語 | 意味 | 定義箇所 |
|---|---|---|
| lane、group (rename group、commit group) | 1 サイクルに並んで処理される op の位置と、その並び。lane 0 から連続して有効である。 | §5.3 R3、§5.12 |
| take | dispatch が 1 サイクルに受理する lane 数。lane `0..take-1` を受け取り、残りは入口のキューに残る。 | §5.3 R4、§R.5.2 |
| oldest token | ROB が出す `{valid, tag}`。最古の未 retire op のタグで、割込み pending などのときは valid=0。取り消せない操作を始めてよいという許可であり、識別子ではない。 | §5.12、§5.13 I5 |
| started latch、`head_started_q` | 取り消せない操作を始めた unit が立てる実行許可の latch と、その OR を commit が登録したもの。立っている間は割込みを受け付けない。 | §5.13.1 |
| nonspec、alone、drain、`ld_barrier` | OpClass の直列化属性: token を要する、commit group に単独で入る、`ordering_empty` を待って retire する、より若い load を止める。 | §5.5 |
| 部分 kill (partial)、full kill | keep より若い op だけを殺す kill / すべての in-flight op を殺す kill。 | §5.4 |
| keep | 部分 kill で生き残る最も若い op (分岐自身)。 | §5.4 |
| dispatch snapshot | 部分 kill の巻き戻し先として、op を割り当てた直後のリングの位置を `rob` が ROB index ごとに保持したもの。 | §5.4 T6、§C.1.6 |
| walk | 部分 kill の後、殺された op の `old_pdst` を若い順に投機 RAT へ書き戻して写像を戻す手順。 | §R.3.4、§C.1.5 |
| resolve record、`recovered` | control op の WB が ROB に書く `{mispred, taken, next_pc}` / その分岐で部分 kill を採用済みである印。 | §5.4 T8、§C.1.4 |
| commit backstop | commit 時に `mispred && !recovered` の control op を retire させて full kill をかける検査 (T8)。早期 kill を捨てても正しさを保つ。 | §5.4 T8 |
| `BR` / `BR_CM` | BRU の resolve による部分 kill / commit 時の検査 (T8) による full kill。 | §5.4、§C.4 |
| outcome、RETIRE_FLUSH | commit の group 関数が lane ごとに出す判定 `{WAIT, RETIRE, RETIRE_FLUSH, TRAP, REPLAY}` / retire したうえで若い op を full kill する outcome。 | §5.12、§C.2.2 |
| commit 窓 | `lq`/`sq` が最古のエントリについて登録済みで出す窓。commit の lane は自分のタグとの等値比較でエントリを選ぶ。 | §C.1.1 |
| RESERVED、HOLE_FILL | WB 枠を issue 時に予約する方式 / 結果を保持して予約表の空きに入れる方式。 | §5.7 |
| `wb<p>`、`wbm<p>` | 実行ポート p の WB ポート / memory pipe p の WB ポート。 | §5.7 |
| slot token | `mem_port_arb` が非 pipe の要求者に与えた m0 の slot の権利。m0 から m2 へ流れ、m2 に達したサイクルに勝者が要求を出す。 | §5.9 MP3、§L.14 |
| 要求者クラス | `mem_port_arb` が slot を割り当てる単位 (NEW、LQ、SQ、HEAD、PTW、AD、ASQ)。HEAD は oldest token か started latch を持つ op の要求。 | §L.14 |
| `ordering_empty`、`resource_empty` | 順序を待つ側が読む述語 (commit 済み store がすべて可視で atomic の待ち行列も空) / drain の要否だけを表す述語。 | §5.9 MP7、§L.8 |
| Stage A、Stage B | 再利用 dcache の受理サイクル (登録読みの提示) と、その次の判定サイクル。 | §M.2.1 |
| fold 群、nf 群 | 再利用 dcache の Stage-A 折り返し読みに乗る要求 (LOAD、PTW_READ) / 乗れない要求 (排他、write-through、uncached)。 | §M.2.1 |
| A 位置、B 位置 (slot A/B) | adapter の物理経路の 2 つの位置。A は受理サイクルの Stage-A 提示、B は主ポートを駆動している保持 slot。 | §M.2.1 |
| HOLD | adapter が slot を保持したまま MISS を返し、fill の開始か hit を待つ状態。 | §M.2.4 |
| attach | 進行中の同じ line の fill に要求を相乗りさせ、その fill の `fill_id` で MISS を返すこと。 | §M.2.3 |
| `fill_id`、`gen_q` | fill の帰属を決める ID と、adapter がそれを採番する世代カウンタ。 | §5.9 MP2、§M.2.5 |
| 空の世代 | HOLD した slot が fill を伴わずに hit で終わったとき、adapter が進める `gen_q` の世代。その世代の `FILL_ABORT` で park した要求者を再 issue させる。 | §M.2.4 |
| D read slot、I read slot | mem_ctrl が hart ごとに持つ D 側と I 側の読み出し slot (accept + 8-beat STREAM、非 DRAM は single-beat)。 | §4.5、§S.3 |
| epoch | full kill と sfence で進む `ptw` の世代。一致しない walk は TLB に install しない。 | §5.10 X2 |
| STA、STD | store のアドレス部 (PA、mask、属性、例外) と、データ部の SQ への書き込み。 | §L.4 |
| `seen`、poison | load が forward の snapshot を取った印 / 順序違反で commit 時 REPLAY が要る印。 | §L.6 |
| store-resolve scan、CoRR line scan | STA を書いた次のサイクルに、その store と重なる snapshot 済みの若い load を poison する走査 / inv、inv2、evict の line と一致する snapshot 済みの load を poison する走査。 | §L.6 |
| PARK(理由)、再 issue | LQ/SQ のエントリが event を待つ状態 (理由は FILL、BUSY、XLATE、SQ、AQ、HEAD、DBIT) / 待ちが解けたエントリを m0 から入れ直すこと。 | §L.7 |
| drain shadow | drain の ack の後 `SHADOW_LEN` サイクルの間、pop したエントリを forward 網に見せ続ける仕組み。 | §5.9 MP7、§L.8 |
| watch、pin | `atomic_unit` が読み出しから書き込みまで対象 line の inv/evict を監視すること / 所有権付きの読み出しの後、dcache が remote の probe を最大 64 サイクル延期すること。 | §L.11 |
| queued atomic (ASQ) | rd=x0 の RMW を retire 後に深さ 1 の待ち行列で実行する方式。採否は M4 で決める。 | §L.11 |
| fetch block、`foff` | FTQ の 1 エントリが表す、`start_pc` から始まり予測 exit か整列境界で終わる命令列 / block 内の halfword offset。op は PC の代わりに `(ftq, foff)` を運ぶ。 | §F.3 |
| carry、straddle | fetch block の末尾をまたぐ 32 bit 命令と、その下半分を次の block まで持ち越す extract の状態。 | §F.7 |
| deliver, don't follow | producer (bpu) は予測を配るだけで、consumer (extract) が実際の命令境界と照合する方針。 | §F.1 F-P2 |
| exec 境界 | VU が実行を始めてよい境界。M5 では oldest token に等しい。 | §V.3 VA2 |
| knob | 挙動を切り替える `bit` の `const`/`param`。新コアは持たない。 | §2.1 P4 |
| DEAD scaffolding | const で守られた arm、値を読まれない計測用カウンタ、使われない予約状態。新コアは持たない。 | §5.15 |
| cold-reader gate | プロジェクトに関わっていないレビュアが、ヘッダと本書だけでモジュールを説明できるかを確かめるゲート。 | §5.15 |
| whole-comb fallback | Veryl の cc backend が組合せ論理を一括で評価できず、遅い評価経路に落ちること。`VERYL_AOT_C_DIAG=1` で数える。 | §3.7、§5.15 |
| sweep、census | 1 軸だけを変えて IPC を測ること / 機構ごとに事象の母集団と内訳を数える計測。 | §2.5、§L.17 |
| golden、V14、W2/W4 (`cfg_w2`/`cfg_w4`) | 観測パッチを当てた `b0f4668` / master 上の改名済み旧コア / 新コアの 2 構成。 | §1.4 D1、§3.2、検証計画の用語 |
| lockstep、trace diff、allow-list | retire record の列を golden と比べる検証と、その比較で吸収する既知の差異の表。 | §1.4 D2/D4、検証計画 |
| ゲートの梯子、ゲート ID (G0、GA、GL-A..GL-C、GB1/GB2/GB4、GT4、GH、GX、GV、GS、GF) | マイルストーンごとに通すテスト群の列と、その個々の名前。V14 の梯子 1-5 は CLAUDE.md の回帰の手順。 | 検証計画 §1 |
| N2.2a | 旧コアで grant の前に MSHR エントリを確保した実験 (MSHR ALLOC)。N=1 のビット一致を保ったまま N=4 boot を livelock させ、撤回した。 | §M.6.1、付録 |
| LSR | 旧コアで dcache の主ポートを占有して load を 1 本保持していたレジスタ。旧コアとの比較にだけ現れる。 | 付録 |

---

## 2. 目標・非目標・成功基準

### 2.1 パラメータ化 (検査項目)

- P1. 5 軸と構造サイズの出所は config パッケージ (§3.6) ただ 1 つ。【決定】理由: 旧コアは ROB_DEPTH が `pipeline_pkg.veryl:29` と `decode_pkg.veryl:32` に重複し (その幅 `ROB_IDX_W` も `:30` と `:33` に手書きで重複)、さらにモジュール既定値とインスタンス側のリテラルにも散っていた。
- P2. サイズ定数 (例: `ROB_N`) を参照してよいのは、所有モジュールと `core_types` だけ。他のモジュールはタグ型 (`RobTag` など) と `tag_pkg` の helper だけを使う。レビューでは grep で検査する。
- P3. 段の追加は局所変更である。段境界はすべて `lane_queue` か `stage_reg` (§5.3) で作る。段を 1 つ追加して変わるのは、両隣のモジュールと、その経路のレイテンシを公表する定数 1 つだけ。
- P4. 新コアには挙動を切り替える `const`/`param ...: bit` が 1 つも無い。【決定】理由: 旧コアには bit knob が 62 個あり (`heliodor_core.veryl` の `const/param X: bit` 宣言を grep した数)、使わない側の arm が腐り、knob の組が二重化して同期が外れた。実験はブランチで行う。FU レイテンシのように値を取るパラメータは knob ではなく、`fu_pkg` に 1 か所だけ置く。モジュール境界を越えて公表するレイテンシ (FU、`RESP_LAT`、`IC_RESP_LAT`、`ITLB_LAT`、`LD_LAT`、`FWD_SKEW` など) はすべて `fu_pkg` にあり、他の場所には置かない。bpu 内部の部品レイテンシは bpu の外から見えないので `bpu_pkg` に置く (§3.6)。
- P5. P4 と cold-reader gate (§5.15) が適用されるのは新規モジュールである。再利用モジュール (例: `vector_unit` 内部の bit パラメータ) は、ゲートの対象に取り込まれるまで免除する。新コアは、それらのパラメータを instantiate 時に固定値で束縛する (例: `MEM_PIPE=0`)。
- P5a. CPU 側を作り直す再利用モジュール (M1b の `icache`、M3 の `dcache`) では、作り直した CPU 側を新規モジュールとして書き、再利用する内部 (fill FSM、tag/data 配列、coherence) はその子として instantiate する。【決定】CPU 側の wrapper には新規モジュールの規則 (knob 0 個、§5.15 のヘッダ、600 行の目安、cold-reader gate) をすべて適用し、子の内部は P5 で免除する。理由: 免除の境界がモジュール境界と一致し、レビューで機械的に判定できる。内部に残る bit const (例: `icache.veryl:732` の `ICACHE_SYNC_READ`) は、子の instantiate 時に固定値で束縛する。

### 2.2 モジュラリティ (検査項目)

- M1. 1 概念 = 1 モジュール。正となる一覧は §4.2。
- M2. core top (`heliodor_core`) は配線だけで作る。中身は `inst` と接続、struct フィールドの詰め替え、lane 配列の連結に限り、`always_comb`、`always_ff`、算術・論理演算を含めない。【決定】理由: synth は 64K cell を超えるモジュールでは depth の再構成を止める。その結果、top に置いた論理だけが ripple のまま残る。
- M3. 予測器は predict/update/recover 契約 (§F) の背後に、FU は §5.6 の契約の背後に置く。差し替えても他のモジュールは変更しない。
- M4. モジュールの行数は、ヘッダコメントを除いて 600 行以下を目安とする。【決定】超える場合は、分割できない理由をレビュアが確認してから受け入れる。理由: 旧コアは 13,315 行の 1 モジュールに概念が混在しており、それが読めなさの主因だった。

### 2.3 可読性 (検査項目)

- R1. 用語は標準語彙 (ROB, IQ, LQ, SQ, SB, FTQ, PRF, RAT, MSHR, TLB, PTW, wakeup, select, retire, commit, flush, kill) を使う。独自語は §5 で定義したものに限る。
- R2. すべてのモジュールの先頭に、ポートのタイミング契約 (§5.15 の書式) を書く。
- R3. コメントは英語で書き、設計固有の理由と非自明な制約だけを書く。経緯、計画書・issue・commit への参照、陳腐化する数値は書かない。
- R4. lane やポートを添字とする論理は、1 つの for-generate 本体で書く。lane 番号による特例 (`if l == 0` など) は書かない。差異が必要なら capability 定数配列で表す。commit の「group 先頭」規則 (§5.12) は lane 番号ではなく順序上の性質として定義するので、この規則の例外にはあたらない。
- R5. 命名は §5.15 に従う。
- R6. 新規モジュールは cold-reader gate (§5.15) を通る (再利用モジュールの扱いは P5)。

### 2.4 構造的伸びしろ

- 天井はすべて、パラメータであるか、§3.4 の「宣言された上限」表に載っているかのどちらかでなければならない。表に無い隠れた天井はバグとして扱う。
- 【決定】機構を選ぶときは、測定済みの天井で判断する。理由: 旧コアで実測された利得の大半は構造から来ていた (幅と L1I 容量で boot -7 %、load pipe の解放で -6 %、I/D チャネルの分離)。一方、依存予測 (天井 0.13 %) と MLP (天井 1.26 %) は小さかった。したがって依存予測器は作らず (D5)、dcache の fill 文脈は M4 で新コアの N=4 boot ができるまで 1 つのまま、宣言された上限とする (§2.5)。

### 2.5 成功基準

| マイルストーン | 機能ゲート | 構造ゲート |
|---|---|---|
| M1a 基盤 | V14 が統合 SoC (`N_HARTS=1`) と改名の後も梯子 1-5 を通り、dhrystone/coremark がビット一致する。golden の受入と最初の成果物 (検証計画 §3.4、§3.5)。 | §3.7 の spike を通過している (SoC 統合より前)。retire_pkg と tracer が master にある。20 テストの時間測定 (D3) を済ませている。 |
| M1b 歩く骨格 | rv64ui が golden の trace と一致する (cfg_w2)。cfg_w4 は elaborate でき、rv64ui のサブセットが通る。 | M1b で取り込んだ新規モジュールが cold-reader gate を通過している (P5)。knob が 0 個。`VERYL_AOT_C_DIAG=1` で whole-comb fallback が 0。kill/WB の invariant checker がすべてのテストで 0。 |
| M2 | arch suite、ACT4、5.15 N=1 boot の lockstep (cfg_w2)。 | 推定段階の旧コアバグを directed test で確認済み (D4)。 |
| M3 | 両構成で N=1 のゲートの梯子を通る (新コアの SMP は M4 から存在する)。N=4 boot ゲートの扱い (D7) をここで決め、M4 から適用する。 | 各軸の sweep で IPC が期待方向に動く。動かない場合は、その原因を §3.4 に天井として登録する。dcache の CPU 側は 2 ポート (bank 化、ポートごとの tag lookup、`fill_id = {index, 世代}` を持つ MSHR file の構造) で、DTLB は lookup 2 ポート。いずれも N=1 のゲートで検査する。支援する `MSHR_N`/`N_FILL` は 1 のまま。cy/s を記録している。 |
| M4 | litmus N=2/N=4、N=2/N=4 boot。 | メモリ系を変更した場合は N=4 boot を必須とする。`MSHR_N`/`N_FILL` を 1 より大きくするのは、新コアの N=4 boot ができた後に限り、そのコミットはすべて N=4 boot をゲートとする。 |
| M5 | hvlinux、vector のテスト群。 | VU の上限を修正するか宣言する (§3.4)。 |
| M6 | 既定コアを切り替える。旧コアを削除する (`src/v14/` を消す)。 | M6 での変更は、削除と既定値の変更だけ。 |

【決定】M1 を M1a (基盤: 旧コア側の前提作業、SoC 統合、golden、spike) と M1b (歩く骨格: rv64ui に要るものだけ) に分ける。理由: 1 つのマイルストーンで前提作業と全モジュールの最終形を同時に求めると、ゲート (rv64ui) が確かめない構造まで cold-reader に掛けることになり、また SoC 統合が使う構文の検証 (spike) が統合より後に来ていた。FP FU、`tlb`/`ptw`、`atomic_unit`、`io_unit`、rv64ui が要らない CSR と割込みは M2 に移す (マイルストーン計画)。

sweep の判定: 1 軸だけを増やし、他の軸を固定する。coremark/dhrystone (cycles と instret は正確) と N=1 boot (cy は 10,000 刻みに量子化) で IPC が下がらないこと。加えて、その軸が律速となる負荷で IPC が上がること。

### 2.6 非目標

- 旧コアとの性能パリティ、および旧コアのバグとの互換。
- 周波数目標。CP の数値は「直列リデュースが無いこと」と「段の追加が局所的であること」を確かめるためだけに使い、目標値にはしない。
- non-coherent な bare 構成 (メモリを直結したコア単体ハーネス) への対応 (D3)。
- 実体のある WFI (D2 により NOP)。
- M4 で新コアの N=4 boot ができるまでの、1 hart あたり複数 line fill (MLP) (§3.4 で上限として宣言)。
- RVA23 のうち旧コアが持たない拡張の追加。これは M5 の後に、ユーザの判断で行う。

---

## 3. 支援構成とパラメータ軸

### 3.1 5 軸の定義

| 軸 | 定数 | 定義 |
|---|---|---|
| fetch/decode | `FETCH_W` | extract が 1 サイクルに出せる命令数の上限。decode lane 数と同じ。 |
| rename/dispatch | `RENAME_W` | 1 サイクルに rename して dispatch する op 数の上限。 |
| issue | `ISSUE_W` | メモリ以外の実行 issue ポートの数。各ポートは 1 サイクルに 1 op を select し、固有の FU 集合と WB ポートを持つ。 |
| memory | `MEM_W` | memory pipe の数。これは dcache の CPU 要求ポート数、DTLB の lookup ポート数、load WB ポート数と等しい。 |
| commit | `COMMIT_W` | 1 サイクルに retire できる op 数の上限。retire record の lane 数と等しい。 |

【決定】`ISSUE_W` には memory pipe を含めない。理由: 含めると 2-2-2-1-2 では実行ポートが 1 本になり、2-wide rename に対して旧コア (整数 2 lane + FP 1 lane) より狭くなってしまう。この定義では 4-4-6-2-4 の select は 1 サイクルに 6+2=8 本になる。

### 3.2 支援構成と導出値

| 値 | 式 | `cfg_w2` (2-2-2-1-2) | `cfg_w4` (4-4-6-2-4) | 状態 |
|---|---|---|---|---|
| FETCH_W / RENAME_W / ISSUE_W / MEM_W / COMMIT_W | 軸 | 2 / 2 / 2 / 1 / 2 | 4 / 4 / 6 / 2 / 4 | 【決定】D7 |
| `FETCH_BYTES` (fetch block) | 8×FETCH_W | 16 | 32 | 【決定】非圧縮命令 FETCH_W 個分 (4×FETCH_W B) の 2 倍。block 内で開始位置がずれていても FETCH_W 命令を供給できる。icache の CPU ポートもこの幅に広げる (§F)。 |
| WB ポート総数 | ISSUE_W+MEM_W | 3 | 8 | 【決定】§5.7 |
| retire 数の幅 `RETIRE_CNT_W` | idx_w(COMMIT_W+1) | 2 | 3 | 【決定】 |
| 1 サイクルに retire できる store 数 `ST_RET_N` | MEM_W | 1 | 2 | 【決定】`core_types` の導出定数 `ST_RET_N` として出す (M1b)。store は execute で 1 サイクルに最大 MEM_W 個しか生成されないため、それ以上 retire させても定常状態では得にならない。 |
| SB の push ポート数 `PUSH_W` (line 単位) | max(MEM_W, 2) | 2 | 2 | 【決定】line をまたぐ store は、retire のサイクルに 2 つの line を push する (§L)。 |
| FTQ の PC 読出ポート数 | BRU ポート数 | 1 | 2 | 【決定】PC を FTQ から読むのは BRU ポートだけ (§F.3)。commit は PC を導出する (§C.2.3)。 |
| commit-alone op | 1/cycle | 1 | 1 | 【決定】§5.12 |
| kill | 1/cycle | 1 | 1 | 【決定】§5.4 |
| BRU ポート数 (1 サイクルの resolve 数) | トポロジ | 1 | 2 | W2 は【決定】、W4 は【M3 で決定】 |
| walk 幅 `WALK_W` | RENAME_W | 2 | 4 | 【決定】walk は rename の RAT 書込ポートを使う。 |
| rename group あたりの vector op 数 | VU の alloc ポート数 | 1 | 1 | 【決定】宣言された上限 (§3.4) |
| D-PTW / I-PTW | | 1 / 1 | 1 / 1 | 【決定】 |
| dcache fill 文脈 `N_FILL` | | 1 | 1 | 【決定】宣言された上限。M3 は MSHR file の構造だけを作り、値は 1 のまま。増やせるのは M4 で新コアの N=4 boot ができた後 (§2.5)。 |
| dcache data bank 数 | ≥1 | 1 (M1-M2 adapter) | 【M3 で決定】 | 2 ポート化の bank conflict 率を sweep で測って決める。 |
| PRF 書込ポート数 int / fp | WB 表 (§5.7) | 3 / 2 | 7 / 4 | W2 は【決定】、W4 は【M3 で決定】 |
| PRF 読出ポート数 int / fp | トポロジ | 6 / 4 | 【M3 で決定】 | W4 は FU 使用率の sweep で決める。M5 から VU が int 2 / fp 1 を追加する (§V)。 |
| `PREG_W` | idx_w(max(PRF_INT_N, PRF_FP_N)) | 7 | 8 | 【決定】int と fp で共通の幅にする。再利用する VU と CdbBus が `PRF_INT_W == PRF_FP_W` を前提にしているため。 |

【決定】M1-M2 のゲートは `cfg_w2` で回す。`cfg_w4` は M1b から elaborate でき、rv64ui のサブセットが通る状態を保つ。理由: lane 数が 2 を超える経路を M3 まで放置すると腐る。M1-M2 の dcache adapter は物理経路が 1 本なので、MEM_W=2 で 2 本の論理ポートが同時に要求したら、負けた方が `RETRY(BANK_CONFLICT)` を受け取る。負けるのは port 0 でもありうる (§M.2.6)。これで W4 も機能的には走る (§5.9)。

### 3.3 構造サイズ (初期値)

サイズは所有モジュールだけが参照する (P2)。下表は M1 の skeleton で使う初期値であり、最終値は【M3 で決定】: 1 軸ずつ sweep し、IPC 曲線の膝の位置で決める。

| 定数 | 所有者 | cfg_w2 | cfg_w4 | 初期値の根拠 |
|---|---|---|---|---|
| `ROB_N` | `rob` | 64 | 128 | 2 の冪 (§3.4 の VU 制約)。この理由が拘束するのは、M5 で VU を修正するまで。 |
| `LQ_N` / `SQ_N` | `lq` / `sq` | 32 / 16 | 64 / 32 | 新しい LQ/SQ は credit による背圧を持つので、どのサイズでも正しく動く。旧コアの LQ high-water は 16/32。 |
| `SB_N` (64 B line) | `sb` | 4 | 8 | 旧コアは 4。 |
| `FTQ_N` | `ftq` | 16 | 32 | ROB とは独立に決める。 |
| `PRF_INT_N` | `prf` (int) | 96 | 160 | 32 + ROB_N。free list が ROB より先に詰まらない大きさ。`free_list` と `busy_table` も PRF のサイズを要するが、直接は参照せず、`core_types` が出す導出定数 `FREE_INT_N`/`FREE_FP_N` を使う (P2 を保つ)。 |
| `PRF_FP_N` | `prf` (fp) | 64 | 96 | 32 + ROB_N/2。 |
| `NUM_CKPT` | `rename` | 0 | 0 | M1-M2 は walk だけで回復する (§5.4)。M3 以降の値は【M3 で決定】: walk のサイクル数と、mispredict 1 回あたりの回復コストを測って決める。少なくとも 1 構成では、pool が枯渇して walk に fallback する経路が定常的に発火していなければならない。 |
| IQ のエントリ数 | `iq` | §X | §X | §X で決める。 |
| `DTLB_N` / `ITLB_N` | `tlb` (D / I の instance) | 16 / 16 | 16 / 16 | `tlb` は新規モジュールで、M2 から `ENTRIES` パラメータを持つ (初期値 16 は旧 mmu のリテラル)。core top が instantiate 時に束縛する。M3 は sweep するだけ。 |
| `PTW_D_QN` / `PTW_I_QN` | `ptw` | 4 / 1 | 4 / 1 | 要求キューの深さ (§M.8.1)。M2 から。 |
| `REISSUE_W` | `lq` | 1 | 1 | 1 サイクルに再 issue する数 (§L.7)。上限は MEM_W。 |
| `DC_NB` | `dcache` (M3 の CPU 側) | 1 | 1 | data の bank 数 (§M.6.3)。M1-M2 の adapter は 1 で固定。M3 で sweep する。 |
| `MSHR_N` | `dcache` (M3 の CPU 側) | 1 | 1 | §M.6.4。1 を超える値は M4 で新コアの N=4 boot ができた後に限る (§2.5)。 |

### 3.4 宣言された上限 (再利用モジュールと本設計の構造に由来するもの)

| 上限 | 出所 | 許される値 | 処置と期限 |
|---|---|---|---|
| ROB ≤ 256、かつ ROB_N は 2 の冪 | VU の `fp_elem` が `logic<8>` (`vector_unit.veryl:925`)、VU の age 計算が `idx - head` | ROB_N ∈ {2^k, k≤8} | M5: VU の owner 幅を切り離し、age 計算を `tag_pkg::older` に置き換える。 |
| 単一の PREG 幅 | VU と `pipeline_pkg::CdbBus` | PREG_W 共通 | 【決定】§3.2 |
| VU は CDB を 2 lane だけ snoop する | `vector_unit.veryl:94-101` | VU を使うのは M5 から | M5: head に達した時点で scalar は ready とみなし、snoop は使わない。 |
| VU の alloc は 1/cycle | `vector_unit.veryl:70` | rename group あたり 1 | 宣言された上限として残す。 |
| dcache data は 1 read/cycle | `o_hit2` は `S3_SLOT1=1` によって 0 に固定 (`dcache.veryl:877,3112`) | M1-M2 では物理アクセス 1 本 | M3: data を bank 化し、tag を複製する。 |
| D-line fill は 1 hart に 1 本 | `MSHR_N=1` (`dcache.veryl:452`)、mem_ctrl の SPH=2 | N_FILL=1 | 宣言された上限。M3 は MSHR file の構造 (`fill_id = {index, 世代}`) だけを作り、値は 1 のまま。増やす条件は §2.5 の M4 行。 |
| icache の fill は 1 本で、I read slot を I-PTW と共有する | 再利用 `icache` の単一 fill、外部 slot は I 側に 1 本 | - | 宣言された上限として残す。I read slot の調停は `islot_arb` (§M) が行う。 |
| `o_inst_hart = h as 3` | `mem_ctrl.veryl:1067` | SPH=2 | SPH>2 にする前に `h % N_HARTS` に修正する。 |
| hart 数 ≤ 8 | fabric の `logic<3>`、CLINT のデコードが 3 bit | N_HARTS ∈ {1,2,4,8} | 宣言された上限として残す。 |
| TLB サイズがリテラル | `mmu.veryl:220-237` | 16 / 32 | `tlb`/`ptw` は `mmu.veryl` のロジックを移植した新規モジュールで、`tlb` は M2 から `ENTRIES` を持つ。`mmu.veryl` は変更しないので、MMU には v14 の凍結コピーが要らない。 |
| minstret の増分が 1 bit | `csr.veryl:170` | - | M1a: `csr` に `i_instret_cnt` の幅パラメータを設ける (既定値 1。旧コアは既定値のまま instantiate するので変わらない)。 |
| CLINT に tick 入力が無い | `clint.veryl:51-68` | - | M1a: 追加の入力 2 本 `i_tick_sel` と `i_tick` を設ける (prescaler は残し、`i_tick_sel=0` で従来どおり)。 |
| fetch 幅 ≤ 4 | `FETCH_BYTES = 8×FETCH_W` ≤ 32 B (icache の内部 block 幅、§F.6 IC2)。ITLB の lookup が block あたり 1 回で足りるのもこの制約による | FETCH_W ∈ {1, 2, 4} | 宣言された上限として残す。広げるには icache の内部 block と ITLB の lookup を作り直す。 |
| fetch block は 1 サイクルに 1 本 | bpu の enqueue、extract の取り出し、ftq から bpu への update がどれも 1 block/cycle (§F.3、§F.4、§F.7) | - | 宣言された上限。taken branch が密で COMMIT_W=4 のとき、update が FTQ の解放を律速しうる。【M3 で決定】`ftq_full` の発火と update 待ちのサイクルを測り、律速なら update を 2 本にする。 |
| store の drain ポートは 1 本 | `sb` の head だけが駆動する line 幅の書込ポート (§5.9 MP7、§M.6.6) | - | 宣言された上限。PUSH_W と MEM_W を上げても drain の帯域は増えない。 |
| port 0 専用の client クラス | HEAD、PTW、AD、ASQ と VU (§5.9 の能力表、§L.14) | - | 宣言された上限。MEM_W を上げてもこれらの帯域は増えない。 |
| wbm0 だけに付く HOLE_FILL の client | `io_unit`、`atomic_unit`、VU の scalar 結果 (§5.7) | - | 宣言された上限。どれも head でしか動かないので同時に 1 つ。 |
| `MemEvent` は 1 サイクルに 1 個 | adapter と M3 の dcache の event ポート (§M.2.5) | - | `MSHR_N > 1` (M4) にするときに再検討する。 |
| kill 1/cycle、commit-alone 1/cycle、D-PTW と I-PTW 各 1 本、rename group あたり VEC 1 個 | §3.2 の固定値 | - | 宣言された上限として残す。 |

VU に由来する行 (ROB ≤ 256 と 2 の冪、CDB の 2 lane snoop、alloc 1/cycle) は M5 の後にこの表から消える。修正した上限は削除し、残す上限は §V の宣言に移す。

### 3.5 構成値の三段階と非支援値の拒否

| 段階 | 意味 | 扱い |
|---|---|---|
| 支援構成 | `cfg_w2` と `cfg_w4` だけ | ゲートの梯子をすべて通す。 |
| sweep 点 | 構造制約を満たす他の値 | elaborate でき、bench が走る。ゲートでの保証は無い。config パッケージは `tb/` に置く。 |
| 拒否 | 構造制約に反する値 | `test_cfg_constraints` を落とす (下記)。 |

【決定】(U6、§3.7.1) 構造制約は `core_types` の 1 つの bitmask 定数 `CFG_ERR` (制約 1 つに 1 bit、合法な構成では 0) にまとめ、`#[test] test_cfg_constraints` が全構成について `CFG_ERR == 0` を検査する。理由: 未定義モジュールの instantiate は generate 条件に関係なく常にエラーになり、elaborate 時の拒否が書けないため。各 bit が実際に立ちうることは、わざと違反させた構成 `cfg_bad_a`/`cfg_bad_b` (`tb/cfg_bad.veryl`) が期待どおりの bit を立てることで示す (2 つの和で全 bit を覆う)。制約を所有モジュールの側へ移すのは、その方がきれいになった場合に限る。M1b 時点の bit:

| bit | 制約 | 理由 |
|---|---|---|
| 0 | `FETCH_W` ∈ {1, 2, 4} | icache の block と block あたり 1 回の ITLB lookup で fetch は 32 B が上限 (§3.4) |
| 1 | `FETCH_BYTES == 8×FETCH_W` | §3.2 |
| 2 | `RENAME_W`、`ISSUE_W`、`MEM_W`、`COMMIT_W` ≥ 1 | |
| 3 | `ROB_N` ≤ 256、2 の冪、`ROB_N ≥ RENAME_W` | VU の 8 bit owner と `idx - head` (§3.4) |
| 4 | `PRF_INT_N`、`PRF_FP_N` > 32 | free list が空にならない |
| 5 | 1 ≤ `REISSUE_W` ≤ `MEM_W` | §3.3 |
| 6 | `MSHR_N == 1` かつ `DC_NB == 1` | 新コアの N=4 boot まで fill は 1 本 (§2.5)。M3/M4 で緩める |
| 7 | `DQ_N ≥ FETCH_W`、`RQ_N ≥ FETCH_W`、`RQ_N ≥ RENAME_W` | `lane_queue` は少なくとも 1 group を保持する |
| 8 | `MEM_IQ < N_IQ` | §X.2 |
| 9 | 各 IQ に issue ポートが 1 本以上 (`MEM_IQ` は memory pipe を数える)、`IQ_N[q] ≥ RENAME_W`、1 ≤ `IQ_NSRC[q]` ≤ 3 | |
| 10 | `PORT_IQ[p] < N_IQ` かつ `PORT_IQ[p] != MEM_IQ` | `PORT_IQ` は exec ポートだけを表す (§X.2) |
| 11 | `PORT_FU` に NONE、LOAD、STORE、ATOMIC、VEC を載せない | memory と dispatch で完了する種別は exec ポートに来ない |
| 12 | 1 つのポートに DIV と FDIV を同時に載せない | HOLE_FILL の FU はポートに高々 1 つ (§X.2) |
| 13 | 同じ FuKind を持つポートは同じ IQ に属する | op の行き先 IQ が種別だけで決まる (§R.5.1) |
| 14 | SYS を持つポートはちょうど 1 本 | §X.8.3 |
| 15 | ALU、BRU、MUL、DIV、FMA、FMISC、FDIV がそれぞれ 1 本以上のポートに載る | decode が出す exec 種別はどれも行き先を持つ |
| 16 | `NUM_CKPT == 0` | checkpoint pool ができるまで walk だけで回復する (§R.7)。M3 で緩める |

### 3.6 構成の運び手 (Veryl)

【決定】proto パッケージ + 構成ごとのパッケージ + generic な型パッケージ + 構成ごとの非 generic wrapper top、という構造にする。理由: 2 つの構成が 1 回のビルドに共存でき、struct のフィールド幅を構成に追従させられ、std の `axi4_pkg`/`axi4_if` と同じ型で書けるため。

```veryl
pub proto package core_cfg {
    const FETCH_W    : u32;
    const RENAME_W   : u32;
    const ISSUE_W    : u32;
    const MEM_W      : u32;
    const COMMIT_W   : u32;
    const FETCH_BYTES: u32;
    const ROB_N      : u32; // read only by rob and core_types
    const LQ_N       : u32;
    const SQ_N       : u32;
    const SB_N       : u32;
    const FTQ_N      : u32;
    const PRF_INT_N  : u32;
    const PRF_FP_N   : u32;
    const NUM_CKPT   : u32;
    const FBQ_N      : u32; // fetch buffer queue (ifu -> extract)
    const DQ_N       : u32; // decode queue, owned by extract
    const RQ_N       : u32; // rename input queue (decode -> rename)
    const PRED_META_W: u32; // width of the opaque predictor metadata type
    const PRED_CKPT_W: u32; // width of the opaque predictor checkpoint type
    const DTLB_N     : u32; // tlb entries, bound per instance by the core top (from M2)
    const ITLB_N     : u32;
    const PTW_D_QN   : u32; // ptw request queue depth (from M2)
    const PTW_I_QN   : u32;
    const REISSUE_W  : u32; // LQ re-issues per cycle, <= MEM_W
    const DC_NB      : u32; // dcache data banks (rebuilt CPU side, M3)
    const MSHR_N     : u32; // dcache MSHR entries (M3 structure, > 1 only from M4)
    // FU topology (see sections 5.7 and X)
    const PORT_FU    : FuSet [ISSUE_W]; // FU set per exec issue port
    const PORT_IQ    : u32 [ISSUE_W];   // IQ feeding each exec issue port
    const N_IQ       : u32;             // includes the memory IQ
    const MEM_IQ     : u32;             // IQ feeding every memory pipe
    const IQ_N       : u32 [N_IQ];      // entries per IQ
    const IQ_NSRC    : u32 [N_IQ];      // source operands per IQ entry
}

pub package cfg_w2 for core_cfg { const FETCH_W: u32 = 2; /* ... */ }
pub package cfg_w4 for core_cfg { const FETCH_W: u32 = 4; /* ... */ }

pub package core_types::<CFG: core_cfg> {
    const ROB_IDX_W: u32 = tag_pkg::idx_w(CFG::ROB_N);
    // RobTag, LqTag, SqTag, FtqTag, PReg, OpTag, Kill, ... (section 5.1, 5.2)
}

pub module heliodor_core::<CFG: core_cfg> ( /* section 4.5 */ ) { /* wiring only */ }
pub module heliodor_core_w2 ( /* same ports, concrete widths */ ) {
    inst u_core: heliodor_core::<cfg_w2> ( /* ... */ );
}
```

- `core_cfg` に置く予測器の定数は、不透明な予測器型 (`PredMeta`, `PredCkpt`) の幅だけである。BTB のエントリ数、block あたりの slot 数、RAS の深さ、各部品のレイテンシなど予測器内部のサイズは `bpu_pkg::<CFG>` に置き、`bpu` だけが読む (§F)。
- FU トポロジ表 (`PORT_FU`, `PORT_IQ`, `N_IQ`, `MEM_IQ`, `IQ_N[]`, `IQ_NSRC[]`) の意味と cfg_w2/cfg_w4 の値は §X が定める。構成によって変わるのはこの表だけである (§5.7)。
- モジュール本体は、構成を先頭の `import core_types::<CFG>::*;` だけで受け取る。本体の中で `CFG::` を修飾して書くのは、子モジュールの instantiate (`inst u: rob::<CFG>`) とサイズの所有箇所だけ。この規則にしておけば、§3.7 の fallback への移行が機械的な書き換えで済む。
- 構成に依存しない helper (`tag_pkg`, `tree_pkg`, `exc_pkg`, `pma_pkg`, `retire_pkg`, `fu_pkg`) は、通常の非 generic パッケージに置く。幅が必要なものは generic 関数 (`older::<W>`) にする。前例として `fpu_pkg::clz::<W>` が production で動いている。
- 構成ごとの wrapper top (`heliodor_core_w2`, `heliodor_core_w4`) は、`veryl synth --top`、Verilator の SV wrapper、tb ハーネスに安定した名前を与える。generic モジュールは mangle された名前で emit されるので、外から直接名指ししない。
- SoC は非 generic のまま `CORE` パラメータ (enum: `V14`, `W2`, `W4`) を持ち、generate-if で wrapper top を選ぶ (D6)。

### 3.7 M1a ツールチェーン spike (§3.6 の採否を決めるゲート)

spike では、2 つの構成で skeleton (rename + ROB + FU 1 個 + struct 配列ポートを持つ `lane_queue`) を作り、次をすべて通す。

1. cc backend での `veryl check/build/test`。`VERYL_AOT_C_ASYNC=0` で測り、`VERYL_AOT_C_DIAG=1` で whole-comb fallback が 0 であること。
2. Verilator wrapper での実行。
3. 非 generic wrapper に対する `veryl synth --top`。
4. veryl clone 側に、新しく依存する構文ごとの simulator unit test を追加する。対象は、proto パッケージ上の generic モジュール、generic な型パッケージと generic モジュール内でのその import、struct 配列ポート (generate-for 内の部分 index 接続と slice 接続を含む)、const struct 配列パラメータ (PMA 表と FU トポロジ表)、ポート集合の異なる 2 本の generate-if 枝 (SoC の `CORE`)。
5. 同じ関数を入れ子で呼ぶと recursion と誤判定される問題 (`veryl/crates/simulator/src/ir/statement.rs:4535`) を、clone 側で修正する。【決定】プロジェクト規則に従い、heliodor 側では回避しない。修正が入るまでの間も、tree は段ごとに配列を持つ generate で書く (§5.15)。この書き方は修正後もそのまま正しい。
6. §3.5 の拒否の仕組みを確認する。

#### 3.7.1 spike の結果 (2026-10-14、ブランチ `phase15/spike`)

【決定】§3.6 の (A) を採る。fallback は使わない。spike (`src/spike/`、`tb/test_spk_*.veryl`) は、proto パッケージ `spk_cfg` と 2 つの構成パッケージ、generic な型パッケージ `spk_types::<CFG>`、generic モジュール `spk_rob::<CFG>`、非 generic wrapper `spk_core_w2/w4`、`type` パラメータと struct 配列ポートを持つ `spk_lane_queue`、const struct 配列パラメータ (PMA 表) を受ける `spk_pma_user`、ポート集合の異なる 2 本の generate-if 枝を持つ `spk_soc` から成る。

| 項目 | 結果 |
|---|---|
| 1. cc backend | `check/build/test` 通過。`VERYL_AOT_C_DIAG=1` で whole-comb fallback は 0 (旧コアを含む既定スイート全体でも 0)。 |
| 2. Verilator | `spk_soc` の 2 構成が cc と同じ値を出す。 |
| 3. synth | `veryl synth --top` が `spk_core_w2`、`spk_core_w4`、`spk_soc` で通る。 |
| 4. clone の単体テスト | spike が見つけた veryl のバグ 3 件を clone で直し、それぞれに回帰テストを足した (下記)。構文ごとの網羅的な単体テストは、M1b で各構文を最初に使うモジュールと一緒に足す。 |
| 5. 入れ子呼び出し | パッケージの generic 関数では再現しない。モジュール内の関数では再現したので clone で直した (下記 D)。 |
| 6. 拒否 (U6) | 未定義モジュールの instantiate は条件に関係なく常にエラーになり、幅 0 の型は確実に落ちない。【決定】`#[test] test_cfg_constraints` で全構成の制約定数を検査する。 |
| cranelift (U10) | spike は `--backend cranelift` でも通る。skeleton 規模での到達範囲は M1b で測る。 |

見つけて直した veryl のバグ (clone の修正ブランチ。統合ブランチ `local/heliodor-fixes` からビルドしたバイナリで heliodor を回す。upstream への PR はユーザが行う):

| ID | 症状 | 原因 | ブランチ |
|---|---|---|---|
| A | 前のパラメータで大きさを決めたパッケージ struct の配列パラメータのメンバを参照すると「定義前の参照」になる | 配列で初期化した const のメンバパスが登録されず、外部参照として型を評価し直していた | `fix/param-array-member-ref` |
| C | パッケージ内の `#[ifdef]` に `--define` が効かない (simulator だけ。SV 出力は正しい) | 名前解決が define を知らず、排他な変種のうち最後の宣言を選んでいた | `fix/sim-ifdef-package-items` |
| D | 同じモジュール内関数の入れ子呼び出しが recursion と判定される | 引数を変換する前に展開中の印を付けていた | `fix/sim-nested-same-function-call` |

仕様上の制約 (バグではない): パッケージの generic 関数に、モジュールのパラメータを generic 引数として渡せない (`p::f::<N>()` は循環依存として拒否される。インスタンスがパッケージ内に生成され、モジュールの `N` が見えないため)。【決定】そのような helper (`pma_check` など) はパッケージ外のグローバル generic 関数にする。グローバル関数は呼び出し元のモジュール内に生成される。

その他の決定:

- U7: 【決定】checker (`chk_*`) は `#[ifdef(HELIODOR_CHK)]` で囲み、`[test].defines` にだけ `HELIODOR_CHK` を入れる。`veryl synth` は define を渡さないので、synth からは自動的に外れる。Verilator でも `+define+HELIODOR_CHK` で有効にする。
- `CORE` の既定値の切替 (検証計画 §2.5): バグ C の修正により、パッケージ const の `#[ifdef]` で切り替えられる。
- U4: 【決定】新コアは `local/heliodor-fixes` の veryl を使う。旧コアはこのバイナリでも dhrystone/coremark がビット一致し、既定スイートも全通過した。
- 【決定】(M1b 先行、veryl を origin/master `6a671a6b` + 修正 5 本に更新した後) helper の形: `src/core/common/tag_pkg.veryl` は `pub package tag_pkg { idx_w }` と、ファイルレベルのグローバル generic 関数 `tag_older::<W>`、`tag_older_eq::<W>`、`tag_next::<W, N>` を持つ。`src/core/common/tree_pkg.veryl` はパッケージを持たず、グローバル generic 関数 `tree_prefix_or/and`、`tree_first`、`tree_prefix_count` (配列の output 引数)、`tree_popcount`、`tree_onehot_enc/mux`、`tree_oldest` (one-hot、同じ tag なら小さい index) を持つ。`core_types::killed()` は `tag_older` を呼ぶ (age の式は 1 か所だけ)。理由: パッケージの generic 関数を呼び出し側の定数 (モジュールのパラメータや `core_types` の定数) でインスタンス化すると、インスタンスがパッケージ内に生成されるため、生成される SV で本当の相互依存になる (veryl の仕様)。グローバル関数のインスタンスは呼び出し側に生成される。`tb/cfg_bad.veryl` を別ファイルにするのは、構成パッケージとそれを `core_types::<cfg>` で使う側を同じファイルに置くとファイル間の循環になるため。§5.2 と §5.15 の `tag_pkg::older` などの表記は、この名前 (`tag_older` など) に読み替える。

【決定】fallback: spike で (A) が成立しなかった場合は、`#[ifdef]` で選ぶ素のパッケージ `core_cfg` (1 回の veryl 起動で 1 構成、もう 1 構成は別の worktree/.build で回す) に切り替える。§3.6 の import 規則により、モジュール本体は変わらない。`#(param)` を全モジュールに通す方式 (旧コア流) は採らない。理由: struct のフィールド幅をパラメータに追従させられず、モジュール間でタグ幅の食い違いを許してしまうため。

---

## 4. 全体構造

### 4.1 ブロック図

```
                 +----------------------- Redirect / Kill (flush_ctrl, registered) -----------------------+
                 |                                                                                         |
   +-----+   +-------+   +-------+   +---------+   +--------+   +-----------------------+                 |
   | bpu |-->|  ftq  |-->|  ifu  |-->| extract |DQ>| decode |rq>| rename + dispatch rn_ |--+              |
   +-----+   +-------+   +---+---+   +---------+   +--------+   +---+-------------+-----+  |              |
      ^          ^           |  icache, tlb(I), ptw(I)            ^             |  | | |   |              |
      | update   | commit    v                                    | walk        |  | | +-> rob <---------+
      |          |      [I read slot]                             |             |  | |      ^  |  oldest token
      |          |                                                |             v  v v      |  v
      |          |                                     +---------------------------------+  |  commit --> retire port
      |          |                                     | iq + busy_table + wb_resv       |  |    |  ^       (RVFI lanes,
      |          |                                     +--------+-----------+------------+  |    v  |        irq event)
      |          |                                              |           |               | trap_unit -- csr
      |          |                           exec_port[ISSUE_W] |           | mem_pipe[MEM_W]
      |          |                    +-------------------------+           +----------------+
      |          |                    | RR / bypass / FU set     |           | AGU, tlb(D),   |
      |          |                    | (alu, bru, mul, div,     |           | PMP+PMA, fwd,  |
      |          |                    |  fma, fmisc, fdiv, sys)  |           | load format    |
      |          |                    +------------+------------+            +---+------+-----+
      |          |                                 | WB packets (ISSUE_W+MEM_W)  |      |  lq / sq / sb
      +----------+---------- resolve/commit -------+-----> prf(int,fp), rob      |      |  atomic_unit, io_unit
                                                                                 v      v
                                                               mem_port_arb[MEM_W] + sb drain
                                                                         |
                                                          dcache CPU side (M1-M2: dcache_port_adapter)
                                                          dcache (reused), ptw(D) client on port 0
                                                                         |
                                                [D read slot] [write channel] [coherence in]
```

`DQ` は `extract` が所有する decode queue (extract → decode)、`rq` は decode → rename の入力キューであり、どちらも `lane_queue` である (§F、§R)。rename と dispatch は 1 つの段 `rn_` を成す (§R)。モジュールとしては `rename` と `dispatch` に分かれる。

外部ポート群は §4.5 で定める。dcache より下 (L2, mem_ctrl, bus) は再利用ロジックであり、§S が扱う。

### 4.2 モジュール一覧 (1 概念 = 1 モジュール)

| モジュール | 責務 | 章 | 由来 |
|---|---|---|---|
| `heliodor_core::<CFG>` | core top。配線のみ。 | §0 | 新規 (旧 top は `v14_heliodor_core`) |
| `heliodor_core_w2`, `heliodor_core_w4` | 構成ごとの非 generic wrapper | §0 | 新規 |
| `bpu` | 予測器群の top (predict/update/recover 契約)。中の部品は差し替え可能。 | §F | 新規 (旧予測器のロジックを移植) |
| `ftq` | fetch target queue。block 記述子、予測メタデータ、history/RAS の snapshot。 | §F | 新規 |
| `ifu` | fetch: ITLB lookup、icache への req/resp、fetch buffer | §F | 新規 |
| `extract` | 命令境界、RVC 展開 (`c_expander` を lane ごとに)、predecode による自己検証 | §F | 新規 |
| `icache` | 内部は再利用し、CPU ポートを req/resp に作り直す。旧コア用には `v14_icache` として凍結コピーする (M1b、§4.4)。 | §F | 再利用 + CPU ポートの作り直し |
| `decode` | lane ごとに: `decoder` + OpClass + 合法性判定 (§5.5) | §R | 新規 (`decoder` は再利用) |
| `rename` | 投機 RAT と arch RAT、group 内の依存解決、walk/restore、checkpoint pool | §R | 新規 |
| `free_list` | レジスタクラスごとの free list | §R | 新規 |
| `dispatch` | 資源予算、部分受理、ROB/LQ/SQ/IQ の割り当て、dispatch 時完了 | §R | 新規 |
| `iq` | 汎用 issue queue (wakeup、木による select) | §X | 新規 |
| `busy_table` | `prf_ready` (`prf_done` は M5 で最初の消費者と同時に加える、§5.7) | §X | 新規 |
| `wb_resv` | WB ポートごとの予約表 | §X | 新規 |
| `prf` | 汎用の多ポートレジスタファイル (int/fp で instantiate) | §X | 新規 |
| `exec_port` | issue ポート 1 本分: RR、bypass の選択、FU 集合、WB packet | §X | 新規 |
| `fu_alu`, `fu_bru`, `fu_mul`, `fu_div`, `fu_fma`, `fu_fmisc`, `fu_fdiv`, `fu_sys` | FU 契約 (§5.6) に従う各 FU | §X | 新規 (`int_divider`、fp_* の各 leaf は再利用) |
| `fu_blocking_shell` | blocking FU の共通 shell (占有状態、タグの latch、kill による abort、`i_wb_grant` までの保持)。`fu_div` と `fu_fdiv` が共有する。 | §X | 新規 |
| `fp_misc` | スカラ FP の雑多な演算の leaf (`fpu_wrap` から切り出す。`fpu_wrap` 自体は変更しない) | §X | 新規 (leaf のロジックを移植) |
| `mem_pipe` | memory pipe 1 本分: AGU、DTLB、PMP/PMA、dcache 要求、forwarding、load 整形 | §L | 新規 |
| `lq`, `sq`, `sb` | load queue、store queue (commit 前)、committed store buffer | §L | 新規 (D5) |
| `atomic_unit` | AMO/LR/SC、reservation、watch | §L | 新規 (旧方式を移植、D5) |
| `io_unit` | IO アクセスを exactly-once で実行する (§5.14) | §L | 新規 |
| `mem_port_arb` | メモリポートごとの要求者調停 | §L | 新規 |
| `islot_arb` | I read slot の調停 (icache の fill と I-PTW) | §M | 新規 |
| `dcache_port_adapter` | M1-M2: N 本の論理ポートを再利用 dcache に載せる | §M | 新規 (M3 で置換) |
| `dcache` | 内部は再利用。CPU 側は M3 で bank 化して作り直す。 | §M | 再利用 |
| `tlb` | 汎用 TLB (ENTRIES, LOOKUP_PORTS)。I と D で instantiate。 | §M | 新規 (mmu の照合ロジックを移植) |
| `ptw` | page table walker (I と D で 1 個ずつ) | §M | 新規 (`mmu.veryl` のロジックを移植。`mmu.veryl` は変更しない) |
| `pmp_check` | PMP | §M | 再利用 (そのまま) |
| `rob` | エントリ、完了ポート、walk 読出ポート、oldest token、dispatch snapshot | §C | 新規 |
| `commit` | commit group 関数、retire record、副作用の enable、order カウンタ | §C | 新規 |
| `trap_unit` | cause の優先順位、委譲、tval、epc、割込みの受付 | §C | 新規 |
| `flush_ctrl` | kill の生成 (resolve の選択と登録)、front end への redirect | §C | 新規 |
| `csr` | CSR ファイル (`i_instret_cnt` に幅パラメータを追加、既定値 1) | §C | 再利用 (追加のみ。最初の非追加の修正で `v14_csr` を凍結、§4.4) |
| `vector_unit`, `vu_adapter`, `vu_mem_adapter` | VU と、そのタグ・kill・メモリ接続 | §V | 再利用と新規 (M5) |
| `vrf` | ベクトルレジスタファイル | §V | 再利用 (M5) |
| `lane_queue`, `stage_reg` | 段境界の汎用部品 (§5.3) | §0 | 新規 |
| `chk_*` | 観測専用の invariant checker (§5.15) | §0 | 新規 |
| `heliodor_soc_smp` | 統合した SoC (`CORE`, `N_HARTS>=1`, PMA 表) | §S | 再利用 + 変更 |

パッケージ: `core_cfg` (proto), `cfg_w2`, `cfg_w4`, `core_types::<CFG>`, `bpu_pkg::<CFG>` (予測器内部のサイズとレイテンシ、`bpu` だけが読む), `tag_pkg`, `tree_pkg`, `opclass_pkg`, `exc_pkg`, `fu_pkg` (モジュール境界を越えて公表するレイテンシのすべて: FU、`RESP_LAT`、`SNAP_OFS`、`LD_LAT`、`FWD_SKEW`、`SHADOW_LEN`、`IC_RESP_LAT`、`ITLB_LAT`、§2.1 P4), `pma_pkg`, `xlate_pkg` (I/D の翻訳で共有する権限判定関数), `retire_pkg`, `csr_pkg` (既存。CSR 属性表を追加のみで拡張する)。

### 4.3 core top の中身

- `heliodor_core::<CFG>` に置くのは、§4.2 の §F/§R/§X/§L/§M/§C のモジュールの instance と、それらの接続だけ。lane 配列やポート配列は generate-for で instance を並べる。
- event wire の束ね (§4.5 の `o_perf`) と checker への配線も、接続だけで書く。
- top には reset 値も状態も持たない。

### 4.4 命名とファイル配置 (D6 の具体化)

- 【決定】旧コアの private モジュール 20 個を、今すぐ `v14_` prefix 付きで `src/v14/` に機械的に移す。対象: `heliodor_core`, `alu_wrap`, `alu`, `lsu`, `bht`, `blkpred`, `btb`, `ibtb`, `ras`, `tage`, `decode`, `free_list`, `iq_fp`, `iq_int`, `load_queue`, `prf_fp`, `prf_int`, `rat`, `rat_fp`, `rob`。理由: これで新コアが最終名を使え、M6 の作業は `src/v14/` の削除だけになる。改名は機能を変えない。受入条件は、dhrystone/coremark の cycles と instret がビット一致すること。
- 共有モジュール (`decoder`, `c_expander`, `imm_gen`, `csr`, `fpu_wrap` と fp_* leaf, `int_divider`, `vector_unit`, `vrf`, `dcache`, `dcache_tagbank`, `l2cache`, `mem_ctrl`, `memory_bus`, `mmu`, `imem_mmu`, `dmem_mmu`, `pmp_check`, `clint`, `plic`, `uart`, 既存パッケージ) はそのまま置いておく。
- 【決定】共有モジュールへの変更は、M2 まで「追加のみ」(新しい出力の追加、または旧コア側では従来の値に固定される新しい入力の追加) とする。追加では済まない変更が初めて必要になった時点で、変更前の版を `src/v14/v14_<name>` として凍結コピーし、旧コアはそちらを使う。理由: M6 まで、旧コアは master 上で既定コアとしてゲートを通り続けなければならない (D6)。golden は別 worktree に置くので (D1)、master 上の旧コアが golden と一致し続ける必要は無い。
- 見込まれる凍結コピーとその時期:

| 凍結コピー | 時期 | 契機 | 章 |
|---|---|---|---|
| `v14_icache` | M1b | CPU ポートを req/resp に作り直す | §F |
| `v14_csr` | 最初の非追加の修正が入るとき | 追加のみで済まない `csr` の修正 | §C |
| `v14_dcache` | M3 | CPU 側の bank 化と 2 ポート化 | §M |
| `v14_vector_unit` | M5 | owner 幅と age 計算の修正 (§3.4) | §V |

- MMU には凍結コピーを作らない。`tlb`/`ptw` は `mmu.veryl` のロジックを移植した新規モジュールであり、`mmu.veryl` そのものは変更しないため。
- 新コアのファイルは `src/core/` の下に、章ごとのサブディレクトリ (`common/`, `front/`, `rename/`, `sched/`, `exec/`, `lsu/`, `mem/`, `commit/`) を切って置く。Veryl のモジュール名前空間はプロジェクト全体で 1 つなので、ディレクトリは読み手のための区分にすぎない。

### 4.5 コアの外部ポート群

| 群 | ポート | 契約 |
|---|---|---|
| clock/reset | `clk`, `rst` (async_low) | 有効ビットはすべて reset する。 |
| 静的な設定 | `i_hart_id`, `i_reset_pc` | 【決定】パラメータではなく入力にする。理由: 全 hart が同一の component になり、synth の CHILD_CACHE と Cranelift の chunk 共有が効く。cc backend はどのみち hart ごとに展開する。 |
| PMA | パラメータ `PMA_REGIONS` (§5.11) | SoC から与える。全 hart で同一。 |
| D read slot | mem_ctrl の slot プロトコル (accept + 8-beat STREAM、非 DRAM は legacy) | dcache のみが駆動する。 |
| I read slot | 同じプロトコル | icache と I-PTW が使い、`islot_arb` (§M) が調停する。非 cacheable な fetch (ROM) も single-beat 要求としてこの slot を通す。【決定】旧コアの `o_imem` パススルーは廃止する。理由: 外部メモリプロトコルを 1 つにする (D3)。 |
| write channel | writeback、write-through、IO store | 1 つの packet にアドレス・データ・strobe を収める。misaligned の hi 側を別線で送ることはしない (§5.9)。 |
| coherence 入力 | probe, inv, inv2, probe ack | 再利用 dcache の既存仕様に従う。 |
| 割込み | `i_irq_timer_m`, `i_irq_sw_m`, `i_irq_ext_m`, `i_irq_ext_s` (ゲスト外部割込みは M5) | csr で pending を作り、1 サイクル登録してから使う (§5.13)。 |
| 時刻 | `i_mtime` | lockstep 時の tick は SoC 側で作る (§5.13)。 |
| retire ポート | `o_retire[COMMIT_W]: RetireRec`、`o_irq_evt: IrqEvent` | §5.12。新コアの観測契約はこれだけ。`o_dbg_*` の群は持たない。 |
| デバッグ入力 | `i_dbg_retire_limit_en`, `i_dbg_retire_limit`, `i_dbg_irq_mask`, `i_dbg_irq_allow` | §5.13。通常使用ではすべて 0 に固定する。 |
| 性能イベント | `o_perf` (登録済みの event wire の struct) | 機構ごとの発火 wire (§5.15)。HPM の 8 bit バス (csr 内部) はこの部分集合。 |
| checker | `o_chk` (sticky flag) | 観測専用 (§5.15)。 |

統合 SoC (`heliodor_soc_smp`、§S.1、§S.5) は、検証のために次のパラメータとポートを追加する: パラメータ `MTIME_SRC`/`MTIME_DIV` (mtime を時間で進めるか、retire 数の tick で進めるか、とその分周)、`i_mtime_tick`、`i_ext_irq_src` (外部割込みの注入元)、hart ごとの `i_dbg_*`、hart ごとに帰属を付けた IO アクセスの観測出力 `o_chk_io`。詳細は検証計画 §2.1 に従う。

---

## 5. 横断契約

### 5.1 型と幅のパッケージ

所有者: `core_types::<CFG>` (構成に依存する型) と `tag_pkg` (構成に依存しない helper)。

```veryl
// tag_pkg (plain package)
function idx_w (n: input u32) -> u32 { return if n >= 2 ? $clog2(n) : 1; }

// core_types::<CFG>
const ROB_IDX_W: u32 = tag_pkg::idx_w(CFG::ROB_N);
const LQ_IDX_W : u32 = tag_pkg::idx_w(CFG::LQ_N);
const SQ_IDX_W : u32 = tag_pkg::idx_w(CFG::SQ_N);
const FTQ_IDX_W: u32 = tag_pkg::idx_w(CFG::FTQ_N);
const PREG_W   : u32 = tag_pkg::idx_w(max(CFG::PRF_INT_N, CFG::PRF_FP_N));
const CKPT_W   : u32 = tag_pkg::idx_w(CFG::NUM_CKPT);   // >= 1 even when NUM_CKPT = 0
const FOFF_W   : u32 = tag_pkg::idx_w(CFG::FETCH_BYTES / 2);
const ROB_TAG_W: u32 = ROB_IDX_W + 1;                  // full tag widths (wrap + index), the W of the
const LQ_TAG_W : u32 = LQ_IDX_W + 1;                   // age helpers (section 5.2); likewise SQ_TAG_W, FTQ_TAG_W
const FREE_INT_N: u32 = CFG::PRF_INT_N - 32;           // free-list sizes (section R.4)
const FREE_FP_N : u32 = CFG::PRF_FP_N - 32;
const FL_IDX_W : u32 = tag_pkg::idx_w(max(FREE_INT_N, FREE_FP_N)); // one FlPtr type for both classes
const ST_RET_N : u32 = CFG::MEM_W;                      // stores retired per cycle (section 3.2)

struct RobTag { wrap: logic, idx: logic<ROB_IDX_W> }
struct LqTag  { wrap: logic, idx: logic<LQ_IDX_W>  }
struct SqTag  { wrap: logic, idx: logic<SQ_IDX_W>  }
struct FtqTag { wrap: logic, idx: logic<FTQ_IDX_W> }
enum   RegClass: logic { INT, FP }
struct PReg   { cls: RegClass, idx: logic<PREG_W> }
struct FlPtr  { wrap: logic, idx: logic<FL_IDX_W> }
// also defined here: FillId (section 5.9),
// MemTag (section 5.9), OpTag and Kill (sections 5.2, 5.4), ExTag and WbPacket (section 5.6)
```

不変条件:

- タグ・index・ポート番号の幅を、リテラルや手書きの `$clog2` で書いてよいのは `core_types` の中だけ。他の場所ではこれらの型を使う。所有者はレビュアで、grep で検査する。
- `idx_w` は 1 未満を返さない。1 エントリや 1 ポートの軸 (MEM_W=1, NUM_CKPT=0) でも `logic<0>` は生じない。
- 物理アドレスは 56 bit (`pma_pkg::Pa = logic<56>`)、仮想アドレスは 64 bit。PA の上位ビットを捨てるデコードは禁止する (§5.11)。
- 構成に依存しない record (`ExcRec`, `PmaAttr`, `RetireRec`, `IrqEvent`) は、それぞれ `exc_pkg`, `pma_pkg`, `retire_pkg` に置く。
本文の複数の章で使う型のうち、上の宣言に無いものの定義と置き場所:

| 型 | 中身 | 置き場所 |
|---|---|---|
| `FuKind`、`FuSet`、`fu_bit` | FU の種別 (§5.5) と、その bitset (`logic<FuKind の数>`、bit k が FuKind k)。`PORT_FU` の要素型。`fu_bit(k)` は k だけを立てた FuSet。 | `opclass_pkg` |
| `N_PORT` | 1 つの `iq` が受け持つ issue ポートの数。FU トポロジ表 (`PORT_IQ`) から導く。 | `core_types` |
| `BrResolve` | `{valid, mispred, taken, next_pc: logic<64>, ftq: FtqTag, foff: logic<FOFF_W>}`。BRU の WB packet が運び、`rob.res` と `flush_ctrl` が読む。 | `core_types` |
| `Effect` | retire 時の副作用の bitset `{FFLAGS, FS_DIRTY, VS_DIRTY, VXSAT, VCFG, VSTART}`。 | `opclass_pkg` |
| `Budget` | rename/dispatch の資源需要の bitset `{INT_RD, FP_RD, LQ, SQ, VQ, CKPT, PAIR_RD}` (§R.5.1)。 | `opclass_pkg` |
| `FlushKind` | `{NONE, NEXT_PC, XRET}` (§5.5)。 | `opclass_pkg` |
| `AccKind` | `{LOAD, STORE, AMO, FETCH}` (§5.10)。 | `xlate_pkg` |
| `MemCls`、`RespKind`、`RetryReason`、`EvKind`、`MemClient` | §5.9 のコメントに列挙した値をそのまま enum にしたもの。 | `core_types` |
| `PtwKey` | `{vpn: logic<27>, regime: {V0, V1, HLV}}` (§5.10、§M.8.1)。 | `xlate_pkg` |
| `TlbFill`、`TlbInv` | `ptw` から `tlb` への install と、retire 時の無効化 `{kind, va, asid, all_va, all_asid}` (§M.7、§C.2.5 の `XlateFlush` と同形)。 | `xlate_pkg` |
| `BarSeq` | `ld_barrier` op の通し番号 (`logic<ROB_IDX_W+2>`、巡回)。Kill と dispatch snapshot が運ぶ (§L.10)。 | `core_types` |
| `Target`、`AmoClass` | PMA 領域の種類 `{DRAM, ROM, IO}` と、許す atomic の範囲 `{NONE, LRSC, FULL}` (§5.11、§S.2)。 | `pma_pkg` |
| `FillId` | fill の帰属 ID。M1-M2 は adapter の世代 `gen_q` (§M.2.5)、M3 からは `{idx, gen}` (§M.6.4)。LQ 側から見た型は変わらない (§5.9)。 | `core_types` |

- 【決定】`FlPtr` は int と fp で 1 つの型とし、幅は `FL_IDX_W = idx_w(max(FREE_INT_N, FREE_FP_N))` とする。Kill と dispatch snapshot はクラスごとに別のフィールドで運ぶ (§5.4)。理由: リングの深さは 2 の冪でなくてよい (§5.2) ので、小さい側のリングは idx の上位が余るだけで済み、型を 1 つにできる。
- 【決定】`opclass_pkg` は M1b の時点では `FuKind`、`FuSet`、`fu_bit` だけを持ち、`src/core/common/` に置く。`Effect`、`Budget`、`FlushKind`、`op_class()` は decode と一緒に足す。理由: `core_cfg` の `PORT_FU` が `FuSet` を使うので、構成の運び手より先に存在しなければならないため。

型の定義は、上の 2 つの表のほか、契約を定める節か所有モジュールの節にある。所在の索引:

| 型 | 定義する節 |
|---|---|
| `OpTag` | §5.2 |
| `Kill`、`Redirect` | §5.4 |
| `RedirKind` | §5.4 (定義は `core_types`、生成者 `flush_ctrl`、値の意味は §C.4) |
| `OpClass` | §5.5 |
| `ExTag`、`WbPacket` | §5.6 |
| `ExcRec` | §5.8 (`exc_pkg`) |
| `MemTag`、`MemReq`、`MemResp`、`MemEvent` | §5.9 |
| `XlateReq`、`XlateResp`、`PtwEvent` | §5.10 |
| `Pa`、`PmaAttr`、`PmaRegion` | §5.1、§5.11 (`pma_pkg`) |
| `RetireRec`、`IrqEvent` | §5.12 (`retire_pkg`) |
| `CfiKind`、`BlockPred`、`PdInfo`、`PredMeta`、`PredCkpt`、`FetchId`、`FetchBlk`、`XOp`、`PdRedirect` | §F.2 |
| `IcReq`、`IcKind`、`IcResp`、`IcEvKind`、`IcEvent` | §F.6 |
| `DecOp` | §R.2 |
| `LqState`、`ParkWhy`、`FwdQuery`、`FwdPart`、`StaWrite` | §L.1 |
| `MshrEnt`、`MshrSt` | §M.6.4 |
| `TlbLookup`、`TlbEntry` | §M.7 |
| `XlateFlush`、`XfKind`、`SysPending` | §C.2.5 |
| `VuAlloc`、`VecSide`、`VuDone` | §V.3 |
| 既存パッケージの型 (`decoder` の `DecodedOp`、`alu_pkg::AluOp`、`fpu_pkg::FpuOp`、`vector_pkg::VecOp`、旧コアの `pipeline_pkg::CdbBus`) | 再利用モジュールの定義のまま |

### 5.2 op 識別子と単一の age helper

所有者: 型は `core_types`、helper は `tag_pkg`。識別子を割り当てるのは `dispatch`。

```veryl
struct OpTag {
    rob    : RobTag,                       // every op
    lq     : LqTag , lq_v: logic,          // loads
    sq     : SqTag , sq_v: logic,          // stores, store-class atomics
    ftq    : FtqTag, foff: logic<FOFF_W>,  // fetch block + halfword offset
    pdst   : PReg  , has_rd: logic,        // has_rd = 0 for x0 and no-dest ops
    ckpt   : logic<CKPT_W>, ckpt_v: logic, // checkpoint held by this op (M3)
}
// tag_pkg: W = 1 + index width, N = ring size
function older   ::<W: u32>       (a: input logic<W>, b: input logic<W>) -> logic; // a strictly older than b
function older_eq::<W: u32>       (a: input logic<W>, b: input logic<W>) -> logic;
function next    ::<W: u32, N: u32>(t: input logic<W>) -> logic<W>;            // wraps at N, toggles wrap bit
// older(a, b) = (a.wrap == b.wrap) ? (a.idx < b.idx) : (a.idx > b.idx)
```

不変条件:

- 年齢の比較はすべて `older`/`older_eq` で行う。`idx - head` を計算するコードを書かない。kill の消費者に ROB head を配らない。所有者はレビュアで、grep で検査する。
- `older` が正しいのは、2 つのタグがどちらも同じリングの窓の中で生きているときだけ。リングの深さは 2 の冪でなくてよい。`in_window` は assertion 専用とする。
- タグは一意ではない。部分 kill がリングの tail を巻き戻すと、次の割り当てでまったく同じ `{wrap, idx}` が得られる。pdst も同様に、free list の head が巻き戻ると直ちに再配布される。再利用を安全にするのは §5.4 の kill の完全性だけであり、wrap bit では staleness は防げない。
- op の識別子は op と一緒に運ぶ。生きた状態 (ROB head、IQ head、ポートを駆動している者) から読み直さない。例外は次の 2 群だけで、どちらも識別子ではなく許可であり、このほかに例外を足すときはここに登録する。
  - ROB が出す oldest token `{valid, tag: RobTag}` (§5.12)。消費者は自分が運んでいるタグとの等値比較にだけ使う。
  - 取り消せない操作の started latch と、それを立てるタグ無しの `o_started` パルス (`fu_sys`、`io_unit`、`atomic_unit`、`sq` の D ビット経路、M5 の `vu_adapter`、§5.13.1)。パルスはタグを運ばず「いま token を持つ op」に帰属する。これが正しいのは、パルスを出せるのが token と等しいタグを持つ op の受理 edge だけだからである。checker `chk_oldest` が、パルスのサイクルに token が有効でそのタグが発生源の op のタグと等しいことと、`commit.head_started_q` が各 unit の latch の OR に等しいことを検査する。
- 木の中の比較は段ごとに配列を持つ generate で書き、`older(older(..), ..)` のような同一関数の入れ子呼び出しはしない (§3.7)。
- 【決定】`core_types` はタグ全体の幅 (wrap + index) を定数 `ROB_TAG_W`、`LQ_TAG_W`、`SQ_TAG_W`、`FTQ_TAG_W`、`FL_TAG_W` (= `*_IDX_W + 1`) として出し、age helper の `W` にはこれを渡す。理由: Veryl の generic 引数には単純な識別子かリテラルしか書けず、`ROB_IDX_W + 1` のような式を渡せないため。

### 5.3 段間ハンドシェイク規約

所有者: 各段境界の送り側と受け側。部品は `lane_queue` と `stage_reg`。

- R1. valid/ready で受け渡す。転送は `valid && ready` のサイクルに起こる。`valid` は `ready` に組合せで依存してはならない。受理されるまで、送り側は `valid` とデータを保持する。
- R2. `ready` は受け側の登録済み状態 (自分の占有数、credit) だけから作る。下流の `ready` からの組合せ経路は作らない。理由: 段の間に組合せの逆向き経路が無ければ、comb の settle が 1 パスで済む (simulator の速度)。また段の挿入がキューを挟むだけで済む。
- R3. group ハンドシェイク: 1 つの group の lane は lane 0 から連続して valid である (`valid[l]` ならば `valid[l-1]`)。受理されるときは、全 lane が一緒に転送される。
- R4. 部分受理を許すのは dispatch の入口だけ。dispatch は、登録済みの credit (ROB, IQ, LQ, SQ, pdst, VU) から受理数 `take` を計算し、lane `0..take-1` を受け取る。残りの lane は `lane_queue` に残る。
- R5. 汎用部品:

```veryl
module lane_queue #(param T: type, param W_IN: u32, param W_OUT: u32, param DEPTH: u32) (
    i_valid: input  logic [W_IN] , i_data: input T [W_IN],
    o_ready: output logic        ,              // registered: free >= W_IN
    o_valid: output logic [W_OUT], o_data: output T [W_OUT],
    i_take : input  logic<idx_w(W_OUT + 1)>,    // consumer takes lanes 0..i_take-1
    i_flush: input  logic        ,              // empties the queue; drops this cycle's input group and take
);
module stage_reg::<CFG: core_cfg> #(param T: type) ( // back-end pipeline register with built-in kill
    i_valid: input logic, i_data: input T, i_tag: input RobTag, i_kill: input Kill,
    o_valid: output logic, o_data: output T,
);  // o_valid_next = i_valid && !killed(i_kill, i_tag); data captured only when i_valid
```

- 【決定】`lane_queue` では flush がすべてに優先する。flush の edge では、そのサイクルの入力 group と take をどちらも捨てて空にする。理由: flush するのは kill を受けた段だけで、その入力と出力はどちらも kill 済みの op なので、受理や取り出しを数える必要が無い。
- 【決定】`lane_queue` の `DEPTH` は 2 の冪でなくてよい。リングの index は 1 回の減算で巻き戻す (1 サイクルに進む量は `DEPTH` を超えない)。理由: `RQ_N = 2×FETCH_W` のような深さを 2 の冪に丸めずに使えるようにするため。
- 【決定】`stage_reg` は op の `RobTag` を別ポート `i_tag` で受ける。理由: `T` は不透明な型パラメータで、`stage_reg` からはタグの位置が分からないため。
- 【決定】`stage_reg` は stall を持たず、毎サイクル進む。データは `i_valid` のサイクルにだけ捕捉する。理由: back-end の段は背圧を持たない (待たせる必要がある経路は `lane_queue` か WB 予約で表す)。無効なサイクルのデータは誰も読まないので、書き込みは有効な op に限ってよい。
- `stage_reg` が kill を確かめるのは捕捉の edge だけである。kill のサイクルに `o_data` に居る op は次段の入力であり、次段が同じ kill を捕捉時に適用する。

- R6. 段の挿入とは、`lane_queue` か `stage_reg` を 1 つ挟み、その経路のレイテンシ定数 (FU なら `fu_pkg`、memory pipe なら §5.9 の `RESP_LAT`) を 1 増やすことである。それ以外の変更が必要になったら、その設計は契約違反である。

### 5.4 kill/flush プロトコルと回復

所有者: kill を生成するのは `flush_ctrl`。回復の実体は `rename` (RAT) と各リングの所有者が持つ。

```veryl
struct Kill {                       // registered one-cycle pulse, at most one per cycle
    valid   : logic,
    full    : logic,                // 1: every in-flight op dies (keep ignored)
    keep    : RobTag,               // partial: youngest SURVIVING op
    lq_tail : LqTag, sq_tail: SqTag,// partial: rewind targets, from rob's dispatch snapshot of keep
    fl_int  : FlPtr,                // partial: free-list head of the INT class, same snapshot
    fl_fp   : FlPtr,                // partial: free-list head of the FP class, same snapshot
    bar_seq : BarSeq,               // partial: ld_barrier allocation count, same snapshot (section L.10)
    ftq_tail: FtqTag,               // partial: next of the branch's FtqTag (carried by BrResolve)
    ckpt_v  : logic, ckpt: logic<CKPT_W>,
}
struct Redirect {                   // to the front end
    valid: logic, pc: logic<64>, ftq_keep: FtqTag,
    foff : logic<FOFF_W>,           // halfword offset of the redirecting op in its block
    taken: logic,                   // resolved direction of that op (history/RAS repair, FTQ outcome)
    kind : RedirKind,               // produced by flush_ctrl, values in section C.4
}
enum RedirKind: logic<3> { BR, BR_CM, TRAP, IRQ, XRET, SERIAL, REPLAY }
function killed (k: input Kill, t: input RobTag) -> logic { return k.valid && (k.full || older(k.keep, t)); }
```

タイミング規則:

- T1. kill は 1 サイクルに最大 1 つ。full が partial に優先する。同じサイクルに resolve した BRU の中では、最古のものが勝つ (木で選ぶ)。採用されなかった resolve は捨ててよい。commit の backstop (T8) が拾うので安全である。別の kill の直後のサイクルには部分 kill を採用しない (`!kill_q.valid`)。そのサイクルの resolve は直前の kill で既に死んでいる可能性があり、捨てても T8 が拾う。
- 【決定】`Kill` は free list の head を、クラスごとの配列 `fl_head[2]` ではなく 2 つのフィールド `fl_int`/`fl_fp` で運ぶ。理由: Veryl は struct の中に unpacked 配列を置けないため。
- 【決定】`RedirKind` は `core_types` に `Redirect` と並べて定義し、生成するのは `flush_ctrl` である (値の意味は §C.4)。理由: `Redirect` のフィールドの型であり、モジュール間で共有する型は型パッケージに置くため。`RedirKind` は少なくとも `BR` (BRU の resolve による部分 kill)、`BR_CM` (commit 時の検査 T8 による full kill) と、その他の原因 (例外、割込み、xRET、replay、flush を伴う retire) を区別する。front end は `BR`/`BR_CM` と `foff`/`taken` を使って history、RAS、FTQ の outcome を正確に修復する (§F)。
- T2. kill のサイクルには、タグを持つどの構造にも割り当てを行わない (`dispatch` を抑止する)。
- T3. kill のサイクルにも issue、execute、完了は続いてよい。ただし、すべての段レジスタは、その edge で捕捉する op に `killed()` を適用する。kill のサイクルに完了した op は kill に負ける。
- T4. 部分 kill は commit と同じサイクルに共存できる (keep より古い op は影響を受けない)。full kill のサイクルには commit を抑止する。
- T5. リングはエントリごとの比較ではなく snapshot で巻き戻す。ROB の tail は `next(keep)`、LQ/SQ/FTQ の tail、free list の head、`lq` の barrier 割り当て数 `bar_seq` (§L.10) は Kill が運ぶ値にする。full kill では ROB/LQ/SQ を空にし、free list の head を全非アーキ pdst の解放位置に戻し、`RAT := arch RAT` とする。SQ には commit 前の store しか入らない (commit 済みの store は `sb` にある) ので、full kill で SQ は空になる。
- T6. dispatch snapshot `{lq_tail, sq_tail, fl_int, fl_fp, bar_seq}` は、`rob` が ROB index ごとの副配列として持つ。`dispatch` が割り当て時に書き込み、`flush_ctrl` が resolve のサイクルに keep の index で読む。【決定】理由: branch の payload を太らせずに済み、サイズ (`ROB_N`) を参照するのが `rob` だけで済む (P2)。
- T7. kill の完全性 (最重要の不変条件): kill の edge までに、すべての構造は `killed(k, tag)` が選ぶ op をすべて捨てている。その edge で捕捉中の op も含む。ROB の完了ポートはフィルタではない (エントリの valid は確認するが、世代は確認しない)。
- T8. commit の backstop: すべての control op の resolve 結果 (mispredict, resolved next PC) を ROB に記録する。commit 時に `mispredict && !recovered` であれば、その op を retire したうえで full kill をかける (§5.12 の RETIRE_FLUSH)。早期 kill は最適化にすぎず、正しさはそれに依存しない。部分 kill を発行したときは、keep に該当する ROB エントリの `recovered` を立てる。予測値の上書きはしない。
- T9. walk 中に届いた部分 kill と、別の kill の直後のサイクルの部分 kill は捨てる (T8 が拾う)。【M3 で決定】walk の途中で、より古い kill を受け入れて終点を動かすかどうか: M3 で「walk 中に捨てた resolve の数 × 回復コスト」を測って決める。

消費者 (網羅。新しく状態を持つモジュールを追加したときは、ここにも追加する):

| 消費者 | kill への応答 |
|---|---|
| `ftq`, `ifu`, `extract`, `decode`, rename 前の `lane_queue` | `kill.valid` で全 flush する (rename 前の op はすべて keep より若い)。`ftq` は、partial なら `ftq_tail` まで、full なら commit 済みの位置まで巻き戻す (詳細は §F)。`bpu` の history/RAS は生き残った FTQ エントリから復元する。 |
| `rename` | full なら arch RAT をコピー。partial なら、`ckpt_v` の場合は restore、そうでなければ ROB の `{rd_arch, cls, old_pdst}` を tail 側から keep の手前まで WALK_W 個ずつ戻す。walk 中は rename を止める。 |
| `free_list` | head を自分のクラスの `fl_int`/`fl_fp` に戻す。占有数は `tail - head` から求め、別のカウンタは持たない。 |
| `dispatch` | kill のサイクルには割り当てない。入口の `lane_queue` は flush する。 |
| `iq` と issue 段のレジスタ | `killed()` でエントリを落とす。ready/busy ビットは kill では触らない (rename 時の割り当てでクリアする)。 |
| すべての FU の段レジスタ、反復 FU の shell、WB 保持バッファ | `stage_reg` の規則に従う。反復 FU は、FSM を abort したうえで、同じサイクルの `o_valid` をマスクする (§5.6)。 |
| `wb_resv` | 消費者ではない。kill された op の予約枠は空のまま使われずに終わる。 |
| `lq`, `sq` | tail を巻き戻す。miss 待ちの load も一緒に消える。`lq` は barrier の割り当て数 `bar_seq` も巻き戻す (§L.10)。 |
| `mem_pipe` の各段、ポート要求 | `killed()` で落とす。応答が kill 済みのタグ宛てなら、要求者が捨てる。要求を保持するもの (adapter の slot、`ptw` の要求キュー、`io_unit`、`atomic_unit`) は、いずれも `MemTag.rob` に `killed()` を適用する (§5.9)。adapter の slot は fill の開始前に限り取り消せる。front end の client (IFU) は、どの kill でも flush する。 |
| `ptw` の要求キュー | owner の RobTag が `killed()` なら要求を落とす。walk 自体は続けてよい。TLB への install は epoch 規則 (§5.10) に従う。 |
| `rob` | tail を `next(keep)` にする (full なら空にする)。 |
| `rob.exc_q` (最古の例外 1 本、§5.8) | 記録した op が `killed()` なら消す。 |
| `commit` | `sys_pending`、`vec_pending`、`head_started_q` を、その op が `killed()` なら消す (`head_started_q` が消えるのは、その op 自身の trap か retire による full kill だけである、§5.13.1)。retire の条件にも `!killed(kill, tag[l])` を含める (§5.12 C1)。 |
| `flush_ctrl` の resolve フィルタ | 登録済みの resolve 候補のうち `killed()` のものを捨てる。 |
| `exec_port` の wake 遅延線 | `killed()` で落とす。 |
| `fu_blocking_shell` | latch したタグが `killed()` なら FSM を abort し、保持中の結果を捨てる (§5.6 F2)。 |
| `vector_unit` 内部の dispatch FIFO (M5、VM1 の後) | `killed()` で落とす。VU の実行部は head でしか動かないので、消費者ではない。 |
| checkpoint pool | keep より若い checkpoint を解放する。 |
| 非消費者 | arch RAT, `sb`, CSR, commit 済みの LR reservation, started latch を立てた操作 (`io_unit`/`atomic_unit`/`sq` の D ビット経路/VU。最古の op なので、自分の retire と trap 以外の kill には選ばれない、§5.13.1)。 |

回復インタフェースと M1 の範囲:

- `rename` は `restore(ckpt)` と `walk(to: keep)` を 1 つの kill 入力の背後に隠す。
- 【決定】M1 は部分 kill と walk だけで回復を出荷する (`NUM_CKPT=0`)。理由: kill を全面 flush だけにすると、部分 kill の消費経路 (再利用 index のバグ類の主戦場) が M3 まで一度も動かず、checker にも検査対象が無い。checkpoint pool は M3 で追加する (§3.3)。
- 【決定】タグの再利用の安全性は kill の完全性 (kill-before-reuse、T7) で保証する。完了時の世代照合 (tag-validated completion) は設計論理に入れない。理由: 世代ビットをすべての packet に載せる代わりに、kill の消費を `stage_reg` と `i_kill` ポートの lint (§5.15) で構造的に担保し、違反は観測専用の checker で検出する。
- 【決定】kill の判定は age 比較で行う。branch mask は使わない。理由: walk に fallback した branch や、full kill を起こす全原因 (例外、割込み、replay、直列化) には、どのみち age 比較が必要になる。旧コアの CP の壁はいずれも直列リデュースであり、kill の比較ではなかった。mask を再検討するのは、CP の分解で kill の比較が名指しされたときだけ。

### 5.5 OpClass レコード

所有者: `decode` (純関数 `opclass_pkg::op_class(DecodedOp, fetch_fault)`)。消費者: `dispatch`, `iq`, `lq`/`sq`, `commit` (1 つの commit group 関数, §5.12)。

```veryl
struct OpClass {
    fu        : FuKind,   // NONE, ALU, BRU, MUL, DIV, FMA, FMISC, FDIV, SYS, LOAD, STORE, ATOMIC, VEC
                          // FDIV also covers fround/froundnx (blocking shell)
    nonspec   : logic,    // issue only with the oldest token (section 5.12)
    drain     : logic,    // retire waits for sb.ordering_empty (includes the atomic_unit queue, MP7)
    flush     : FlushKind,// NONE, NEXT_PC, XRET: retire ends the group and full-kills younger ops
    alone     : logic,    // retires only as the sole member of its commit group
    ld_barrier: logic,    // loads younger than this op do not issue until it retires (section L.10)
    csr_wr    : logic,    // csr_op == RW || rs1/uimm != 0
    effect    : Effect,   // FFLAGS, FS_DIRTY, VS_DIRTY, VXSAT, VCFG, VSTART (bitset)
    reads_frm : logic,    // dynamic rounding mode read at execute
    budget    : Budget,   // INT_RD, FP_RD, LQ, SQ, VQ, CKPT, PAIR_RD (rename/dispatch resources)
}
```

`fu == NONE` の op は、dispatch で ROB エントリを完了済みとして割り当て、例外を持つ場合はその例外を載せる (dispatch 時完了)。IQ のエントリも FU も使わない。

| op の分類 | fu | nonspec | drain | flush | alone | 備考 |
|---|---|---|---|---|---|---|
| 整数/FP の演算 | ALU/BRU/MUL/DIV/FMA/FMISC/FDIV | 0 | 0 | NONE | 0 | FP は fflags を lane 間で OR し、FS を dirty にする。 |
| cacheable な load/store | LOAD/STORE | 0 | 0 | NONE | 0 | store は §3.2 の予算 (retire は MEM_W 個まで、line は PUSH_W 本まで) に従う。 |
| IO の load (翻訳後に付く遅延属性、`io_ordered=1`) | LOAD | 1 | 1 | NONE | 1 | §5.14。alone は commit が `alone_eff` として合成する (§C.2.2)。 |
| NC の load (翻訳後に付く遅延属性、`io_ordered=0`) | LOAD | 1 | 1 | NONE | 0 | M1-M2 は IO と同じく head でだけ発行する (§5.14)。`alone_eff` は `io_ordered` だけから作るので、group は切らない (§C.2.2)。 |
| IO store (遅延属性) | STORE | 1 | 1 | NONE | 1 | 書き込みの受理を待ってから retire する (§5.14)。 |
| AMO/LR/SC, amocas | ATOMIC | 1 | 0 | NONE (amocas.q は下記) | 1 | `ld_barrier` = aq ビット。drain=0 なのは、`atomic_unit` 自身が開始前に `ordering_empty` を待つため (§L)。実行は D8 の方式 B (§L L.11)。待ち行列方式は M4 まで既存のまま (D5)。amocas.q の形は【M2 で決定】: 2 つの micro-op に crack する案と、2 宛先の op (`budget.PAIR_RD`) にする案を、ACT4 の Zacas テストを通す実装で比べる。rename に追加の RAT ポートが要らない方を採る。 |
| CSR (`csr_wr=1`) | SYS | 1 | 0 | NEXT_PC | 1 | 下の【決定】を参照。 |
| CSR の読み出しのみ (`csr_wr=0`) | SYS | 1 | 0 | NONE | 1 | CSR ファイルには書かない。 |
| SFENCE.VMA, SINVAL.VMA, HFENCE.*, HINVAL.* | SYS | 1 | 1 | NEXT_PC | 1 | オペランドは SYS FU が PRF から読む。 |
| SFENCE.W.INVAL, SFENCE.INVAL.IR | NONE | 0 | 1 | NEXT_PC | 1 | |
| FENCE, FENCE.TSO | NONE | 0 | 1 | NONE | 1 | `ld_barrier=1` |
| FENCE.I | NONE | 0 | 1 | NEXT_PC | 1 | retire 時に icache を invalidate する (§5.12 C3)。 |
| MRET/SRET | NONE | 0 | 0 | XRET | 1 | 飛び先は retire 時に CSR から読む。 |
| ECALL/EBREAK、decode 不正、fetch fault | NONE (例外付き) | - | - | (trap) | - | lane 0 でのみ trap する。 |
| WFI, PAUSE, Zawrs, rd=x0 の hint | NONE | 0 | 0 | NONE | 0 | WFI は合法なら NOP (D2)。U-mode と TW=1 の S-mode では decode で不正命令にする (§C.8)。 |
| cbo.clean, cbo.flush, cbo.inval | STORE | 0 | 0 | NONE | 0 | mem_pipe で翻訳と権限検査 (Zicbom) を行い、fault しうる。プラットフォームは完全に coherent なので cache への要求は出さず (§M)、retire は no-op。所有者 §L。 |
| cbo.zero | STORE | 0 | 0 | NONE | 0 | line 全体に 0 を書く store として `sb` を通る (常に allocate する)。所有者 §L。 |
| VEC (M5) | VEC | 1 | 0 | vector store の全形式で NEXT_PC | 1 | すべての VEC op が `effect` に VSTART を持つ (§V)。 |

決定事項:

- 【決定】CSR への書き込み (`csr_wr=1`) と xRET は、すべて retire 後に flush する。理由: これで、合法性や翻訳に影響するアーキ状態はすべて flush を伴う retire でしか変わらないことになる。frm/satp ごとの特例も、翻訳 barrier の CSR リストも不要になる (§5.10)。白リスト化による緩和は、M3 の sweep で CSR 書き込みの flush コストが 1 % を超えた場合に限って検討する。
- 【決定】特権・状態に依存する合法性検査 (TVM, TSR, FS/VS=Off, 仮想命令, HLV の特権, U-mode の SFENCE/SINVAL, MRET/SRET の特権, counteren, menvcfg/senvcfg の CBIE/CBCFE/CBZE による CBO の有効化 (§C.8), CSR の存在・特権・読み出し専用への書き込み) は、すべて decode で、commit 済みの CSR 状態に対して評価する。不正な op は `NONE` に例外を付けた op にする。理由: 上の flush 規則により、decode が見る状態はその op の commit 時の状態と常に等しい。その結果、commit 時の trap 述語 (旧コアでは head だけで評価していたため、slot 1 を通れば検査を逃れた) が構造的に不要になる。
- 【決定】fetch fault の op は、fetch から decode への境界で class ビットを捨て、`NONE` に例外を付けた op にする。理由: 旧コアでは、fault した op が古い命令ビットのまま VU や LSU に送られる経路が推定された。decode 不正 (不正な OP-V を含む) も `NONE` になるので、完了元を持たずに head で wedge する事態は構造的に起こらない。
- 【決定】`csr_wr` は decode で作り、op と一緒に運ぶ。CSR ファイルへの書き込み、satp/frm の副作用、counter の増分抑止は、すべて `retire && csr_wr` を条件とする。読み出しでも trap する検査 (TVM の satp アクセス、VS の H-CSR アクセス) は `csr_wr` に依存させない。
- 【決定】arch_regs の shadow は持たない。SFENCE/HFENCE のオペランドは SYS FU が通常の issue と同じく PRF から読む。amocas の追加オペランド (比較値の rd、amocas.q の rd+1 と rs2+1) は、`atomic_unit` が開始時に arch RAT と PRF から自分で読む (§L.11)。IQ の source 数は増やさない。boot の pass 判定 (x3) は retire ポートから再構成する。
- 不変条件: op ごとの直列化に関する規則を決めてよいのは、`op_class` (decode 時に決まる分) と、`lq`/`sq` が付ける遅延属性 (IO/NC) だけ。rename、dispatch、commit の中に別のリストを書かない。

### 5.6 FU 契約

所有者: 各 `fu_*`。レイテンシの唯一の出所は `fu_pkg`。

```veryl
struct ExTag { rob: RobTag, pdst: PReg, has_rd: logic }        // echoed unchanged
struct WbPacket {
    valid : logic, tag: ExTag, data: logic<64>,
    exc   : exc_pkg::ExcRec,                                     // section 5.8
    fflags: logic<5>,
    br    : BrResolve,                                           // BRU only: mispredict, taken, next_pc, ftq tag
}
// FU ports (uniform):
//   i_valid, i_op (FU-specific enum), i_tag: ExTag, i_src [N_SRC], i_imm/i_pc/i_rm (only where needed)
//   i_kill : Kill
//   o_ready: registered state only; constant 1 when PIPELINED
//   o_wb   : WbPacket; i_wb_grant: {valid, off} (blocking FUs only: cycles until the granted WB slot)
```

レイテンシの定義: 受理サイクル A とは、`i_valid && o_ready` が成立するサイクルを言う。入力はサイクル A に提示される。`LATENCY = L` の FU は、サイクル A+L に登録済みの `o_wb` を出す。この結果に依存する op は、bypass を通して早ければサイクル A+L に FU に受理されうる (L=1 なら back-to-back)。

不変条件:

- F1. `PIPELINED=1` の FU は stall しない。`o_ready=1` は定数であり、`LATENCY` は正確な値である。各段は `stage_reg` で作り、kill を適用する。
- F2. `PIPELINED=0` (blocking) の FU は、受理時に `{tag, ...}` を自分で latch する。占有中と結果保持中は `o_ready=0` にする。`killed()` で FSM を abort し、同じサイクルの leaf の `o_valid` をマスクする。結果は、出力バッファで `i_wb_grant` が指す WB サイクルまで保持する。`i_wb_grant` はパルスではなく `{valid, off}` (WB slot までのサイクル数) である。blocking FU は `fu_blocking_shell` (§X) の中に leaf を置いて作り、`fu_div` と `fu_fdiv` (fdiv/fsqrt に加え fround/froundnx を含む、FuKind FDIV) がこれを共有する。完了は latch したタグに帰属させ、そのとき提示されている op とは比較しない。公表する `LATENCY` は最小値であり、スケジューラは WB の grant をもって wakeup する。再利用する反復 leaf (`int_divider`, `fp_divider*`, `fp_sqrt*`) の `o_busy` は、受理サイクルと `o_valid` サイクルに low になる。そのため shell は leaf の `o_busy` に頼らず、自分で占有状態 (受理から WB grant まで) を持つ。旧コアが別々に持っていた `started`/`done`/`owner` の 3 つのレジスタは、この占有状態 1 つに置き換わる。
- F3. `o_wb.tag` は `i_tag` をそのままコピーしたものである。FU は live な入力から tag を作らない。
- F4. IQ のエントリを解放するのは、FU が受理したときである。blocking FU には登録済みの `o_ready=1` を見てからしか issue しないので、issue すれば必ず受理される。
- F5. 例外と fflags は packet の中で運ぶ。packet の外に sideband は置かない。
- F6. `fu_sys` は oldest token を持つ op しか受け付けない (IQ の select 条件)。CSR の読み出しは live な CSR ファイルから行う。これは「op が最古であり、CSR への書き込みはすべて retire と flush を伴う」ことによって正しい。新しい値、`csr_wr`、SFENCE のオペランドは `commit` が持つ 1 本の `sys_pending` レジスタに渡し、CSR ファイルへの書き込みは retire 時に行う。
- F7. FU が受理した op は必ず完了させる。FU が書いてよいのは packet のフィールドだけである。
- F8. FU 内部の段数と `fu_pkg` の定数が一致することを、elaborate 時に検査する。
- 【決定】スカラの FMA は、M2 では fp_fma の `STAGE3=0` で使う。理由: `STAGE3=1` は rm を 2 つのサイクルで読む (`fp_fma.veryl:211,321`) ので、tag の shift register だけでは毎サイクル投入できない。【M3 で決定】`STAGE3` を使うかどうか: rm を s1a に載せる leaf の修正 (VU 側の挙動は変わらない) の後に、CP の分解でこの段が律速になっているかを見て決める。
- 【決定】`fpu_wrap` は VU 専用として凍結する。スカラの FP FU は leaf から組み立てる。

### 5.7 writeback、wakeup、bypass の方針

所有者: `wb_resv` (予約)、`exec_port`/`mem_pipe` (packet の生成)、`busy_table` (ready/done)。

【決定】深さ規則 2 の具体化として、次の混成方式を採る。

| WB の種別 | 対象 | 規則 |
|---|---|---|
| RESERVED | 各実行ポートの pipelined FU | スケジューラは issue 時に `LATENCY` から WB サイクルを予約する。構造上、1 ポート 1 サイクルに結果は 1 つしか出ず、調停は無い。 |
| HOLE_FILL | ポートに付く可変レイテンシの FU (DIV, FDIV)。memory port 0 の WB に付く `io_unit`, `atomic_unit`, VU の scalar 結果 | 保持中の結果は、登録済みの予約表の中で最も早い空きサイクルを予約する。スケジューラはそれを見て、衝突する issue を控える。grant を出すのは offset が `WAKE_LEAD` 以上のサイクルだけである (依存 op の wakeup を間に合わせるため、§X)。待ち時間の上限は `ISS_TO_ACC` + そのポートの最大 `LATENCY`。grant は登録済み状態から計算するので、同じサイクルの issue に組合せで戻る経路は無い。 |
| LOAD | memory pipe ごとの専用 WB | load hit と LQ からの再 issue は、pipe 自身の固定レイテンシで予約する。ALU とは競合しない。 |

- WB packet は宛先クラス (`pdst.cls`) を運ぶ。各 WB ポートは、そのクラスの PRF に書く。旧コアの `cdb_dest_is_fp` のような、優先順位をなぞる mux (`heliodor_core.veryl:5164`) は作らない。
- `busy_table` の `prf_ready` はスケジュール上の wakeup であり、IQ だけが使う。`prf_done` は値が PRF にあるか、bypass で確実に届くことを示すビットで、bypass の窓の外で値を読む消費者が見る。【決定】`prf_done` は最初の消費者 (M5 の VU の scalar オペランド) ができたときに作る。M1 の `busy_table` は `prf_ready` だけを持つ。理由: 読まれない状態は DEAD scaffolding である (§5.15)。
- memory port は、固定の wake lead と WB の claim offset を公表する。`iq` は `i_load_fence` (未 retire の ld_barrier op より若い load の発行を止める。より古い load は止めない、§L.10) と `i_port_hold[p]` (ポート p への select を止める、MP3 の予約など) を入力に持つ (§L、§X)。
- M1 では投機的な load-hit wakeup を行わない。load の結果に依存する op は、HIT 応答を受けたサイクルに起こす (応答の前に予定で起こすことはしない。§5.9、§L.2)。IQ エントリの解放条件は 1 本の信号 `iq_release` に集約し、M1 では FU 受理と同義とする。投機 wakeup を導入するときは、この信号の定義と cancel 入力の追加だけで済むよう、§X の IQ 設計で保証する。【M3 で決定】投機 wakeup を導入するかどうか: M3 の latency sweep で、load-use 鎖の密度に対する IPC 感度を測って決める。
- bypass の深さは、公表された `LATENCY` と、PRF の書き込みから読み出しまでの距離から導く (§X)。

WB ポート表:

| ポート | cfg_w2 の生産者 | int 書込 | fp 書込 | cfg_w4 の案 (【M3 で決定】) |
|---|---|---|---|---|
| wb0 (実行ポート p0) | ALU, BRU, MUL, SYS; DIV (HOLE_FILL) | ✓ | | p0: ALU, BRU |
| wb1 (実行ポート p1) | ALU, FMA, FMISC; FDIV (HOLE_FILL) | ✓ | ✓ | p1: ALU, BRU |
| wb2..wb5 | (無し) | | | p2: ALU, MUL / p3: ALU, SYS; DIV (HOLE_FILL) / p4: FMA, FMISC (int と fp) / p5: FMA; FDIV (HOLE_FILL) (fp) |
| wbm0 (memory pipe 0) | load; io_unit, atomic_unit (HOLE_FILL) | ✓ | ✓ | 同じ |
| wbm1 (memory pipe 1) | (無し) | | | load |
| 合計 | 3 本 (int 3W, fp 2W) | | | 8 本 (int 7W, fp 4W) |

FU とポートの対応は config パッケージの FU トポロジ表 (`PORT_FU: FuSet [ISSUE_W]`、`PORT_IQ`、`N_IQ`、`MEM_IQ`、`IQ_N[]`、`IQ_NSRC[]`、§3.6) で表す。構成によって変わるのはこの表だけである。cfg_w4 の最終形は、M3 の sweep で FU ごとの使用率を測って決める。

### 5.8 例外の報告経路

所有者: 例外を検出したモジュールが `ExcRec` を作る。trap を取るのは `trap_unit`。

```veryl
struct ExcRec { valid: logic, cause: logic<6>, tval: logic<64>, gpa: logic<54>, gva: logic } // gpa feeds htval (gpa >> 2)
// M5 may add `implicit` (fault during an implicit VS-stage access) depending on the htinst/mtinst decision
```

- 例外 record は op と一緒に、その op の完了まで運ぶ。`rob` はエントリごとに ExcRec を持たず、最古の例外 1 つだけを 1 本のレジスタ `exc_q` に保持する (§C)。発生源は、fetch、decode (合法性)、memory pipe (翻訳、PMP、PMA、misaligned) の 3 つ。
- 1 つの op に複数の cause が該当しうる場所 (fetch、decode と fetch の合流点、memory pipe) では、`exc_pkg::exc_prio` という 1 つの関数で合流させる。この関数は特権仕様の同期例外の優先順位表 (guest page fault の位置を含む) を実装する。
- trap は lane 0 の op だけが起こす。lane i>0 の op が例外を持つ場合、その直前で group を切る。その op は次のサイクルに lane 0 になってから trap する。
- `trap_unit` が cause、tval、htval、GVA、委譲を計算するときは、運ばれてきたフィールドだけを使う。live な MMU 出力は読まない。
- 同期例外の epc はその op の pc とする。割込みの epc は、`commit` が保持する commit 済みの next PC (`arch_next_pc_q`) とする。fetch のポインタは使わない。
- trap した op はアーキ状態に書かない (RAT、PRF の対、CSR、store、reservation のいずれにも)。例外は 1 つだけ文書化しておく: ベクトルの precise fault は vstart と、部分的な VRF への書き込みを残す (M5)。

### 5.9 メモリポート契約

所有者: CPU 側の型と応答は `dcache_port_adapter` (M1-M2) と、M3 で再構築する dcache の CPU 側。要求者の調停は `mem_port_arb`。drain は `sb`。

```veryl
struct MemTag {
    client: MemClient,           // LQ, SQ, PTW_D, PTW_I, AD, ATOMIC, IO, IFU, VU
    id    : logic<MEMID_W>,      // e.g. LqTag; MEMID_W >= the widest of LqTag, SqTag, FtqTag
    rob   : RobTag,              // owner op, valid for back-end clients; every holder applies killed()
}
struct MemReq {
    tag  : MemTag, cls: MemCls, pa: Pa,
    mask : logic<16>,              // bytes within ONE line, up to 2 adjacent dwords
    wdata: logic<128>, attr: pma_pkg::PmaAttr,
}
// MemCls: LOAD, LOAD_EXCL (AMO/LR read with ownership), UNC_READ, PTW_READ, STORE_WT, STORE_EXCL, CMO
struct MemResp {                   // exactly RESP_LAT cycles after accept, one per accepted request
    valid: logic, tag: MemTag,
    kind : RespKind,               // HIT, MISS, RETRY, EXCL_PASS, EXCL_FAIL, PENDING
    data : logic<128>, fill_id: FillId, reason: RetryReason, // FILL_BUSY, INV_RACE, PREEMPTED, WB_BLOCKED, BANK_CONFLICT
}
struct MemEvent {                  // broadcast, all ports
    valid: logic, fill_id: FillId, line: logic<50>, crit: logic<3>,
    kind : EvKind,                 // FILL_START, FILL_CRIT, FILL_DONE, FILL_ABORT, UNC_DONE, WT_DONE
    data : logic<64>,
}
```

不変条件:

- MP1. 要求は valid/ready で 1 回だけ受理される。受理された要求には、ちょうど `RESP_LAT` サイクル後に、応答がちょうど 1 つ返る。`RESP_LAT` はポートが公表する定数であり、load-hit のレイテンシはここから導く。【M1b で決定】`RESP_LAT` の値: adapter の実装で確定させる (Stage-A 提示から Stage-B 判定までの距離で、2 を見込む)。
- MP2. 応答の帰属はタグで決める。fill の帰属は `fill_id` と line で決め、そのとき誰がポートを駆動しているかでは決めない。MISS を受けた要求者は `fill_id` に park する。`FILL_CRIT` (要求した dword と一致する場合) か `FILL_DONE` を受けて再 issue し、`FILL_ABORT` を受けても再 issue する。UNC_READ と STORE_WT は `PENDING` を受け取る。その後の `UNC_DONE`/`WT_DONE` イベントとは、応答の `fill_id` で対応づける。同じサイクルの規則: 応答と同じサイクルに届いた MemEvent は、応答より後に来たものとして扱う (要求者は応答を処理した後の状態でそのイベントを評価する)。
- MP3. ポートの ready は登録済み状態から作る。port 0 を memory pipe 以外の要求者に渡すときは、`mem_port_arb` がサイクル t に登録済み状態から t+1 の m0 の slot を予約し、memory IQ はサイクル t に pipe 0 向けの select をしない (`i_port_hold[0]`)。予約した slot は token として m0 から m2 へ流れ、勝者は token が m2 に達したサイクル A に `MemReq` を出す。A が adapter の受理サイクルである。adapter には、A の 1 サイクル前 (A-1) に立つ登録済みの信号 `p0_resv_next` を与える。これは `mem_port_arb` の決定を token と一緒に m1 まで運んで作る信号で、`i_port_hold[0]` とは別物である。adapter は A-1 に fold 群 (Stage-A の折り返し読み、§M.2.1 と §1.6) をすべて RETRY させて B 位置を空け、A に nf 群 (fold できない要求) を受理する (§M.2.1)。memory pipe が段の途中で ready=0 に出会うことは無く、あるのは RETRY 応答だけである。
- MP4. `mem_port_arb` は飢餓を起こさない。要求者クラスごとの待ちの上限 B を、モジュールのヘッダに書く。
- MP5. misaligned の扱い: スカラの cacheable な load/store の misaligned は cause 4/6 を起こさず、ハードウェアが line 境界で分割する (line をまたぐ load は M1-M2 では oldest token を持つときだけ実行する。line をまたぐ store は SQ エントリの 2 つの半分として通常どおり実行する、§L.15)。misaligned の AMO/LR/SC はアクセス fault (cause 5/7)。vector の misaligned 要素は cause 4/6 (§V)。NC/IO の misaligned はアクセス fault (§5.14)。分割は LSU が line 境界で行う。1 要求の範囲は 1 line 内の、隣接する最大 2 dword までとする。2 つの半分は、どちらも翻訳と PMP/PMA 検査を済ませてからでないと、どちらも書き込まない。【決定】理由: 自然整列した 16 B 領域は 64 B line をまたがないので、Zama16b の原子性が保たれる。また hi dword を別線で送る仕組み (旧 `o_dmem_wdata_hi`、hi-strobe の漏れで 5f60630 を起こした) が不要になる。これに合わせて ACT4 の `MISALIGNED_MAX_ATOMICITY_GRANULE_SIZE` を 4096 から 64 に下げる (M2)。
- MP6. exclusive write (`STORE_EXCL`) は、試行したサイクルで PASS か FAIL に確定する。PASS は最終的なもの。owned な hit に余計なサイクルを足してはならない (競合する atomic の livelock を防ぐため)。
- MP7. store の drain は、専用の line 幅の書込ポート 1 本で行う。駆動するのは `sb` の head だけなので、構造上「駆動者 = 持ち主」が成り立つ。可視性の契約 (所有者 `sb`): drain が ack されたサイクル t の store は、t+1 より前に data array を snapshot したすべての load が forward の判定を終えるまで、forward 網から見え続ける。shadow の長さは、load pipe の snapshot から forward までの距離から導く。`sb` は `ordering_empty` と `resource_empty` を別々の出力として出す。待つ側 (FENCE, IO, atomic, VU) は `ordering_empty` を使い、これには `atomic_unit` の待ち行列も含める。
- MP8. 一貫性イベント (inv, inv2, evict) は、そのまま `lq` (CoRR) と `atomic_unit` (reservation と watch) に渡す。

能力表 (要求クラス × ポート):

| クラス | 要求者 | port 0 | port ≥1 | drain |
|---|---|---|---|---|
| LOAD (LQ からの再 issue を含む) | `mem_pipe` / `lq` | ✓ | ✓ | |
| UNC_READ | `io_unit` | ✓ | | |
| PTW_READ | D-`ptw` | ✓ | | |
| LOAD_EXCL / STORE_EXCL | `atomic_unit` | ✓ | | |
| STORE_WT | `io_unit` (IO store) | ✓ | | |
| A/D 書き込み (AD) | I/D 両方の `ptw` の A/D 更新。M1-M3 は STORE_WT、M4 から owned RMW (LOAD_EXCL + STORE_EXCL) | ✓ | | |
| CMO | `io_unit` だけ: uncached な DRAM アクセスの前に、自 hart の line を clean する (§5.11 の M2 基本線) | ✓ | | |
| VU の要素アクセス (M5) | `vu_mem_adapter`。mem_pipe 0 の issue slot を使う client で、forwarding も load 整形も行わず、128 bit の生の応答を受ける | ✓ | | |
| vector store (M5) | `sb.i_vu_push` から `sb` に入る | | | ✓ |
| committed store の line | `sb` | | | ✓ |

- 【決定】D-PTW は port 0 のタグ付き client とする。理由: タグ付き応答によって、orphan walk 中に replay が i_addr を上書きし、load のデータが PTE として install された事故の類が構造的に消える。L2 直結にすると mem_ctrl に第 3 の slot クラスが要る。【M3 で決定】L2 直結への変更は、W4 の sweep で port 0 の占有率をクラス別に測り、PTW が上位 2 位以内に入った場合に限って評価する。
- 【決定】A/D ビットの書き込みは AD クラスとして port 0 に出す。要求者は I/D 両方の walker。M1-M3 では STORE_WT、M4 からは owned RMW (LOAD_EXCL + STORE_EXCL) とする。7.1 は ADUE=1 で動くため、M4 で必要になる。
- cbo.clean/flush/inval の命令はメモリ要求を出さない (§5.5。完全に coherent なプラットフォームでは no-op)。cbo.zero は `sb` を通る store である。
- 【決定】M1-M2 では、再利用する単一 fill の dcache を `dcache_port_adapter` で包み、最終形の型を見せる。dcache を M1 から作り直す案は、M3 の 2 ポート化と同じ作業を 2 回することになるので採らない。adapter の規則 (保持 slot、判定表、HOLD と空の世代、`fill_id` の採番、kill による取り消し、論理ポートの調停) の正本は §M.2 である。要点: slot を取り消せるのは fill の開始前だけで、物理経路に入れなかった論理ポートは port 0 を含めて RETRY(BANK_CONFLICT) を受ける。勝者は予約が無い限り `MemTag.rob` の古い方なので、最古の load は衝突に負けない (§M.2.6)。
  - 保持 slot は 1 つで M1 の 1 エントリ MSHR を兼ねる。主ポートの駆動は要求の群で異なる (fold 群と nf 群、§M.2.1)。判定は `o_stall` だけからは作らず、E1 の latch 値と E3 の分解した項から作る (`o_miss_valid`/`o_miss_offset` は使わない)。判定表は §M.2.3、過渡的な stall での HOLD と空の世代は §M.2.4 にある。
- 【決定】dcache への変更は追加の出力だけとする (§4.4、export の一覧は §M.2.2)。
- 【決定】M3 の MSHR file は dcache の中に line 単位で置き、LQ は load ごとの待ち状態を `fill_id` をキーに持つ。M3 では fill_id が {MSHR index, 世代} に変わるが、LQ 側は変わらない。M3 が作るのは構造だけで、`MSHR_N` を 1 より大きくする条件は §2.5 の M4 行が定める。各イベントには、エントリ自身が latch した {line, dword} を載せ、ポート由来のフィールドは使わない。理由: live なポートの値を拾うと、イベントが別の要求の dword と組になる (§M.6.4)。

### 5.10 翻訳要求の契約

所有者: `tlb` (lookup)、`ptw` (walk と epoch)、`mem_pipe`/`ifu` (要求者)。

```veryl
struct XlateReq  { valid: logic, tag: MemTag, va: logic<64>, acc: AccKind, hlv: logic, hlvx: logic, // acc: LOAD, STORE, AMO, FETCH
                   nonspec: logic }   // D-bit update allowed: set only on an accept edge where the op holds the token (section 5.13.1)
struct XlateResp { valid: logic, tag: MemTag, hit: logic, pa: Pa, pma: pma_pkg::PmaAttr, exc: exc_pkg::ExcRec,
                   need_d: logic }    // store/AMO hit a W=1, D=0 entry with ADUE=1: PA not final, retry with nonspec
struct PtwEvent  { valid: logic, key: PtwKey, fault: logic }  // key = {vpn, regime}; broadcast on every walk completion
```

- X1. 権限の文脈 (実効特権、SUM、MXR、MPRV、V、satp/vsatp/hgatp) は、lookup 時に CSR ファイルから読む。これが正しいのは、翻訳の文脈を変える操作がすべて flush を伴う retire であり (§5.5)、実行中の op はどれもその変更より若いからである。HLV/HLVX は op ごとの属性として運ぶ。
- X2. epoch: `ptw` は walk の開始時に文脈と epoch を latch する。epoch は full kill のたびに増える。walk の完了時に epoch が一致していれば TLB に install する (fill は常に許す: kill された op のための翻訳であっても、正しい翻訳を cache することはアーキ上問題ない)。walk 要求は owner の RobTag を運ぶ (`MemTag.rob`)。walk の owner は、成功でも fault でも完全な XlateResp を受け取り、kill 済みのタグ宛てなら捨てる。fault を含むすべての walk の完了は `PtwEvent {valid, key (vpn, regime), fault}` を broadcast し、park している待ち手 (合流した要求者) は lookup をやり直す (§M)。同じサイクルの規則 (MP2 と同じ形): walk 要求が受理されたサイクル r から、その要求者が park を記録する edge までの間に届いた同じキーの `PtwEvent` は、park の後に来たものとして扱う。要求者 (`mem_pipe` の段レジスタ) は r 以降の event を自分のキーと比較して印を運び、印があれば park せずに READY として記録する。理由: m1 で合流した walk が m1 か m2 で完了すると、park の前に event が過ぎ去り、他に walk が無ければその load は永久に待つ。
- X3. TLB miss は非ブロッキングで扱う。miss した load は LQ で待つ。要求者が VA を再提示することに依存しない。
- X4. TLB の lookup は副作用を持たず、どのサイクルでも捨ててよい。walk を始める方法は、`ptw` の要求キューへの valid/ready 要求だけである。walk 要求を出せるのは、LQ/SQ に割り当て済みで (タグを持つ) まだ kill されていない op (LR も LQ に割り当てる、§L.3)、`ifu`、M5 からは VU の要素アクセス (`vu_mem_adapter`、VEC op の RobTag を owner とする、§V.4) だけである。要求者は、walk の間もポートや MMU の FSM 状態を保持しない。I 側では、walk を始めてよいのは最古の未 fetch block (f1 にあるもの) だけである。walk の重複排除 (同じ VPN と文脈への要求をまとめる) と要求キューの深さは §M で決める。
- X5. satp の shadow (旧コアの `satp_shadow` や偽の ifault 注入) は持たない。MMU は retire した瞬間の CSR 値を使う。

翻訳の文脈を変える CSR と命令の完全なリスト (どれも §5.5 の flush 規則で覆われる。白リスト化するときは、このリストが必要条件になる): `satp`, `vsatp`, `hgatp`, `mstatus` (MPRV, MPP, MPV, MXR, SUM, GVA), `sstatus` (SUM, MXR), `vsstatus` (SUM, MXR), `hstatus` (SPV, SPVP, HU, VTVM), `menvcfg`/`henvcfg`/`senvcfg` (PBMTE, ADUE, PMM), `mseccfg` (PMM), `pmpcfg0-15`, `pmpaddr0-63`。命令: SFENCE.VMA, SINVAL.VMA, SFENCE.W.INVAL, SFENCE.INVAL.IR, HFENCE.VVMA, HFENCE.GVMA, HINVAL.*, MRET, SRET、および trap の受付。

### 5.11 PMA とプラットフォームマップ

所有者: `pma_pkg` (型と関数)。領域表は SoC が持つ (`heliodor_soc_smp` のパラメータ)。

```veryl
struct PmaAttr {
    target: Target, backed: logic, cacheable: logic, coherent: logic, executable: logic,
    amo: AmoClass,          // NONE, LRSC, FULL
    idempotent: logic,      // speculative read allowed
    io_ordered: logic,      // strongly ordered, non-speculative
    misaligned_ok: logic, pte_ok: logic, cbo_ok: logic,
}
struct PmaRegion { base: Pa, mask: Pa, attr: PmaAttr }   // naturally aligned power-of-two regions
function pma_check (pa: input Pa, tbl: input PmaRegion [N]) -> PmaAttr; // mask compare per region, one-hot OR; no hit = hole
```

- PM1. 物理アドレスのデコードは、`pma_check` を通す 1 か所だけで行う。core の IFU/LSU/MMU も、SoC のデコードも同じ関数を使う。旧コアの 32 MiB 窓 (`PA[63:25]==39'h40`、10 か所)、tohost の窓 (7 か所)、PA[31] だけを見る SoC のデコード、MMU の PMA_FAULT による hole 判定は、すべてこれに置き換える。
- PM2. `pma_check` は、op ごと・ポートごとに翻訳の時点で 1 回だけ、`pmp_check` と並べて評価する。結果は LQ/SQ のエントリ (fetch の場合は fetch block) に格納し、消費者はすべてエントリのビットを読む (深さ規則 3)。
- PM3. Svpbmt との合成: NC は `cacheable=0, idempotent=1, io_ordered=0`、IO は `cacheable=0, idempotent=0, io_ordered=1` とする。PBMT は属性を厳しくする方向にしか変えられない。PTE の読み出しは PBMT を見ずに `pma_check(pte_pa)` で判定し、`pte_ok=0` ならアクセス fault とする。
- PM4. どの領域にも当たらない PA は hole であり、アクセス fault とする。PA は 56 bit 全体でデコードし、上位ビットを捨てたエイリアスを作らない。
- PM5. tohost は PMA にも core にも存在しない。検出は retire ポート (`mem_paddr == TOHOST_PA && wmask != 0`) で行う (D3)。
- PM6. DTS と ACT4 の `sail.json` の領域定義は、同じ表と照合するスクリプトでゲート上で検査する (§S.2 と検証計画 §2.2)。同じスクリプトが、表の全領域で `pte_ok` ならば `cacheable && coherent` であることも検査する (PTE は coherent な cache 経由でしか読み書きしないため)。
- PM7. mem_ctrl に line 要求か single-beat 要求かを伝えるのは、要求者の属性である。SoC のアドレスデコードではない。
- 【M2 で決定】DRAM 内の Svpbmt NC/IO: 基本線は、uncached 経路と mem_ctrl の single-beat DRAM 読み書きで実装し、自 hart の dirty line は事前に clean する。M2 で ACT4 の Svpbmt テストと `svpbmt_test` がこの基本線で通ることを確認して確定する。旧コアは load と store で扱いが食い違っていたため (推定)、この領域は trace diff の対象外とする (D4)。

### 5.12 commit group 規則と retire record

所有者: `commit` (group 関数と retire record)。`rob` は oldest token とエントリの読み出しを出す。

group 関数は lane `l` ごとに outcome を求める。outcome は `{WAIT, RETIRE, RETIRE_FLUSH(kind, pc), TRAP(exc), REPLAY(pc)}` のいずれか。

- C1. lane `l` が retire するのは、outcome が RETIRE か RETIRE_FLUSH で、より古い lane がすべて retire して group を閉じておらず (RETIRE_FLUSH と alone は group の最年少になる)、lane 0 以外では alone/例外/poison で group が切られず、store の予算と lockstep の上限を満たし、割込みを受け付けておらず、その op が kill されていないときである。式の正本は §C.2.2 の retire 式で、ここには書かない (`alone` は IO アクセスの遅延属性を `alone_eff` として合成したもの)。
- oldest token は登録済みの head 状態から計算する。より古い op が retire するのと同じサイクルに、次の op へ token を渡すことはしない (token の付与は retire の 1 サイクル後になる。時刻を読む op などが決定的になる)。
- C2. 連続する lane だけが retire する。TRAP、REPLAY、割込みは、group の先頭 (lane 0) の op に対してだけ作用する。1 サイクルに flush は最大 1 つ (RETIRE_FLUSH、TRAP、REPLAY、割込みのどれか 1 つ)。
- C3. retire は ack を意味し、すべての副作用を駆動する。具体的には、arch RAT の更新と旧 pdst の解放、LQ/SQ のポインタ前進、`sb` への push、CSR への書き込み (`sys_pending` 経由、lane 0 だけ)、fflags の OR、FS/VS の dirty 化、vset/vstart、reservation と watch の解除、FENCE.I による icache の invalidate、予測器の更新 (FTQ の commit ポインタ)、`arch_next_pc_q`、retire record、instret。どれも `retire[l]` だけを条件にし、「head が valid であること」を条件にしない。
- C4. control op を含め、すべての lane が retire しうる。lane ごとの next PC の検査 (T8) を、lane ごとに独立に行う。
- C5. store は、PA とデータを持ち、fault が無く (IO store はさらに WT_DONE を受けていて、§C.2.2)、`sb` に空きがあれば、どの lane でも retire できる (予算: 1 サイクルの store は MEM_W 個まで、push する line は `PUSH_W` 本まで。line をまたぐ store は 2 本を使う)。retire は単なるポインタの前進であり、commit は TLB を再駆動しないし、SB との merge の一致も待たない。
- C6. `drain=1` の op は、`sb.ordering_empty` が成立するまで WAIT とする。MP7 により `ordering_empty` は `atomic_unit` の待ち行列も含むので、store と atomic を区別する別の条件は持たない。
- C7. REPLAY (順序違反で poison された load) は、retire させず、record も出さずに、full kill してその op 自身の pc から refetch する (D5: commit 時の replay)。poison を判定するのは `lq` であり、REPLAY の発生源は `lq` だけである (D8: atomic の失敗は `atomic_unit` の内部で再試行し、commit には届かない)。
- C8. instret は `popcount(retire[l] && !trap)` (幅 `RETIRE_CNT_W`) とし、`csr.i_instret_cnt` に与える。minstret に書く CSR op は alone なので、そのサイクルの増分は書き込みで抑止される (現行の csr の意味論と同じ)。

retire record (`retire_pkg::RetireRec`、lane ごと)。record は retire の 1 サイクル後に登録して出す (§C):

| フィールド | 意味 |
|---|---|
| `valid` | この lane が retire したか、または同期例外の trap を起こした (trap record)。replay と kill された op は record を出さない。 |
| `order` (64) | 単調増加。trap record も 1 つ消費する。 |
| `pc`, `next_pc` | `next_pc` はアーキ上の次 PC。trap record では trap ベクタではなく 0 とする (飛び先は次の record の pc で分かる)。 |
| `insn` (32), `is_rvc` | 展開後の 32 bit 命令と、RVC かどうか。【決定】理由: ROB が持っているのは展開形であり、golden も同じ形を出す。fetch fault の record の insn は不定 (比較対象外)。 |
| `trap`, `cause`, `tval` | 同期例外。trap record は lane 0 にしか現れない。 |
| `priv`, `virt` | retire 時点のモード。 |
| `rd_kind` {NONE, INT, FP}, `rd_addr`, `rd_wdata` | trap では NONE。何も書かないときは 0。FP の値は NaN-boxing 後の 64 bit。 |
| `rd2_valid`, `rd2_wdata` | amocas.q が書くレジスタ対の 2 本目。 |
| `mem_size`, `mem_vaddr`, `mem_paddr`, `mem_io` | アクセスの先頭バイト。split アクセスでも `mem_paddr` は先頭側の PA だけ。 |
| `mem_rmask`, `mem_wmask`, `mem_rdata`, `mem_wdata` (+ `_hi`) | 値は右詰めで size バイト。AMO では rdata が旧値、wdata が新値。`_hi` は 16 B アクセスの上位側。 |
| `csr_valid`, `csr_addr`, `csr_wdata` | `csr_wr=1` のときだけ。CSR 書き込みポートに与えた値 (WARL 正規化の前)。 |
| `fflags` (5) | この op が立てた fflags。 |
| `vec_v`, `vrf_wcnt`, `vrf_hash`, `vtype`, `vl`, `vstart` | vector op の観測 (VRF に書いた要素数と、書いた内容のハッシュ、retire 後の vtype/vl/vstart)。M5 までは 0。D1 のパッチは v1 からこのフィールドを持つ。 |

割込み event (`IrqEvent`): `{valid, cause, epc, order}`。`order` は次の record の order であり、event 自体は order を消費しない。lane の record が無いサイクルにだけ出る。

- lane の位置は比較対象ではない。trace diff は、record を order 順に直列化した列を比較する。golden の adapter は (偽 ifault の正規化などで) 別の lane に record を置いてもよい。
- 正規化規則と MASK 対象 (counter CSR の読み出し、旧コアの minstret、偽 ifault の窓、不正な RVC の tval、rd=x0 の load の `mem_rdata` (LQ はデータを持たないので再構成できない) など) は、tracer と golden adapter の両方の隣に書く (検証計画、D4)。

### 5.13 割込みの受付点

所有者: `commit` (受付の判定と oldest token の gate)、`trap_unit` (cause と epc)。

- I1. pending は csr の (mip & mie & 委譲 & 特権による有効化) を 1 サイクル登録した `irq_q` を使う。
- I2. flush-at-head: `take = irq_q.pending && !head_started_q && 許可 && !kill.valid` が成り立ち、かつ直前のサイクルに pending に影響するアーキ状態を変える retire が無いサイクルには、lane を 1 つも retire させない。`flush_ctrl` が full kill をかけ、`trap_unit` が `epc = arch_next_pc_q` で trap を取る。head の op はまだ retire していないので、ハンドラから戻った後に再実行される。`kill.valid` のサイクルと、アーキ状態を変える retire の次のサイクル (このとき `irq_q` は 1 サイクル古い) には take しない。そのような retire (CSR 書き込み、xRET、trap) はすべて full kill を伴い、その kill が古い `irq_q` のサイクルに重なるので、実装上は `!kill.valid` の項が両方を担う (§C.2.6)。pending に影響するアーキ状態を full kill 無しで変える retire を足すときは、この論拠を見直す。
- I3. 取り消せない操作を始めた op を中断しない。取り消せない操作とその開始点、開始後の手順の扱いは §5.13.1 が定める。開始した op が retire する (または自分の trap で終わる) まで `head_started_q=1` であり、その間割込みは待つ。
- I4. 割込みが pending かつ許可されている間は、oldest token を出さない。これで新たに取り消せない操作が始まることはなくなる。既に始まった操作は token ではなく自分の started latch で進むので (§5.13.1)、token を止めても止まらず、retire した時点で割込みが受け付けられる。したがって割込みは有界時間内に必ず受け付けられる。
- I5. oldest token: `nonspec_ok = oldest.valid && !(irq_q.pending && 許可) && !(retire_limit_en && order_q >= retire_limit) && !kill.valid`。

デバッグ入力の意味 (D2):

| 入力 | 意味 |
|---|---|
| `i_dbg_retire_limit_en`, `i_dbg_retire_limit` (64) | lane l は `order_q + l < limit` のときにだけ retire できる。`order_q == limit` の op は oldest token を受け取らないので、取り消せない操作を始めない。 |
| `i_dbg_irq_mask` | 1 のとき、割込みを受け付けない (pending は保持される)。 |
| `i_dbg_irq_allow` | 1 のとき、`i_dbg_retire_limit_en=1` かつ `order_q == limit` の境界に限って mask を無視して受け付ける。`limit_en=0` なら allow は効かない (式の正本は §C.2.6 の `irq_ok`)。 |

replay の手順 (tb が行う): golden の (K, cause) ごとに、`limit=K, limit_en=1, mask=1, allow=1` を設定する。コアは order K-1 まで retire して境界で止まり、`irq_q.pending` が立っていれば受け付ける。tb は event の cause が golden の cause と一致することを assert する。一定サイクル以内に event が出なければ、「golden の割込みが自コアで pending でない」として失敗とする。

- WFI は合法なら NOP (D2。U-mode と TW=1 の S-mode では不正命令、§C.8)。lockstep で mtime を retire 数から進める tick は SoC が作る (§S.5、検証計画)。コアは `i_mtime` を読むだけである。

#### 5.13.1 取り消せない操作のライフサイクル

取り消せない操作とは、一度メモリやデバイスや CSR に届いたら、kill しても効果が戻らない操作である。所有者は各 unit (下表) と `commit` (`head_started_q`)。

| unit | 操作 | 開始点 (最初の要求が受理される edge) | 開始後に同じ op が繰り返す手順 |
|---|---|---|---|
| `fu_sys` | SYS の実行 (CSR の読み、`sys_pending` への書き込み) | FU の受理 | なし |
| `io_unit` | IO load の `UNC_READ`、IO store の `STORE_WT` | adapter が要求を受理した edge | RETRY を受けた後の再要求 |
| `atomic_unit` | LR、AMO、SC、amocas の `LOAD_EXCL` と `STORE_EXCL` | 最初の `LOAD_EXCL` (SC は `STORE_EXCL`) を adapter が受理した edge | MISS と FILL_DONE の後の再要求、RETRY の後の再要求、D8 の FAIL と watch による読み直し、`STORE_EXCL` |
| `sq` | D ビットを立てる `nonspec` walk (§L.16、§M.8.4)。atomic の分も SQ エントリが出す | `ptw` の要求キューが `nonspec=1` の要求を受理した edge | walk の完了後に STA を完了させる再 issue |
| `vu_adapter` (M5) | VU の実行 (要素アクセス、VRF 書き込み) | 最初の exec 許可 (`exec_q`、§V.3 VA2) | 要素ごとの要求 |

状態 (unit ごとに 1 組。開始できる op は最古の 1 つだけなので、エントリごとには持たない):

```
IDLE --(受理 edge で token.valid && token.tag == 自分の tag)--> STARTED --(自分の retire、または自分の trap による full kill)--> IDLE
  STARTED の間: started_q = 1、o_started パルスは受理 edge の 1 回だけ
```

規則:

- IR1 (実行許可の latch)。unit は開始点の受理 edge で `started_q` を立てる。開始後に同じ op が出す要求 (上表の右列) の資格は `started_q` だけで決め、その時点の token は見ない。`mem_port_arb` の HEAD クラスへの要求資格も「token のタグが自分と等しい、または `started_q`」である (§L.14)。理由: I4 により割込みが pending の間は token が止まるので、開始後の手順が token を要すると、割込み (I2 で `head_started_q` を待つ) と op (token を待つ) が互いを待ってデッドロックする。
- IR2 (`head_started_q`)。`commit.head_started_q` は各 unit の `o_started` パルスの OR で立ち、lane 0 の retire、trap、full kill で落ちる。各 unit の `started_q` と同じ事象で落ちるので、`head_started_q` は常に `started_q` の OR に等しい (checker `chk_oldest`)。`head_started_q` が立っている間、割込みは受け付けない (I2)。その op の進行は token を必要としない (IR1)。
- IR3 (窓が無いこと)。token は開始点の受理と同じサイクルに組合せで照合する。slot を要求した時点や、slot token が m0 にあった時点の token では照合しない。そのサイクルの token は `irq_take` と同じ登録済みの `irq_q` と `!kill.valid` から作るので (I5)、受理と `irq_take` は同じサイクルに両立しない。受理の次のサイクルからは `head_started_q=1` である。したがって「token を確かめた後、要求が届く前に割込みを受け付ける」窓は無い。受理の瞬間に token を失っていたら、unit は要求を出さず、その slot は空のまま終わる。
- IR4 (開始した op は kill されない)。不変条件 (所有者 `commit`、`flush_ctrl`。checker `chk_oldest`): `started_q` が立っている op は、自分の retire (RETIRE_FLUSH を含む) か自分の trap による full kill 以外では `killed()` に選ばれない。根拠: その op は最古なので、より古い分岐が無く、部分 kill の keep はその op 以上である。full kill の発生源のうち、割込みは `head_started_q` で止まり、REPLAY は poison された load にしか起きず (IO/NC の load は poison されない、§5.14)、他の op の RETIRE_FLUSH や trap は、より古い op が無いので起きない。
- IR5 (`nonspec` の walk)。`XlateReq.nonspec=1` を付けてよいのは、IR3 と同じ照合で token を持つ受理 edge か、`sq` の `started_q` が立った後の要求だけである。`ptw` は `nonspec` の walk の PTE 書き込み (D ビット) を、owner が有効な間しか出さない。IR4 により owner は落ちないはずなので、owner を落とした `nonspec` walk が書き込みに達したら checker が flag を立てる。投機的な A ビットの書き込みはこの規則の外にある (§L.16)。

### 5.14 I/O と非冪等アクセスの規則

所有者: `io_unit` (実行)、`lq`/`sq` (属性と park)、`commit` (retire の条件)。

| 規則 | 内容 |
|---|---|
| 分類 | 翻訳時に `PmaAttr` を求め (§5.11)、LQ/SQ のエントリに格納する。それより前に、cacheable かどうかを推測で決めない。 |
| IO load の待機 | 翻訳までは投機的に進めてよい。その後は LQ に park し、cache にもバスにも要求を出さない。 |
| IO load の発行 | 発行できるのは、自分のタグが oldest token と等しく、`sb.ordering_empty`、`atomic_unit` が空、未完了の IO store が無い、のすべてが成り立つときだけ。割込みが pending なら token は出ないので、割込みは発行の前に受け付けられる。 |
| IO load の一回性 | 1 op につき要求は 1 つ (port 0 の UNC_READ、タグは LqTag)。応答は `io_unit` の 1 本の結果レジスタで捕捉し (IO アクセスは hart あたり同時に 1 つだけ)、WB は HOLE_FILL で行う。LQ のエントリは完了だけを記録する。受理された後は、flush も、forward の受け手になることも、poison も、replay もされない (I3)。 |
| IO store | non-posted。より古いすべての store が見えた (`ordering_empty`) 後に、`io_unit` が STORE_WT として 1 回だけ発行する。retire は WT_DONE を受けた後。受理された後に再提示しない。SB には入らない。 |
| forwarding | IO の store は forward の送り手にならず、IO の load は forward の受け手にならない。 |
| misaligned、AMO、LR/SC | NC/IO 領域に対しては、翻訳時にアクセス fault (load は cause 5、store/AMO は cause 7) とする。分割はしない。 |
| fetch | `executable=0` の領域からの fetch は、命令アクセス fault とする。 |
| NC の load | M1-M2 では IO と同じく head でだけ発行する。【M3 で決定】投機的な発行を許すかどうか: boot と bench で NC load の発生数を測り、0 であれば head 発行のまま確定する。 |
| VU の IO アクセス | 【M5 で決定】fault にするか、head で要素ごとに直列化するか: vector テスト群と boot に IO 領域への vector アクセスがあるかを数え、0 なら fault にする (§V)。 |

検証側の obligation: SoC のモニタが、IO 領域に対する hart ごとのデバイス読み書き enable を、retire record の `mem_io` と回数・アドレス順で照合する (検証計画)。boot ではデバイス読み出しの副作用が一度も起きないので、この規則は自己検査型の directed test で守る。

### 5.15 命名、モジュールヘッダ、コメント規約とレビューゲート

命名:

| 対象 | 規約 |
|---|---|
| モジュール | snake_case の概念名詞 (`rob`, `mem_pipe`)。旧コアは `v14_` prefix。 |
| ポート | `i_`/`o_` prefix。ハンドシェイクは `_valid`/`_ready`。 |
| 段 prefix | `p<n>_` (bpu), `f<n>_` (fetch), `x_` (extract), `d_` (decode), `rn_` (rename と dispatch。同じ段、§R), `is_` (select), `rr_` (register read), `ex<n>_` (execute), `m<n>_` (memory pipe), `wb_`, `cm_` (commit)。 |
| レジスタ | 出力が登録済みの変数は `_q`。 |
| 型、定数、関数 | 型は PascalCase、定数は UPPER_SNAKE、関数は snake_case。 |
| lane の添字 | lane は `l`、ポートは `p`、エントリは `e`。 |

モジュールヘッダの書式 (英語):

```
// <module>: <one-line responsibility>
//
// Ports (timing contract):
//   i_x_valid/i_x : group handshake, lanes contiguous from lane 0
//   o_x_ready     : registered state only
//   o_y           : registered, valid N cycles after accept
//   i_kill        : applied on the capture edge of every entry and stage
// Owns:
//   - <invariant this module guarantees, as a checkable statement>
// Rationale:
//   - <design-specific choice and why; omit if none>
```

RTL 規約:

- 直列リデュースを書かない。N エントリにわたる compare-select、加算、カウント、mux を `acc = f(acc, x[i])` の形で書かず、`tree_pkg` の木や prefix の helper を使う。新しい木を作ったら、`tb/test_vmspre.veryl` の型で直列参照との等価性を検証する。【決定】理由: synth は argmin の鎖を再構成しない。また 64K cell を超えるモジュールでは再構成自体を止める。
- `break` を含むループを書かない。first-match は prefix で書く。
- one-hot mux は AND-OR で書き、優先順位の if 鎖では書かない。
- 頻繁に書き換える配列は、エントリごとに decode した 1 か所の書き込みにする。
- RTL の中に `$display`/`$assert` を置かない (cc backend は whole-comb ごと bail する)。観測はポート経由で行う。
- すべての valid bit を reset する。`if_reset` の else の後に文を書かない。
- 部分的にしか組み立てない struct 出力を作らない。
- DEAD scaffolding を置かない: const で守られた arm、値を読まれない計測用カウンタ、使われない予約状態はいずれも禁止。
- タグ型のレジスタを持つモジュールは、必ず `i_kill: Kill` ポートを持つ (grep で検査する)。
- `$readmemh` の対象は tb の中にだけ置く。

レビューゲート:

| ゲート | 内容 |
|---|---|
| cold-reader | プロジェクトに関わっていないレビュア (人、または本書とそのモジュールのソースだけを渡した新しい Claude セッション) が、ポートの意味とタイミング、モジュールが所有する不変条件、非標準的な選択の理由を説明できること。旧コアや経緯を読まなければ答えられない質問が出たら、それはヘッダの欠陥とみなす。モジュールを初めて取り込むマイルストーンで実施する。 |
| 発火カウンタ | 各機構 (RETRY の理由ごと、kill の種別ごと、予算による group 切断の理由ごと、forward の hit、walk、replay、HOLE_FILL の待ち) は `o_perf` に event wire を出し、tb で数える。どの機構も、少なくとも 1 つのゲートで 0 より大きくなければならない。どこでも 0 のままなら、未テスト (directed test を足す) か dead (消す) かのどちらかである。ビット一致の結果は「発火しなかった」と読む。 |
| invariant checker | `chk_*` モジュールは観測専用で、出力を設計論理に戻さない。sticky flag を `o_chk` に出し、tb はすべてのテストの終わりに 0 であることを確認する。最低限の項目: kill 後に kill 済みのタグが残っていないか、kill のサイクルに割り当てが無いか、二重 writeback、未割り当ての ROB エントリへの完了、RAT の重複マッピング、free list の漏れと重複、未知のタグへのメモリ応答。【M1a で決定】synth からの除外方法: `#[ifdef]` で外すか、モジュール別の面積から差し引くかを、spike で決める。 |
| lint 差分 | 新しいモジュールは警告 0。veryl を更新したら、警告を種類ごとに数えて差分を取る。新しく増えた種類はバグ報告として扱う。 |
| シミュレーション速度 | 各マイルストーンで `VERYL_AOT_C_DIAG=1` の whole-comb fallback が 0 であること、cy/s を記録すること。 |
| ブランチ実験 | 計測用の変種はブランチで行い、master に knob として残さない。 |

---

## §F フロントエンド

所有範囲: `bpu`, `ftq`, `ifu`, `extract`, `icache` の CPU 側と I read slot。加えて、fetch 側での `tlb`(I)/`ptw`(I) の使い方、FENCE.I、`flush_ctrl` が出す Redirect の消費。`decode` は受け渡し (§F.8) までを扱う。`decode` の中身 (OpClass と合法性) は §5.5 と §R、`tlb`/`ptw` の内部は §M、Redirect と Kill の生成は §C が持つ。

### F.1 構造と、選択を決めた測定値

```
 bpu --BlockPred--> ftq --entry--> ifu [f0 ITLB | f1 icache req | f2 resp] --FetchBlk--> extract [x0 | x1] --XOp[FETCH_W]--> decode[FETCH_W] --> rename (§R)
  ^                 ^ ^ ^            |  fetch buffer (FBQ)    |                            decode queue (DQ)  |
  | recover/update  | | +-- cm      +-- ptw(I) --- I read slot (islot_arb)                                   |
  +-----------------+ +--- pc/pred read (BRU ports only)                   pd writeback / PdRedirect <--------+
```

| 旧コアでの測定 | 値 | この設計での帰結 |
|---|---|---|
| Block W 後の N=1 boot で front end が空だったサイクル | 19.5 % (`doc/phase14_frontend_deep_ooo_plan.md:2443`) | 供給は律速の一つ。幅だけ広げても供給が伴わなければ効かない (rename slot 1 の制限を外して 2-wide rename を +26 % 発火させても、boot は -0.21 %。`doc/phase14_frontend_deep_ooo_plan.md:2252` 以降)。 |
| W2b census: fetch-ahead FIFO が空だったサイクルの内訳 | 74 % が icache miss (容量)。run-ahead の不一致は 0.3 % (`heliodor_core.veryl:4110-4118`) | L1I 32 KiB を維持し、run-ahead の仕掛けを凝らさない。miss 処理の拡張 (prefetch、2 本目の fill) は M3 の測定で決める。 |
| FTQ の深さの価値 (`doc/cp_predictor_sram_plan.md:1993`) | 予測器を extract の位置で読むかぎり 0。per-dword producer では FTQ の平均深さ 0.026 | 予測器は FTQ の上流 (block ポインタ) で読む。そうすれば FTQ の深さが bpu の bubble と miss を隠す。 |
| clocked 予測器一式のコスト (`doc/cp_predictor_sram_plan.md:3456`) | coremark +14.8 % (うち 72 % が front end idle)、boot 約 +2 % | 予測器のレイテンシを公表し、run-ahead で隠れる位置に置く。 |
| cancel できない next-line prefetch | boot +1.31 % (悪化) | M1 は prefetch を持たない。 |
| Block W 以前の slot-1 喪失 | boot 2.93M サイクル (straddle と line 越え) | 固定 2 slot をやめ、block 内で一様な N lane にする。 |
| icache の 512-bit 読み | 256-bit の約 6 倍のシミュレーション時間 | `FETCH_BYTES ≤ 32` (icache 内部 block 幅) を構造制約にする。 |

設計原則:

- F-P1. 予測は block 単位で、FTQ の上流で行う。FTQ は block 記述子のリングであり、予測メタデータ、history/RAS の checkpoint、PC の唯一の保持者を兼ねる。
- F-P2. deliver, don't follow。bpu は自分の予測に沿って FTQ の鎖を作る。ただし extract は、消費するすべてのバイトを (ftq tag, `start_pc`) で名指しし、予測を実際の命令境界と照合する。producer の誤りは predecode redirect になるだけで、誤ったバイトの解釈や命令の飛ばしにはならない。producer は extract 側の資源 (キューの幾何、head+k) を一切仮定しない。
- F-P3. front end の redirect は 2 種類だけである。backend からの Redirect (§5.4) と、extract が出す PdRedirect。bpu 内部の override は bpu の外からは見えない。旧コアでは 6 種類の re-steer があり、優先順位が 10 か所で別々のメンバーシップで書かれていたが、これを置き換える。
- F-P4. front end は割込み、CSR 書き込み、satp を見ない。割込みは flush-at-head (§5.13) で、翻訳文脈の変化は flush を伴う retire (§5.5) で受け、どちらも front end ごと捨てて再開する。

### F.2 型と構成値

```veryl
// core_types::<CFG>, front-end part
const NH    : u32 = CFG::FETCH_BYTES / 2; // halfwords per fetch block
const GRAN_N: u32 = CFG::FETCH_BYTES / 4; // PMP granules (G=0) per block
enum CfiKind: logic<3> { NONE, BR, JAL, JAL_CALL, JALR, JALR_CALL, JALR_RET, JALR_RETCALL } // RAS hint table
struct BlockPred { exit_v: logic, exit_foff: logic<FOFF_W>, exit_kind: CfiKind, target: logic<64> }
struct PdInfo    { start: logic<NH>, cfi: CfiKind [NH] }  // predecode from the block's entry point
type   PredMeta = logic<CFG::PRED_META_W>;                // opaque outside bpu
type   PredCkpt = logic<CFG::PRED_CKPT_W>;                // opaque outside bpu: history + RAS at block start
struct FetchId {                                          // icache request ID, echoed unchanged
    ftq  : FtqTag, start_pc: logic<64>, pred: BlockPred,
    probe: logic,                                         // 0: no lookup, echo only (faulted block)
    exc  : exc_pkg::ExcRec, pmp_deny: logic<GRAN_N>,      // translation/PMA fault, per-granule PMP-X deny
}
struct FetchBlk { id: FetchId, data: logic<CFG::FETCH_BYTES * 8> }  // ifu -> extract
struct XOp {                                              // extract -> decode, one per lane
    ftq : FtqTag, foff: logic<FOFF_W>, pc: logic<64>,
    insn: logic<32>, cinsn: logic<16>, is_rvc: logic,     // insn: expanded form; cinsn: raw RVC parcel
    pred_taken: logic,                                    // this op is its block's predicted taken exit
    exc : exc_pkg::ExcRec,                                // fetch fault only (cause 1/12/20)
}
struct PdRedirect { valid: logic, ftq: FtqTag, foff: logic<FOFF_W>, taken: logic, pc: logic<64> }
```

- `CfiKind` の `*_CALL`/`*_RET`/`*_RETCALL` は、非特権仕様の JALR の RAS hint 表 (link = x1, x5) に従う。rd と rs1 がどちらも link で rd≠rs1 のときは pop してから push する。旧コアはこの場合を call としか扱っていなかった (`heliodor_core.veryl:4679-4682`)。RV64 には c.jal が無い (その符号は c.addiw)。
- 【決定】`PredMeta`/`PredCkpt` は、幅だけを構成値で決める不透明型とする。`bpu` は内部の struct 幅がそれに一致することを elaborate 時に検査する。理由: 予測器を差し替えても `ftq` と `core_types` の定義は変わらない (§2.2 M3)。
- 構成値 (§3.6 の `core_cfg`。所有モジュールだけが読む、P2): `FBQ_N` (`ifu` の fetch buffer、block 数)、`DQ_N` (`extract` の decode queue、op 数)、`PRED_META_W`, `PRED_CKPT_W`。予測器内部のサイズ `BP_BTB_N`, `BP_SLOTS`, `BP_RAS_N` (TAGE/iTTAGE の分は M3 で追加) は `core_cfg` に置かず、`bpu_pkg::<CFG>` に置いて `bpu` だけが読む (§3.6)。

| 定数 | 所有者 | cfg_w2 | cfg_w4 | 初期値の根拠 |
|---|---|---|---|---|
| `FBQ_N` | `ifu` | 4 | 4 | 旧 WORD FIFO は 8 dword = 64 B。1 block が 16/32 B なので 64/128 B に相当する。 |
| `DQ_N` | `extract` | 8 | 16 | 旧 fetch buffer は 8 records。4×FETCH_W とする。 |
| `BP_BTB_N` / `BP_SLOTS` (`bpu_pkg`) | `bpu` | 4096 / 2 | 4096 / 3 | blkpred は 4096 entry。8 B の dword で cond slot 2 個が kernel の 98.1 % を覆った (`blkpred.veryl:14-21`)。32 B の block では 1 個足す。 |
| `BP_RAS_N` (`bpu_pkg`) | `bpu` | 16 | 32 | 旧 ras は 16。 |
| `PRED_META_W` / `PRED_CKPT_W` | `bpu` (幅の検査) | 16 / 72 | 16 / 72 | 【M1b で決定】両構成とも暫定値。`bpu` が `PredMeta`/`PredCkpt` の内部 layout を決めた時点で、その幅に合わせて確定する。それまでは `ftq` と `core_types` が型を組めるだけの仮の幅である。 |

最終値は【M3 で決定】: §2.5 の sweep で、`ftq_full`/`fbq_full`/`dq_full` の発火数と IPC の膝の位置を見て決める。`BP_SLOTS` は、commit された block 範囲あたりの条件分岐数を census で数えて決める。

- 公表レイテンシ: `IC_RESP_LAT` (icache、1) と `ITLB_LAT` (tlb(I) の lookup 段、§M、1。M1b には tlb(I) が無く、Bare の翻訳 (PA = VA と PMA/PMP) がこの段を占める) は `fu_pkg` に置く (§2.1 P4)。提供モジュールは、自分の段数がこの値と一致することを elaborate 時に検査する (§5.6 F8 と同じ形)。予測器の部品のレイテンシと meta の配置は、bpu 内部のパッケージ `bpu_pkg::<CFG>` に部品ごとに 1 か所で置く。

### F.3 FTQ

所有者: `ftq`。1 エントリ = 1 fetch block。block は `start_pc` から始まり、予測した taken exit で終わるか、そうでなければ `FETCH_BYTES` で整列した block の末尾で終わる。`start_pc` は整列 block の途中でもよい (taken の着地点の場合)。op は `(ftq, foff)` だけを運び (§5.2 OpTag)、PC は FTQ だけが持つ。

| フィールド | 書き手 | 内容 |
|---|---|---|
| `start_pc` | bpu (enqueue) | block の入口 VA。 |
| `pred: BlockPred` | bpu、extract (訂正) | 配った予測。extract が書き戻した後は変わらない。BRU はこれと比べて mispredict を判定する。 |
| `meta`, `ckpt` | bpu | update と recover のときに bpu へ返すだけ。ftq は解釈しない。 |
| `pd: PdInfo` | extract | 実際の命令境界と CFI 種別。update と recover が使う。 |
| `res: BlockPred`, `end: logic<FOFF_W>` | enqueue 時に初期化。extract、partial kill、full kill が上書き | 実際の結末と、commit されうる範囲の終端。update はこの 2 つで学習する。 |

ポインタ (すべて `FtqTag`、比較は `tag_pkg::older`): `upd_q` (最古のエントリ。update 未送出で、ここが空きの境界)、`cm_q`/`cm_foff_q`/`cm_v_q` (最も若い retire 済み op の位置。`cm_q` より古いエントリは commit 済み)、`fetch_q` (ifu が次に取るエントリ)、`tail_q` (次の enqueue 位置)。順序は `upd_q ⪯ cm_q ⪯ fetch_q ⪯ tail_q` で、占有数は `FTQ_N` 以下。

| 事象 | 効果 |
|---|---|
| enqueue (bpu、valid/ready。`ready` は空きが 1 以上という登録値) | `tail_q` に書く。`res := pred`、`end := pred.exit_v ? exit_foff : NH-1`。Kill.valid か PdRedirect のサイクル k の enqueue は無視する (§5.4 T2)。k+1 以降の enqueue は、k の recover で再開した新しい path のものだけである (bpu は i_rcv を k に受けるので、古い lookup の結果が k+1 に出ることは無い)。 |
| fetch / rewind (`ifu`) | `fetch_q := next(fetch_q)`。rewind では `fetch_q := tag` (miss と walk の再送、§F.5)。 |
| extract の書き戻し (その block の処理で最初の op (straddle の op を含む) を DQ に入れるのと同じ edge) | `pd` を書く。予測を訂正したときは `pred`、`res`、`end` も書く。 |
| PdRedirect (登録済みパルス) | `tail_q := next(ftq)`、`fetch_q := tail_q`。bpu へ recover を出す。 |
| commit (`cm_valid, cm_ftq, cm_foff`。そのサイクルに retire した最も若い op) | `cm_q := cm_ftq`、`cm_foff_q := cm_foff`、`cm_v_q := 1`。 |
| partial kill | `tail_q := Kill.ftq_tail`、`fetch_q := tail_q`。エントリ `ftq_keep` に対して `res := taken ? {1, foff, pd.cfi[foff], Redirect.pc} : {0, ..}`、`end := foff`。bpu へ recover を出す。 |
| full kill | `cm_v_q` が立っていれば、エントリ `cm_q` を閉じる: `end := cm_foff_q`、`res.exit_v &&= (res.exit_foff == cm_foff_q)`。ただし Redirect が branch の結末を運ぶ場合 (commit backstop) は、その結末で `res` を書く。続いて `tail_q := cm_v_q ? next(cm_q) : cm_q`、`fetch_q := tail_q` とし、bpu へ recover を出す。Redirect の `ftq_keep` は、結末を運ぶ場合にだけ使い、そのとき `cm_q` と等しいことを assert する。 |
| update (`older(upd_q, cm_q)` のとき、1 エントリ/サイクル) | bpu に `{start_pc, meta, ckpt, pd, res, end, mispred = (pred != res)}` を渡し、`upd_q := next(upd_q)` とする。 |

ftq は recover の起点 (keep point) を bpu に 1 つの record で渡す: `{pc: 再開 PC, ckpt, meta, pd, foff, taken, apply}`。中身は次のとおり。partial kill と PdRedirect では、そのエントリの `ckpt/meta/pd` と、redirect が運ぶ `foff/taken` を渡し、`apply=1` とする。full kill では、`cm_q` のエントリ、`cm_foff_q`、その位置の `res` を渡し、`apply = cm_v_q` とする (`apply=0` は「ckpt をそのまま戻す」)。

不変条件 (所有者 `ftq`。FQ2 だけは `bpu`):

- FQ1 (寿命)。エントリ e は、e の op が 1 つでも生きている間は解放されない。解放は「`older(e, cm_q)` かつ update 送出後」に限る。kill による巻き戻しが捨てるのは keep より若いエントリだけで、その op は §5.4 T7 によってすでにすべて消えている。したがって、生きている op が自分の `(ftq, foff)` で PC と `pred` を読むことは、どの時点でも正しい。
- FQ2 (鎖)。間に redirect の境界が無い連続エントリ e, e+1 では、`start_pc(e+1) == next_pc(e)` が成り立つ (`next_pc` は、`res.exit_v` なら `res.target`、そうでなければ整列 block の末尾)。checker `chk_fetch_stream` が検査する。
- FQ3。`pred` は、extract の書き戻し edge の後は変わらない。書き戻しは、その block の処理で最初の op を DQ に入れるのと同じ edge で行う。したがって BRU が読む時点では必ず最終値であり、正しさは段の距離に依存しない。
- FQ4。update が学習に使うのは、commit 済みの範囲 `[start, end]` と `res` だけである。投機的な path の情報は学習に入らない。
- 【決定】`ftq` は bpu の update を待って詰まることがない。bpu の update ポートの ready は定数 1 とする (§F.4)。

読み出しポート `o_rd[FTQ_RD_N]` は、tag を与えると `{整列 block の base VA, pred}` を組合せで返す。`FTQ_RD_N` = BRU ポート数 (§3.2) とし、topology から導く。【決定】PC は FTQ だけが持ち、ROB と IQ は 64-bit の PC を持たない。PC を読むのは BRU ポート (条件分岐、JAL、JALR、AUIPC は `fu_bru` で実行する、§X.8) だけで、自分の `(ftq, foff)` で読む。commit は FTQ から PC を読まずに導出する (正本は §C.2.3)。理由: PC の保持者が 1 つになり、PC を段ごとに写す箇所が無くなる。FQ1 によって読みは常に正しい。

サイズ `FTQ_N` (§3.3) は、ROB_N 個の in-flight op が占める block 数と run-ahead 分を覆う必要がある。【M3 で決定】`ftq_full` の発火数で決める。

### F.4 bpu: predict/update/recover 契約

外部ポート (所有者 `bpu`):

| ポート | 向き | 契約 |
|---|---|---|
| `o_enq_valid`, `o_enq {start_pc, pred, meta, ckpt}`, `i_enq_ready` | bpu→ftq | 1 サイクルに最大 1 block。ready は ftq の登録済みの空き。ready=0 の間、bpu はパイプラインを止めて保持する。 |
| `i_rcv {valid, pc, ckpt, meta, pd, foff, taken, apply}` | ftq→bpu | Kill.valid か PdRedirect のサイクル k に、ftq の登録済みエントリと、登録済みの Kill/Redirect/PdRedirect から組合せで作る 1 サイクルパルス。k に bpu は in-flight の lookup と、k に出そうとしていた enqueue をすべて捨て、投機状態を復元し、`pc` から予測を再開する。 |
| `i_upd {valid, start_pc, meta, ckpt, pd, res, end, mispred}` | ftq→bpu | 1 サイクルに最大 1 block。bpu の ready は定数 1。 |

外部の契約は valid/ready なので、ftq/ifu/extract は bpu のレイテンシに依存しない。

内部構造 (bpu の中だけで差し替える):

- 表の部品 `bp_btb`, `bp_dir`, `bp_ind`。サイクル t に `{lk_valid, lk_pc, lk_hist}` を受け取り、登録済みの結果をちょうど t+`LAT` に出す。`LAT` と meta の配置は `bpu_pkg` に部品ごとに公表し、bpu の段制御 (taken の後に捨てる lookup の数、override の整列) はこの値だけから導く。表の部品は投機状態を持たない (recover ポートが無い)。update は、運ばれてきた `meta` と `ckpt` から行う。表を読み直さず、commit 済み history から index を再計算しない。
- 投機状態は `bp_hist` (global/path history) と `bp_ras` だけであり、`PredCkpt` で戻す。
- 【決定】update は meta から行い、学習のための読み出しポート (旧 blkpred の dt コピー) を持たない。理由: 表を 1R1W のまま保て、SRAM が半分で済む。旧コアでは、TAGE と iBTB が committed history から index を再計算する前提 (`tage.veryl:13-20`) が Stage-A/B の分割で崩れていた (推定)。その種のずれも起きなくなる。
- 【決定】表の index は `start_pc` (halfword 単位) の hash とし、slot の offset は `start_pc` からの相対で表す。理由: 予測は、学習したときと同じ入口位置でしか使われない。したがって旧コアの mid-dword re-entry と decode-alignment aliasing (re-entry guard を緩めたら ext_taken_redir が 0 から 1476 に増えた) は発生源で消え、別の guard が要らない。call の整列 block の途中へ return しても別の entry を読むので、旧コアが run-ahead RAS を断念した call→ret→call の空転も起きない。代償は、同じ整列 block への入口ごとに entry を消費すること。【M3 で決定】容量は `bp_btb` の hit 率で決める。

予測を読む位置と bubble:

- lookup ポインタ `p0_pc` は 1 サイクルに 1 block を引く。exit が not-taken なら、次の整列 block を次のサイクルに投機的に引く。taken なら、target を登録して次のサイクルに提示し、その間に投機的に出した lookup (`LAT` 個) を捨てる。
- 【決定】M1 では `bp_btb` の `LAT=1` とし、taken block 1 つにつき 1 bubble を払う。理由: target を同じサイクルに index へ戻すと「表の読み → 表の index」経路になる (旧コアで禁止と判断済み)。bpu の block 供給率は 1/(1+LAT·p_taken) で、p_taken=0.6 なら約 0.6 block/cycle。一方、消費側は 1 block を複数サイクルかけて extract するので、(IPC / block あたりの op 数) block/cycle しか要らない。差は FTQ の深さが吸収する。
- 【M3 で決定】1 サイクルの L0 段で lookup ポインタを操り、遅い最終段 (TAGE、iTTAGE) で override する構造を入れるかどうか: `ftq_empty && ifu_idle` (bpu が供給できずに fetch が止まったサイクル) を測って決める。override は bpu の内部で閉じる。ftq には最終予測しか入らず、不一致のときは bpu 自身の若い in-flight lookup だけを捨てる。

history と RAS の修復 (所有者 `bp_hist`, `bp_ras`):

1. `ckpt` (keep point の block の入口での状態) を戻す。
2. `apply` が立っていれば、keep point の block の `foff` までの結末を追加する。history には、`meta` が示す予測済み cond slot のうち `foff` より前のもの (not-taken) と、`foff` の命令 (`pd.cfi[foff] == BR` なら `taken`) を足す。RAS には、`pd.cfi[foff]` が CALL/RET/RETCALL なら、その push/pop を適用する。
3. `pc` から lookup を再開する。

この手順は、partial kill、PdRedirect、commit backstop、その他の full kill で共通であり、どれでも正確に戻る。旧コアの「commit 済みの twin から戻す」と「16×64 の RAS 全コピー」は、early redirect では近似にすぎなかったが、これを置き換える。

- 不変条件 (所有者 `bp_hist`): block n の lookup に実際に使った history を `ckpt(n)` として ftq に入れ、update はその `ckpt(n)` で行う。recover の後に出す最初の lookup は、正しい path で予測していたら使っていたはずの history を使う。
- 【M3 で決定】history の定義: block n+1 の lookup が block n の bit を待つ (cond を含む block ごとに bubble) か、1 block 遅れた history を使うか。TAGE の的中率と bpu の bubble を測って決める。上の不変条件はどちらの定義でも成り立つ。
- `bp_ras` は BP_RAS_N entry の循環スタックで、投機側 1 本だけを持つ (arch stack は持たない)。`ckpt` は `{tos, top の値}`。push/pop は最終予測の段で exit_kind に従って行い、RET の target はその段の top から取る。溢れたら最古を上書きする。

旧予測器の扱い:

| 旧モジュール | 旧の形 | 新での扱いと adapter | 時期 |
|---|---|---|---|
| `blkpred` | dword index、tag 付き、cond slot 2 個 (13-bit offset + 2-bit ctr) と tail slot 1 個 (kind、64-bit target)、clocked 1R1W、2 サイクル RMW (別コピー dt) | `bp_btb` の母体で、M1 の唯一の表。block を `FETCH_BYTES` に、slot 数を `BP_SLOTS` に一般化し、index/tag を `start_pc` 単位にする。`LAT` を公表する。学習は meta から行い、dt コピーを捨てる。straddle する CFI は学習しない (§F.7 V4)。 | M1b |
| `btb` | 命令 PC で index、lane ごとに全複製 (d0/d1)、`BTB_SYNC_READ` が私有 const | 部品としては使わない。lane 複製は 4 lane で 4 コピーになり、拡張しない。役割は `bp_btb` が吸収する。2 段の BTB が要るなら `bp_btb` の大容量段として作る (【M3 で決定】: taken block の bubble 率で判断)。 | - |
| `bht` | gshare 8192×2b、index は core が計算、予測 2 + commit 側の読み 1 | `bp_dir` の base 表 (M3)。block 単位の row (BP_SLOTS 個の ctr) にする。index は bpu 内で計算する。commit 側の読みポート (TAGE の altpred 用) は meta で置き換えて削除する。 | M3 |
| `tage` | 3 表 (hist 8/21/55)、register file、2 port、committed history から index を再計算して学習 | `bp_dir` の provider (M3)。history は `bp_hist` から受け取る。fold 幅を param にする (`tage.veryl:74-99` の 10/8 固定を解消)。学習は ckpt と meta から行う。`LAT` を公表する。大きな reset loop は valid bit に置き換える。 | M3 |
| `ibtb` | 512 entry、index = gshare ^ 間接 path history (core 内で計算)、2 複製 | `bp_ind` (M3)。間接になりうるのは exit slot だけなので、block あたり 1 回読む。path history は `bp_hist` から受け取る。学習は運ばれた状態で行う。 | M3 |
| `ras` | spec/arch/run-ahead の 3 本、recover は arch→spec の全コピー、`5'd16` リテラル | `bp_ras` に作り直す。ckpt `{tos, top}`、DEPTH を param にする、pop-then-push を追加する。 | M1b |

### F.5 ifu と fetch 側の翻訳

所有者: `ifu`。段の prefix は `f<n>_`。

| 段 | 動作 |
|---|---|
| f0 | ftq の `fetch_q` エントリを取り、整列 block の VA で tlb(I) に `XlateReq` を出す (`acc=FETCH`、`tag.client = IFU`、`tag.id = FtqTag`)。 |
| f1 (f0 + `ITLB_LAT`) | `XlateResp` を受ける。hit なら PA と `PmaAttr` と PMP の granule mask を得て、icache に `IcReq` を出す。fault なら、`exc` を載せた `probe=0` の `IcReq` を出す。miss なら、walk を要求し、自分より若い in-flight 要求を捨て、ftq を `rewind(tag)` して待つ。 |
| f2 (f1 + `IC_RESP_LAT`) | `IcResp` を受ける。HIT なら `FetchBlk` を fetch buffer (FBQ) に push する。MISS なら、若い in-flight 要求を捨て、ftq を `rewind(tag)` して `IcEvent` を待つ。 |

- 【決定】翻訳は、icache の index より前の登録段で行う (旧 `IMEM_MMU_STAGE` を実体化する)。理由: 32 KiB 4-way の icache は 1 way が 8 KiB で page より大きく、VIPT にできない。旧コアは翻訳と index を同じサイクルに置いており、V=1 の TLB cone が 5.36 ns を占めた。
- 【決定】翻訳は block ごとに 1 回行う。整列 block (32 B 以下) は page も line も越えないからである。PMA は block ごとに `pma_check` を 1 回評価する (PMA の領域は 4 KiB 以上で自然整列であることを、表の側で保証する。§S.2)。PMP は 4 B の granule ごとに `pmp_check` を `GRAN_N` 個並べて評価し、拒否の mask を運ぶ。全 granule が拒否なら、その block は fault の block として `probe=0` で流し、fill を起こさない。理由: G=0 なので PMP の境界は 4 B 単位でありうる。旧コアは dword の先頭アドレスでしか PMP を見ていなかった (`imem_mmu.veryl:165-175`。dword 内に境界があれば誤る、推定)。
- block の fault は `exc_pkg::exc_prio` で 1 つにまとめる。page fault、guest page fault、walk 中の access fault が先で、翻訳が成功した後に PMA の access fault (`executable=0` または hole、§5.14) が来る。PMP は mask として運び、op ごとの判定は extract が行う (§F.7)。
- walk を要求できるのは ifu だけで、対象は f1 にある 1 block (fetch 順で最古の未取得 block) に限る。要求は `{tag: FtqTag, va}` を ptw(I) の要求キューに valid/ready で出す。要求の `MemTag` は `client=IFU`、`id` = FtqTag とする (§5.9。front end の client なので `rob` は無効で、どの kill でも flush する)。ifu は walk の間、MMU の FSM 状態を保持しない (§5.10 X4 の I 側規則)。ptw(I) は walk の owner (ifu) に完全な XlateResp (成功でも fault でも) を返し、完了ごとに `PtwEvent` を broadcast する (§5.10 X2)。ifu はそのどちらかを受けたら block を再提示する。fault は `fault_pend {tag, exc}` に latch しておき、その block を再提示したときに TLB の結果の代わりに使う。fault は TLB に入らないので、こうしないと再 lookup のたびに walk を繰り返してしまう。
- 【決定】front end のすべての flush (Kill.valid と PdRedirect) で、ifu は ptw(I) の owner を落とし (`i_owner_drop`)、`fault_pend` を消す。walk 自体は続けてよく、install は §5.10 X2 の epoch 規則に従う。理由: 旧コアは、redirect のサイクルに古い VA で walk を始め、その fault を新しい PC に帰属させていた (boot で 1 文字あたり約 290K サイクルを失った)。また、front end 内部の re-steer ではこの walk が止まらなかった (推定)。
- I 側の A ビット更新 (Svadu) は、§M の ptw 規則に従う (ptw(I) が `mem_port_arb` の port 0 に AD クラスとして出す、§5.9)。特権仕様は A ビットの投機的な更新を許しているので、fetch の walk で立ててよい。
- 再送の規則は 1 つだけである: 「その block 以降の in-flight 要求を捨て、ftq を `rewind(tag)` して待つ」。ITLB miss にも icache MISS にも使う。要求には、lookup と PLRU 以外の副作用が無いので、捨ててよい。
- 【決定】ifu は、icache への要求を出す前に FBQ の credit を確保する: `in_flight + FBQ の占有数 ≤ FBQ_N` (所有者 `ifu`)。理由: 旧 WORD FIFO は in-flight の push を数えておらず、背圧が続くと 9 段目に溢れた (78355eb)。
- fault の block を出したら、ifu は次の flush まで要求を止める。無駄な walk を始めないためである。fault の op は commit で trap するか、より古い redirect で消えるので、front end が止まったままになることは無い。
- ifu は割込み入力も CSR の shadow も持たない (§5.10 X5)。SFENCE.VMA/HFENCE は NEXT_PC flush を伴う (§5.5)。したがって、fence より前に取った命令が古い翻訳のまま retire することは無い (旧コアの SFENCE は redirect しなかった)。
- 不変条件 (所有者 `commit` と `tlb`): SFENCE 系による tlb(I) の無効化は、その op の retire flush の後の最初の lookup より前に効く。

### F.6 icache の CPU 側と I read slot

- 【決定】§4.4 の手順で、icache を `src/v14/v14_icache` に凍結コピーし、新コアの `icache` は CPU 側を作り直す。fill FSM、tag/valid/PLRU、hit-under-fill (victim way の除外)、streaming、FENCE.I による fill_aborted はそのまま移す。next-line/straddle/prefetch 用の tag 複製 (`u_itag_next/nl/pf`) と、使われていない prefetcher は移さない。理由: 要求のハンドシェイク、応答 ID、MISS 応答、I read slot の所有は、どれも「追加」では作れない。

```veryl
struct IcReq  { id: FetchId, pa: pma_pkg::Pa, cacheable: logic }   // pa aligned to FETCH_BYTES
enum   IcKind: logic { HIT, MISS }
struct IcResp { valid: logic, id: FetchId, kind: IcKind, data: logic<CFG::FETCH_BYTES * 8> }
enum   IcEvKind: logic<2> { FILL_DONE, FILL_ABORT, UNC_DONE }
struct IcEvent { valid: logic, line: logic<50>, kind: IcEvKind }
```

- IC1. 要求は valid/ready で受理する (ready は登録済み状態から作る)。受理した要求には、ちょうど `IC_RESP_LAT` サイクル後に応答を 1 つだけ返す。`id` はそのまま返す (§5.6 F3 と同じ)。これが、旧コアで sync read のデータに PC と fault を揃えていた `wf_push_*_q` レジスタを置き換える。
- IC2. 応答の幅は `FETCH_BYTES` とする。cfg_w2 の 16 B は、内部の 256-bit block の半分を `pa[4]` で選ぶ。構造制約 `FETCH_BYTES ∈ {8, 16, 32}` (内部 block 幅 32 B を超えない) は icache が宣言する。旧ポートは内部で 32 B を読みながら 8 B しか出していなかった (`icache.veryl:158-170`)。
- IC3. miss は、データではなく `MISS` 応答で伝える。旧コアは NOP 0x13 を返していたので、利用側が組合せの stall と登録済みの stall を使い分ける必要があった (78355eb)。MISS を返したサイクルに、icache は miss した line を自分のレジスタに latch して fill を要求する。受理される前の fill 要求は front end の flush で取り消してよい。受理された後は落とさずに完走させ (mem_ctrl の slot と lockstep を保つため)、line を install する。旧 icache は、受理前の要求が live の `i_addr` に追従して別の line に向き直ることがあった。新しい icache の fill 要求は、latch した line だけを使う。
- IC4. `probe=0` の要求に対しては、lookup も PLRU の更新もせず、`IC_RESP_LAT` 後に `id` を HIT として返す (data は 0)。fault を持つ block を、通常の要求と同じ順序で流すためである。
- IC5 (uncached fetch)。`cacheable=0` の要求には MISS を返す。そのうえで I read slot に `FETCH_BYTES/8` 回の single-beat 読みを出し、1 block 分の uncached buffer に組み立ててから UNC_DONE を出す。再提示にはこの buffer から HIT で返し、buffer は 1 回使うか flush で無効になる。対象は boot ROM のような `executable=1, cacheable=0, idempotent=1` の領域だけである。`executable=1` かつ `idempotent=0` の領域は、PMA 表の検査で拒否する (§S.2)。これで旧 `o_imem` passthrough と、core 側の 2-beat 組み立て (`f0_nc_*`) が不要になる。
- IC6. `i_inval_all` (commit の `retire && FENCE.I`) の後に受理した要求には、pulse より前の内容を返さない。進行中の fill は aborted として完走させて INVALID で終え、streaming の読み出しにも使わない。
- IC7 (I read slot)。slot の調停は `islot_arb` が行い、client (icache の fill、icache の uncached 読み、ptw(I) の PTE 読み)、優先順位、owner の latch の規則は §M.5 が正本である。PTE 読みは line 1 本の取引で、要求された dword を返す。PTE の line buffer を持つかどうかは §M が決める。icache の側から見た契約は「fill と uncached 読みを `islot_arb` に要求し、受理から最終 beat まで beat を受け取る」ことだけである。
- M1 の再提示規則: MISS を受けた ifu は、いずれかの `IcEvent` が出た後に再提示する。fill は 1 本しかないので、その event は自分の line か、自分を塞いでいる line のどちらかである。【M3 で決定】streaming の early restart (block 単位の到着 event)、cancel できる prefetch、2 本目の fill: N=1 boot の front-end-empty の内訳を測って決める。
- 宣言された上限 (§3.4 に登録済み): icache の fill 文脈は 1 本。I read slot は 1 本で、ptw(I) と共有する (`islot_arb`)。

### F.7 extract

所有者: `extract`。段の prefix は `x_`。入力は FBQ の先頭の `FetchBlk` と carry。出力は、decode queue (`lane_queue #(XOp, FETCH_W, FETCH_W, DQ_N)`) への最大 FETCH_W 個の op と、ftq への pd の書き戻し、PdRedirect。

- x0 (block 単位。block が x1 に入るときに 1 回だけ計算する): 各 halfword 位置 h (`NH` に関する for-generate) で predecode を行い、`is32[h]` と CFI の種別を求める。入口状態 (start foff、carry の有無) から始まる命令開始 mask `start` は、halfword ごとの 2 状態 (開始 / 継続) automaton の合成として、`tree_pkg` の prefix で求める (段数は log2(NH))。下表の予測検証も、ここで block 全体について行う。target を計算するのは、exit の位置と最初の未予測 JAL の 2 か所だけである。
- x1 (lane 選択): cursor 以降の `start` のうち l 番目の位置を lane l が取る (prefix count との比較で one-hot を作り、AND-OR の mux で選ぶ)。lane ごとに `c_expander` を 1 個置く。lane の並びは、exit (訂正点を含む)、block の末尾 (straddle 命令は carry へ回す)、fault、DQ の credit のいずれかで切る。DQ は flush のサイクルの push も捨てる (§5.4 T7)。
- 【決定】境界は prefix で求め、lane の位置は「cursor 以降の l 番目の開始」として lane ごとに独立に求める。理由: lane l が lane l-1 の長さに依存する直列の鎖 (旧 slot-1 の `s1_b1`) を作らず、`FETCH_W` を変えても段数が変わらない (§5.15、R4)。
- 【決定】extract が 1 サイクルに取り出すのは 1 block (と carry) からだけである。理由: `FETCH_BYTES = 8×FETCH_W` なので、block の前半から入れば、非圧縮命令だけでも FETCH_W 個が残る。2 block から読むと、境界の論理とキューの読みポートが倍になる。【M3 で決定】2 block からの取り出しの要否: `x_cut_block_end` (block の末尾で lane が余ったサイクル) を測って決める。

straddle (block の末尾をまたぐ 32-bit 命令):

- 位置 NH-1 から始まる 32-bit 命令は、その block では出さず、下半分を carry `{lo, pc, ftq, foff, exc, deny}` に入れる。carry と結合するのは、次の block の `start_pc` が carry の pc+2 (= 次の整列 block の先頭) と等しいときだけである。等しくない block が来たら carry を捨てる (FQ2 により、その block は redirect の後のものなので、捨てるのが正しい)。
- straddle 命令の op は、下半分がある block の `(ftq, foff=NH-1)` を持つ。
- 【決定】op の fault は、op のバイトが属する各部分の fault を、program order の前の部分から順に見て最初のものとする。具体的には、まず下半分 (その block の `exc` と、属する granule の PMP 拒否) を見て、無ければ上半分 (次の block の `exc` と granule の拒否) を見る。上半分による fault の tval は上半分の VA (= pc+2) とし、epc は pc とする。block 内の 32-bit 命令が 2 つの granule にまたがる場合も同じ規則に従う。理由: 特権仕様は「fault を起こした部分のアドレス」を tval とする。旧コアは、straddle の上半分と slot-1 の dword について fault ビットを見ておらず、`fb_ifault[tail+1]` を 0 に固定していた (推定の cross-page の穴、`heliodor_core.veryl:1204-1207, 3864-3867`)。新コアは op ごとに、自分のバイトが覆う部分すべての fault を合流させるので、この穴は構造的に生じない。
- fault を持つ op を 1 つ出したら、extract は次の flush まで出力を止める。fault op の `insn` は 0 とする (比較対象外、§5.12)。

予測の検証 (deliver, don't follow)。x0 で、block の入口から見て最初に違反した位置を訂正点とする (first-match は prefix で求める)。

| 検査 | 違反時の訂正 | PdRedirect の pc |
|---|---|---|
| V1. 予測 exit の `exit_foff` が命令の開始である | exit を消す (fall-through) | 整列 block の末尾 |
| V2. exit の位置にある命令が CFI である | exit を消す | 同上 |
| V3. exit が直接分岐 (BR/JAL 系) なら `target == pc+imm` | target を訂正する (taken のまま) | `pc+imm` |
| V4. exit が straddle 命令でない | exit を消す。straddle する CFI は block の exit にしない | 整列 block の末尾 (carry で結合する) |
| V5. exit より前 (exit が無ければ block 全体) に、予測されていない JAL が無い | 最初の JAL を exit にする | その target |
| V6. exit の種別が pd と一致する (例: RET と予測した命令が ret の形をしている) | `res.exit_kind` を pd に合わせる。target は backend が検証する | 出さない |

- 訂正点までの op は、訂正済みの `pred_taken` を持って出る。訂正した `pred`/`res`/`end` と `pd` は、その block の処理で最初の op を DQ に入れるのと同じ edge で ftq に書く (FQ3)。PdRedirect は登録して次のサイクルに出し、ifu (FBQ を含む) と x0 段を flush する。x1 にある当該 block の残り (訂正点まで) と carry は残す。
- 不変条件 X1 (所有者 `extract`): `pred_taken=1` を持つ op は、pd が CFI と判定した命令であり、かつその block の (訂正済みの) exit である。非 control op の `pred_taken` は常に 0 である。したがって commit の mispredict 検査は control op だけで足りる (§5.4 T8)。旧コアにあった「非 control op が stray な pred_next を持つ」類 (10ca81f、28dbde7、f2a2046 の c.swsp skip) は構造的に起きない。
- 不変条件 X2 (所有者 `extract` と `ftq`。checker `chk_fetch_stream`): extract が続けて出す op a, b について、間に redirect が無ければ `b.pc == (a.pred_taken ? ftq[a.ftq].pred.target : a.pc + len(a))` が成り立つ。redirect の後の最初の op の pc は redirect の pc と等しい。この不変条件が命令の飛ばしを禁じる。旧コアではこの類が 3 件起き、instret の不一致でしか見つからなかった。
- 不変条件 X3 (所有者 `extract`): PdRedirect を出した block より若い block の op は、DQ に入らない。
- PdRedirect と backend の Redirect が同じサイクルに来たら、backend が勝つ。backend にある op は、どれも extract の中身より古いからである。
- 検証しないもの: 条件分岐の方向と JALR の target。これらは backend の resolve と commit backstop が担う。予測されていない RET を RAS で直すことは、M1 ではしない (【M3 で決定】: 発生数を数えて決める)。

### F.8 decode への受け渡し

- decode queue (DQ) が x|d の境界である。flush するのは backend の Kill.valid のときだけで、PdRedirect では flush しない (中身はすべて訂正点より古い)。
- decode は、DQ の先頭 FETCH_W lane に対して、純関数のインスタンス (`decoder` + `imm_gen` + §5.5 の `op_class`) を FETCH_W 個並べたものである。状態を持たない。合法性は、commit 済みの CSR 状態に対して評価する (§5.5)。出力は、§R の rename 入口のキューが登録する。
- `is_rvc` は、旧 `decode` と同じく入力として渡す。
- 不正な RVC: `c_expander` が illegal を出した lane は、`insn` を不正命令として decode させ、illegal-instruction の tval を `cinsn` (16 bit) にする。旧コアは命令を 32'h0 に置き換えていたため tval が 0 になっていた (`heliodor_core.veryl:1221`)。この差は trace diff の MASK 項目にする (D4)。
- fetch fault の op は、§5.5 のとおりこの境界で class ビットを捨て、`NONE` に例外を付けた op になる。
- `pc` は XOp に載せて decode まで運ぶ (decode は使わない、§R.2)。decode より後の op は `(ftq, foff)` だけを運ぶ。PC の読み手は §F.3 の【決定】のとおり。
- JAL の target は、V3 と V5 によって front end で確定しており、mispredict しない。link の計算に PC が要るので `fu_bru` で実行する (§X.8 の【決定】)。

### F.9 redirect の消費と正しさの網

| 消費者 | Kill.valid (partial と full) | PdRedirect |
|---|---|---|
| `bpu` | in-flight の lookup を捨て、ftq の recover record で復元し、`Redirect.pc` から再開する | 同左 (`pc` は PdRedirect.pc) |
| `ftq` | §F.3 の表 | §F.3 の表 |
| `ifu` (f0-f2、FBQ、`fault_pend`、ptw(I) の owner、icache の未受理の fill 要求) | すべて捨てる | すべて捨てる |
| `extract` (x0、x1、carry) | すべて捨てる | x0 だけ捨てる |
| DQ | flush する | 触らない |

- `RedirKind` の定義は `core_types` にあり、生成者は `flush_ctrl` である (§5.4、§C.4)。front end が区別するのは、「branch の結末 (`Redirect.foff`, `Redirect.taken`、§5.4) を運ぶかどうか」だけである: BR (partial、BRU の resolve)、BR_CM (commit backstop による full kill)、それ以外 (trap、xRET、割込み、NEXT_PC flush、REPLAY による full kill。§C はこれらを細分してよいが、front end から見れば同じ扱い)。
- mispredict の定義 (BRU、§X): `taken != op.pred_taken || (taken && target != ftq[op.ftq].pred.target)`。pc (= block base + 2·foff) と `pred` は ftq から読む。
- early redirect は最適化にすぎず、正しさは T8 の commit backstop が持つ。front end の側の規則は次の 2 つ。
  - 予測値は書き換えない。`ftq.pred` は不変で、partial kill が書くのは `res` だけである。二重の redirect は ROB の `recovered` で防ぐ (T8)。旧コアは ROB の `pred_next_pc` を resolve した target で上書きしたので、TAGE がその誤りを `c_early_fix` で拾い直す必要があった。
  - T1/T9 で捨てられた resolve は、commit backstop (BR_CM) として front end に届く。そのとき ftq は、まず `cm_q` の結末を書き直してから recover を出す。
- full kill の再開点は `Redirect.pc` である。割込みの epc は front end のポインタからは取らない (§5.8)。
- M1 での redirect から rename までの距離: Redirect のサイクルを k とすると、k に bpu の lookup、k+1 に BlockPred と enqueue、k+2 に f0、k+3 に f1、k+4 に f2 (FBQ へ push)、k+5 に x0、k+6 に x1 (DQ へ)、k+7 に decode、k+8 に rename となり、約 8 サイクルである。【M3 で決定】短縮の手段 (FTQ が空のときの bpu→ifu bypass、ifu が enqueue を待たずに redirect の pc を取りに行くこと、x0 と x1 の統合): mispredict 1 回あたりのコストと回数を測って決める。

### F.10 FENCE.I と coherent ifetch

- FENCE.I の OpClass は §5.5 の表、retire 時の動作 (`icache.i_inval_all` と `pc+4` からの full kill) は §C.6 の表が正本である。
- 正しさの連鎖は次のとおり。(1) drain=1 (`sb.ordering_empty` を待つ) により、より古い store はすべて自 hart の dcache に入っている。(2) I 側の fill と PTE 読みは、directory に数えない coherent 読み (所有者がいれば recall) なので、invalidate の後の再 fill は最新の値を読む。(3) IC6 により、invalidate より前の内容は返らない。(4) full kill により、FENCE.I より前に取った後続の命令は DQ と ROB から消える。
- 【決定】予測器の表は FENCE.I で消さない。理由: 古い予測は §F.7 の検証と backend の resolve が正すので、消しても正しさは変わらず、的中率だけが落ちる。
- 【決定】非 coherent な I 側 (旧 `COHERENT_IFETCH=0` の D$ flush sweep) は持たない。理由: D3 で non-coherent な bare 構成を廃止したため。
- 他 hart の store は、その hart が自分で FENCE.I を実行するまでは見えなくてよい (RISC-V の規約)。I 側の line は directory に載らないので、remote の書き込みでは invalidate されない。

### F.11 M1b で出すものと M3 で決めるもの

| 項目 | M1b (最終構造 + 最も単純な policy) | M3 以降 |
|---|---|---|
| bpu の部品 | `bp_btb` (blkpred 由来、slot の 2-bit ctr)、`bp_ras` (ckpt あり)。global history は持たない (読まれない状態は DEAD scaffold になるため) | `bp_hist`、`bp_dir` (tage/bht 由来)、`bp_ind` (ibtb 由来)。L0 段と override の要否 |
| 予測のレイテンシ | `LAT=1`。taken block ごとに 1 bubble | 最終段の `LAT` と L0 段を `ftq_empty && ifu_idle` で決める |
| recover の経路 | partial kill、PdRedirect、commit backstop、full kill をすべて動かす (RAS の ckpt で FTQ の ckpt 経路が M1 から働く) | history の定義を決める |
| ifu / icache | f0-f2、block ごとに 1 回の翻訳 (M1b は Bare。tlb(I)/ptw(I) と ITLB miss の再送は M2)、miss でブロックする、tag からの再送、fill 1 本、任意の event で再提示 | early restart、prefetch、2 本目の fill、redirect の fast path |
| extract | x0/x1、1 サイクルに 1 block、V1-V6 | 2 block からの取り出し、未予測 RET の訂正 |
| 構成 | cfg_w2 で `FETCH_BYTES=16`。cfg_w4 (`32`、4 lane) は elaborate でき、rv64ui のサブセットが通る | sweep でサイズを決める |

- H 拡張 (V=1 の 2 段翻訳、`gpa` 付きの guest page fault) は、tlb(I)/ptw(I) の内部変更として M5 で入る。ifu の契約は変わらない。
- 発火カウンタ (§5.15) に出す event: `bp_taken_bubble`、`ftq_full`、`ftq_empty_ifu_idle`、`itlb_miss`、`ic_miss`、`ic_fill_busy`、`fbq_full`、`x_cut_block_end`、`pd_redirect[V1..V5]`、`fetch_fault_stall`、`dq_full`。boot と bench で V1、V2、V4 が 0 のままなら、aliasing を起こす directed test (自己書き換えと FENCE.I で予測と内容をずらす) を足す。straddle と cross-page fault、PMP の granule 境界にも directed test を用意する。

### F.12 旧コアとの差異 (trace diff)

trace diff に現れうる差異 (D4。推定のものは、M2 の前に golden 上の directed test で確かめる。front end が防ぐバグ類は付録 §F):

- 不正な RVC の tval: 新コアは 16 bit の符号、golden は 0 (MASK)。
- straddle の上半分が fault する場合: 新コアは pc+2 を tval として trap する。golden は fault を見落とす (推定)。directed test は「page 境界をまたいで未 map の page に入る 32-bit 命令」。
- dword 内に PMP 境界がある fetch: 新コアは granule 単位で判定する。golden は dword の先頭でしか判定しない (推定)。
- `executable=0` の領域 (MMIO) からの fetch: 新コアは access fault にする。golden は、PMA_FAULT=1 の構成で CLINT/UART/PLIC を backed として扱う (`imem_mmu.veryl:176-181`)。
- SFENCE.VMA の後の再 fetch: 新コアは行う。golden は行わない。trace には、古い翻訳で fetch した命令がある場合にしか現れない。
- satp の shadow と偽の ifault: 新コアは持たない (§5.10 X5)。trampoline の窓は、検証計画の allow-list で扱う。

---

## §R decode・rename・dispatch

範囲: §F の decode queue (`DQ`) の出力から、ROB/IQ/LQ/SQ (M5 以降は VU) への割り当てまで。型、kill と回復、OpClass はそれぞれ §5.1-§5.2、§5.4、§5.5 に従い、本章では再定義しない。本章が所有するモジュールは `decode`、`rename`、`free_list`、`dispatch` と、decode と rename の間の lane_queue `rq` である (extract と decode の間の `DQ` は §F が所有する)。

### §R.1 段構成と責務

```
§F の DQ (lane_queue #(XOp, ...)) --> decode[l] (d_、lane ごとの組合せ) --> rq: lane_queue #(DecOp, W_IN=FETCH_W, W_OUT=RENAME_W)
  --> rn_ 段: dispatch が take を決め、rename が lane 0..take-1 を写像し、
      同じ clock edge で RAT、free_list、rob、iq[k]、lq、sq、busy_table に書く
```

| モジュール | 保持する状態 | 主な出力 |
|---|---|---|
| `decode` | なし (csr の登録済み出力を組合せで読む) | lane ごとの `DecOp` |
| `rename` | 投機 RAT、arch RAT、(M3) checkpoint pool | lane ごとの source/宛先の写像 |
| `free_list` (int 用と fp 用の 2 instance) | pdst の循環 FIFO、head/tail | pop 窓、`o_free`、`o_head_after` |
| `dispatch` | なし (credit は各所有者が持つ) | `take`、各所有者への割り当て要求と書き込み内容 |

- 【決定】rename と dispatch は同じ段 `rn_` に置く。lane 0..take-1 について、RAT への書き込み、free list の pop、ROB の割り当て (walk 記録となる `{has_rd, cls, rd_arch, old_pdst}` と dispatch snapshot を含む)、IQ/LQ/SQ への書き込み、busy_table のクリアを同じ edge で行う。理由: RAT を書き換えた op は必ず同じ edge で ROB に載るので、walk (§R.3.4) は ROB の範囲だけで完結する。「rename 済みだが ROB に未登録」の op が存在すると、それを巻き戻す経路が別に必要になる。
- 段を足すとき (§2.1 P3) は、IQ/LQ/SQ への payload 書き込みの側に `stage_reg` を挟む。タグと credit は `rn_` で確定しているので、変わるのは IQ の ready 初期値に 1 サイクル分の wake を畳み込むことだけである。【M3 で決定】段を足すかどうか: CP 分解で `rn_` が名指しされた場合だけ検討する (周波数は目標でない、§2.6)。
- 【決定】`rq` の深さ `RQ_N` (`core_cfg`) の初期値は 2×FETCH_W とする (cfg_w2 で 4、cfg_w4 で 8)。理由: ready は登録済みの占有数から作る (§5.3 R2) ので、1 group/サイクルを維持できる最小の深さがこれである。dispatch の部分受理 (§5.3 R4) で残った lane もここに残る。

### §R.2 decode

lane ごとに `decoder` と `imm_gen` (どちらも再利用) を 1 つずつ置き、その出力と §F の `XOp` から `DecOp` を作る。中身は純関数で、lane は一様な for-generate で書く。RVC の展開は extract が済ませている (§F)。旧 `decode.veryl` (改名後は `v14_decode`) は instantiate せず、decoder 出力から record への詰め替えを移植する (§4.4: 新コアは `src/v14/` に依存しない)。

入力は §F の `XOp` (§F.2) で、decode は次のように使う:

| フィールド | decode での使い方 |
|---|---|
| `insn` (展開後 32 bit), `is_rvc` | decoder に渡す。ROB に載せて retire record に使う (§5.12)。 |
| `cinsn` (RVC の元の 16 bit) | 不正な RVC の tval (§F.8) |
| `ftq`, `foff` | OpTag (§5.2) にそのまま載せる。PC が要る後段は FTQ の読出ポートで読む (§F.3)。 |
| `pred_taken` | そのまま運ぶ。fu_bru が mispredict の判定に使う (§X.8)。 |
| `pc` | 使わない。PC 相対の値 (AUIPC、リンク、分岐の target) は fu_bru が計算する (PC の読み手は §F.3) ので、PC を即値に畳まず、`DecOp` にも載せない。 |
| `exc: ExcRec` | fetch fault (cause 1/12/20)。gpa/gva を含む。 |

`DecOp` (rq に積む record。幅は `core_types` が決める):

| フィールド | 内容 |
|---|---|
| §F 由来のフィールド | `insn`, `is_rvc`, `ftq`, `foff`, `pred_taken` |
| `cls: OpClass` | `opclass_pkg::op_class()` の結果 (§5.5) |
| `uop` | FU 固有の op 符号。ALU/MUL/DIV は `alu_pkg::AluOp`、FP は `fpu_pkg::FpuOp`、BRU/SYS/LOAD/STORE/ATOMIC は新しい小さな enum。幅は最大値の 7 bit。 |
| `src[3]` | `{use, rcls: RegClass, arch: logic<5>}`。rs3 を使うのは FMA だけ。 |
| `dst` | `{has_rd, rcls, arch}` |
| `imm` (32 bit), `rm` | 即値 (CSR 番号と uimm もここに詰める)、命令の静的な丸めモード |
| `exc: ExcRec` | fetch と decode の例外を `exc_pkg::exc_prio` で合流させたもの |

規則:

- DC1. 特権・状態に依存する合法性 (§5.5 の【決定】) の規則表は §C.8 が所有し、decode はそれを実装する。入力は csr の登録済み出力 (priv、V、mstatus/hstatus の TVM/TSR/TW/VTVM/VTSR/VTW/FS/VS、frm、*counteren、menvcfg/senvcfg の CBIE/CBCFE/CBZE (CBO の有効化) と STCE) と、`csr_pkg` に追加する CSR 属性表 (§C.8) だけで、どちらも組合せで読む。csr と csr_pkg への変更は追加だけで済む (§4.4)。lane ごとに同じ関数を for-generate で並べ、lane 0 だけの検査は無い。旧コアは同じ検査の一部を commit 時に head だけで行っていたので、slot 1 を通った op は検査を逃れた。
- 【決定】decode は live な csr 出力をそのまま読み、shadow を持たない。理由: csr の出力が変わるのは、flush を伴う retire、trap、xRET、割込みのいずれかだけである。どれも次のサイクルに `kill.valid` を立て、そのとき DQ、decode、rq にいる op をすべて捨てる (§5.4 の消費者表)。したがって生き残った op が decode で見た状態は、その op の commit 時の状態に等しい。
- DC2. rm=DYN で frm が予約値 (101-111) の FP 命令は不正命令にする (非特権仕様の規定)。frm も commit 済み状態なので、上の【決定】と同じ理由で decode で判定してよい。静的な予約 rm は §C.8 の表にある。
- DC3. fetch fault を持つ lane は decoder の出力を使わず、`fu=NONE` に例外を付けた op にする (§5.5)。decode が作る例外は、不正命令 (tval は `insn`、RVC なら `cinsn`、§F.8)、仮想命令、ECALL (cause は priv と V から決める)、EBREAK (tval は `trap_unit` が epc にする、§C.3) の 4 種類。fetch と decode の両方に該当すれば `exc_pkg::exc_prio` で合流させる (§5.8)。
- DC4. `has_rd = (rd を書く命令) && !(rcls == INT && arch == 0)`。加えて `fu == NONE ⇒ has_rd = 0`。x0 の特例はこの式だけにある (§R.3.1)。
- DC5. 非 control op の `pred_taken` は 0 である (§F の不変条件 X1)。decode はこれを `chk_*` に出すだけで、設計論理では使わない。
- DC6. M1-M4 は VU を持たないので、decode は OP-V と vector の load/store をすべて `NONE` + 不正命令にする (§V.1 の【決定】)。dispatch 側から見た要求は「VQ の credit が 0 の構成に `fu = VEC` の op を流さない」ことで、流すと dispatch が止まり続ける。
- DC7. CBO (Zicbom/Zicboz): cbo.clean/flush/inval と cbo.zero は `fu = STORE` の op にし (§5.5)、`budget.SQ` を持つ。CBIE/CBCFE/CBZE による合法性 (不正命令か仮想命令か) は DC1 の表 (§C.8) で判定する。その後の処理 (翻訳と権限検査、cbo.zero の `sb` 経由の書き込み) は §L が持つ。

### §R.3 rename

#### §R.3.1 RAT の形

- 【決定】投機 RAT と arch RAT は、どちらも `{rcls, arch}` (6 bit) で引く 64 エントリの表とし、中身は `PReg.idx` とする。理由: group 内の依存比較、walk、checkpoint を、int と fp を区別しない 1 本の for-generate で書ける。また、同じ arch 番号の int と fp を取り違える経路が構造的に無い。旧コアは `rat` と `rat_fp` に分かれ、fp の rename は lane 0 だけだった。
- reset 時の写像は `{c, a} → a` とする (各クラスの pdst 0..31)。int の pdst 0 は x0 専用で、free list に入らず、どの WB も書かない (DC4 により x0 は rename されない)。`prf` も `busy_table` も pdst 0 を特別扱いしない。reset 値 0 と ready=1 が永久に保たれるだけである。理由: x0 の特例を rename の 1 式に閉じ込めるため。旧コアでは PRF[0] への書き込みと ready のクリアが別々の場所で壊れた。
- ポート:

| ポート | 本数 | 用途 |
|---|---|---|
| 投機 RAT 読み出し | 4×RENAME_W | rs1, rs2, rs3, 旧 rd |
| 投機 RAT 書き込み | RENAME_W | rename と walk が共用する (§3.2 の WALK_W = RENAME_W) |
| 投機 RAT 全面書き込み | 1 | full kill で arch RAT をコピーする。M3 では checkpoint の restore も |
| arch RAT 書き込み | COMMIT_W | retire (§R.3.6) |

- 書き込みは、エントリごとに decode した 1 か所で行う。`for e in 0..64` の本体で、そのエントリを書く lane を選ぶ (§5.15、シミュレータの単一 slot 経路に乗る)。

#### §R.3.2 group 内の依存解決

lane l (0..take-1) について、RAT の edge 前の値を読み、より古い lane j<l の書き込みで上書きする。j の昇順に適用するので、最も若い j が勝つ。

```
wr[l]  = (l < take) && has_rd[l]                      // key = {rcls, arch}
for l, s:  src_p[l][s] = RAT[src[l][s]]; src_grp[l][s] = 0
           for j in 0..l: if wr[j] && dst[j] == src[l][s] { src_p[l][s] = pdst[j]; src_grp[l][s] = 1 }
for l:     old_p[l] = RAT[dst[l]]
           for j in 0..l: if wr[j] && dst[j] == dst[l] { old_p[l] = pdst[j] }
for e:     RAT_next[e] = pdst[最も若い l : wr[l] && dst[l] == e]   (該当が無ければ保持)
```

- 連鎖は lane 方向に O(RENAME_W) で、W ≤ 4 である。エントリ方向の直列リデュースではない (§5.15)。
- `src_grp = 1` の source は IQ の ready 初期値を 0 にする (§R.5.3)。その pdst の busy_table の値は前の持ち主のものなので読まない。
- `pdst[l]` は free_list の pop 窓から選ぶ。添字は、同じクラスで pop する lane のうち l より前にあるものの数 (lane 順の prefix) である (§R.4)。

例 (cfg_w4。SQ の credit が 0、int の pop 窓が p40, p41, ...、fp の pop 窓が p33, ... とする):

| lane | 命令 | source の写像 | 宛先 → 新 pdst (old_pdst) | 需要 | ok |
|---|---|---|---|---|---|
| 0 | `add x5, x1, x2` | x1, x2 は RAT | x5 → p40 (old = RAT[x5]) | ROB, iq_int, INT_RD | 1 |
| 1 | `fcvt.d.l f1, x5` | x5 → p40 (`src_grp`、ready 0) | f1 → fp p33 (old = RAT[f1]) | ROB, iq_fp, FP_RD | 1 |
| 2 | `add x5, x5, x5` | x5 → p40 (`src_grp`) ×2 | x5 → p41 (old = p40) | ROB, iq_int, INT_RD | 1 |
| 3 | `sd x5, 0(x2)` | x5 → p41 (`src_grp`) | なし | ROB, iq_m, SQ | 0 (SQ の credit) |

take=3 となり、lane 3 は rq に残る。RAT は x5 → p41 (lane 2 が勝つ)、f1 → p33 に更新される。int の head は 2、fp の head は 1 だけ進む。snapshot の `fl_int` は lane 0 が head+1、lane 1 が head+1、lane 2 が head+2 である。

#### §R.3.3 投機 RAT の書き込み優先順位

1 サイクルに投機 RAT を書く要因は 1 つだけで、優先順位は full kill (arch RAT をコピー) > (M3) checkpoint の restore > walk > rename である。kill.valid のサイクルと walk 中は、dispatch が take=0 にする (§R.5.2)。このため、rename の書き込みが優先順位に負けて黙って捨てられることは無い。旧 `rat.veryl` では、restore のサイクルに rename の書き込みが失われる形を、外側のゲート (`!any_redirect`) が隠していた。

#### §R.3.4 walk

- 起動: 部分 kill で `ckpt_v = 0` のとき。M1 ではすべての部分 kill がこれにあたる。順序づけは `rob` が持つ (§C.1.5): kill が見えるサイクル K の edge で、`rob` は tail を `next(keep)` にし、K+1 から毎サイクル、旧 tail から keep の直後までのエントリを若い順に WALK_W 個ずつ `o_walk[WALK_W] {valid, cls, rd_arch, old_pdst}` に登録済みで出す (has_rd=0 のエントリは valid=0 の lane)。終わるまで `rob.o_walk_busy = 1`。範囲の走査を `rob` が持つのは、ROB_N と tail を知っているのが `rob` だけだからである (§2.1 P2)。walk 中は割り当てが起きないので、巻き戻した tail より先のエントリは上書きされない。
- 適用: rename は、valid な walk lane を `RAT[{cls, rd_arch}] := old_pdst` で書く。同じバッチの中に同じキーが複数あれば、より古いエントリが勝つ。若い順に戻していくので、最後に書かれた値が keep 時点の写像になる。has_rd=0 のエントリも 1 枠を消費する (詰めるかどうかは §C.1.5 の【M3 で決定】)。
- free list、LQ、SQ は walk を待たない。K の edge で snapshot の値に巻き戻る (§5.4 T5)。busy_table には触らない。
- 終了と再開: 殺されたエントリ数を N とすると、walk は K+1 から ceil(N/WALK_W) サイクルかかり、take の再開は K + 1 + ceil(N/WALK_W) である (N=0 なら K+1)。
- full kill は walk に優先する。walk を打ち切り、arch RAT をコピーする (1 サイクル)。
- §5.4 T9 (walk 中に届いた部分 kill を捨てる) は、kill を生成する側で守る。`flush_ctrl` は `rob.o_walk_busy` の間と kill の直後のサイクルには部分 kill を採用せず、その resolve は commit の backstop (T8) に任せる (§C.4)。rename だけが kill を無視すると、ROB/LQ/SQ/free list は巻き戻るのに RAT だけが戻らない状態になる。

遅延の見積もり。walk は front end の refetch と並行して進むので、露出するのは refetch した op が rn_ に着いた時点で残っている分だけである。

| 構成 | WALK_W | N=10 | N=20 | 最悪 (N = ROB_N-1) | refetch で隠れる N の目安 |
|---|---|---|---|---|---|
| cfg_w2 | 2 | 5 サイクル | 10 | 32 | ≤ 14 |
| cfg_w4 | 4 | 3 | 5 | 32 | ≤ 28 |

「隠れる N」は、§F.9 の見積もり (M1 で Redirect から refetch した op が rename に着くまで約 8 サイクル) から、K+1+ceil(N/WALK_W) ≤ K+8 を解いた値である。旧コアでは redirect から rename までが 4.01 サイクル、commit 時 replay 1 回あたりに殺されるエントリが約 9.94 だった (ROB 32、`doc/phase14_frontend_deep_ooo_plan.md:1453-1460`)。【M3 で決定】NUM_CKPT: mispredict 1 回あたりの露出 walk サイクル数 (refetch した op が rn_ で walk に待たされたサイクル数) を両構成で測り、checkpoint pool で消える量と比べて決める。

#### §R.3.5 checkpoint pool (M3)

M1 には pool の論理を置かない。NUM_CKPT=0 では for-generate が空になり、OpTag と Kill の `ckpt_v` は 0 に固定される。M3 で追加するインタフェースは次のとおり。

- 割り当て: rn_ で control op に pool の空きを割り当て、OpTag の `ckpt`/`ckpt_v` に入れる。保存する内容は「その lane までの書き込みを反映した投機 RAT」で、§R.3.2 の上書き連鎖の lane l 時点の値から作る。【M3 で決定】1 group あたりの割り当て数 (初期案は 1) と、割り当てる対象 (すべての control op か、低確信の分岐だけか)。
- 枯渇: rename を止めない。その branch は `ckpt_v = 0` のまま、walk に fallback する (§5.4)。少なくとも 1 構成で、枯渇の経路が定常的に発火していなければならない (§3.3)。
- restore: `Kill.ckpt_v = 1` なら、K の edge で投機 RAT を pool から 1 サイクルで戻す。walk は起きない。
- 解放: 持ち主の op が retire したとき、または kill で殺されたとき。pool は kill の消費者である (§5.4)。

#### §R.3.6 retire 側の更新

commit が retire させた lane l (§5.12 C3) ごとに、`{retire, has_rd, rcls, arch, pdst, old_pdst}` を ROB エントリから受け取る。arch RAT は `arch_RAT[{rcls, arch}] := pdst` で更新する (同じキーなら若い lane が勝つ)。old_pdst は該当クラスの free_list に push する。trap や replay で終わる op は retire しないので、何もしない。その op の pdst は full kill で回収される (§R.4)。

不変条件 (所有者は rename):

- 投機 RAT と arch RAT は、どちらも同じ pdst を 2 つの arch に写さない (checker: RAT の重複マッピング)。
- 投機 RAT が写している pdst は、そのクラスの free list の空き区間 `[head, tail)` に含まれない (checker: free list の漏れ)。
- walk が終わった時点の投機 RAT は、keep を rename した直後の投機 RAT に等しい。

### §R.4 free_list

レジスタクラスごとに 1 instance を置く。エントリ数は `core_types` が導出して出す定数 `FREE_INT_N`/`FREE_FP_N` (= `PRF_<cls>_N - 32`) で、`free_list` は PRF のサイズを直接参照しない (§2.1 P2、§3.3)。以下ではこれを `FREE_N` と書く。中身は循環 FIFO で、中身は `PReg.idx`、ポインタは `FlPtr {wrap, idx}`。reset 時には pdst 32..PRF_N-1 が入っており、head=0、tail=FREE_N (満杯) である。cfg_w2 の FREE_N は int 64 / fp 32、cfg_w4 は int 128 / fp 64。

| ポート | 本数 | 契約 |
|---|---|---|
| pop 窓 `o_pop[k]` | RENAME_W | `entries[head + k]`。登録済みの配列を組合せで読む。 |
| `o_head_after[k]` | RENAME_W+1 | k 個 pop した後の head。dispatch snapshot に使う。 |
| `o_free` | 1 | `tail - head` (登録済み)。dispatch の credit。 |
| `i_pop_n` | 1 | rn_ で実際に pop する数 (受理した lane の合計)。 |
| push | COMMIT_W | commit の `o_fl_rel[COMMIT_W]` (§C.2.4)。retire した lane の old_pdst を、lane 順に tail から詰める。 |
| `i_kill` | 1 | §5.4 |

巻き戻しの代数。旧 `free_list.veryl:148-174` を一般化し、n_inflight は持たない:

- 部分 kill (checkpoint の有無によらない): int の instance は `head := kill.fl_int`、fp の instance は `head := kill.fl_fp`。
- full kill: `head := tail - FREE_N`。同じサイクルに commit は無い (§5.4 T4)。
- それ以外: `head := head + i_pop_n`。tail は push 数だけ進み、kill とは独立。

正しさの根拠: pop は op の順に、push は retire の順 (= op の順) に起こる。したがって「pop されたが、まだ push で埋め戻されていない区間」`[tail - FREE_N, head)` には、rename 済みで未 retire の op が持つ pdst がちょうど順に並んでいる。部分 kill は「keep を割り当てた直後の head」に戻すだけで、keep より若い op の pdst がすべて空きに戻る。旧コアが別に持っていた n_inflight は、同じサイクルの push 数を引き忘れる bug を起こした (`free_list.veryl:160-166` のコメント)。この式ではその種の bug は生じない。

- head と tail は、それぞれ 1 サイクルに 1 回だけ代入する (旧 `free_list.veryl:12-16` の NBA 規則)。push の書き込みはエントリごとに decode した 1 か所で行う。
- 不変条件: `0 ≤ tail - head ≤ FREE_N`。同じ pdst が空き区間に 2 回現れない (checker: free list の重複)。

### §R.5 dispatch

#### §R.5.1 credit と需要

credit はすべて所有者の登録済み出力であり、dispatch 自身は数を持たない (§5.3 R2)。

| 資源 | 所有者の出力 | 1 op あたりの需要 (`OpClass.budget` と `fu` から) |
|---|---|---|
| ROB | `rob.o_free`、`rob.o_alloc_tag[RENAME_W]` | すべての op に 1 |
| IQ k | `iq[k].o_free` | `fu ∉ {NONE, VEC}` なら、その fu を実行する IQ に 1 |
| LQ / SQ | `lq.o_free`/`sq.o_free`、`o_alloc_tag[RENAME_W+1]` | budget.LQ / budget.SQ |
| pdst | `free_list[c].o_free`、pop 窓 | budget.INT_RD / budget.FP_RD |
| VU | VU の dispatch FIFO の登録済み空き `o_alloc_rdy` (M5、§V の VA1) | budget.VQ (1 group に 1 まで、§3.4) |
| checkpoint | pool の空き数 (M3) | budget.CKPT |

- 【決定】ある FuKind を実行できる issue ポートは、すべて同じ IQ に属する (§X.2 の構成制約。`core_cfg` の FU トポロジ表 `PORT_FU`/`PORT_IQ` (§3.6) に対して elaborate 時に検査する)。理由: op の行き先 IQ が `fu` だけで決まるので、take の計算が IQ 内のポート選択 (§X.3) を待たずに済む。

#### §R.5.2 take と group の切断

```
d[l][r] = lane l の資源 r への需要 (上表)
P[l][r] = Σ_{j≤l} d[j][r]                              // lane 方向の prefix (W ≤ 4)
ok[l]   = valid[l] && (∀r: P[l][r] ≤ credit[r]) && !cut_struct[l]
take    = lane 0 から連続して ok である lane の数        // prefix-AND
take    = 0   if kill.valid || rob.o_walk_busy
```

group を切る理由。lane l で ok[l]=0 になった最初の理由を、理由ごとの event として `o_perf` に出す (§5.15。旧 HPM の sel 4 にあたる)。

1. ROB、IQ k、LQ、SQ、pdst (クラスごと) の credit 不足。
2. 2 つ目の VEC op、または VU が ready でない (M5)。
3. amocas.q を 2 宛先の op にする場合 (§5.5 の【M2 で決定】): `budget.PAIR_RD` の op は、次の lane の RAT 書込ポートと pop 窓の枠を使う。そのため lane l+1 を切る。PAIR_RD の op が最後の lane にあれば、次のサイクルに回す。crack 案を採った場合、この規則は消える。
4. (M3) 1 group あたりの checkpoint 割り当て数の上限 (§R.3.5)。

切らないもの: 例外付きの op、nonspec、alone、flush を伴う op。これらは IQ の select 条件 (§X.3) と commit の group 関数 (§5.12) が扱う。rename と dispatch に op の種別リストを書かない (§5.5 の不変条件)。旧コアの slot-1 可否リスト (`heliodor_core.veryl:4800-4810`) にあたるものは存在しない。

#### §R.5.3 割り当てと書き込み

lane l < take について、すべて同じ edge で次を行う。タグは所有者が出した値をそのまま使い、dispatch が `next()` を計算することはない (リングのサイズを知るのは所有者だけ、§2.1 P2)。

- ROB: タグは `rob.o_alloc_tag[l]`。書く内容は §C.1.1 の表のうち dispatch が書く列で、commit 用の class (`fu`, `drain`, `flush`, `alone`, `csr_wr`, `effect`, `is_rvc`)、rename 情報 (`has_rd`, `cls`, `rd_arch`, `pdst`, `old_pdst`。walk 記録を兼ねる)、OpTag の `lq`/`sq`/`ftq`/`foff`、`insn`、`recovered := 0` である。例外はエントリに書かず、`rob` の `exc_q` の木に入れる (§C.1.2)。PC は書かない (§F.3)。
- dispatch snapshot (§5.4 T6): `{lq_tail, sq_tail, fl_int, fl_fp, bar_seq}` は、lane l までの割り当てを済ませた後の値で、`lq.o_alloc_tag[P[l][LQ]]`、`sq.o_alloc_tag[P[l][SQ]]`、`free_list[c].o_head_after[P[l][c]]`、`lq.o_bar_after[P[l][BAR]]` (lane l までの `ld_barrier` op の数、§L.10) から取る。ROB の割り当てと同じ edge で書くので、ROB にいる op は必ず snapshot を持つ。
- dispatch 時完了: `fu == NONE` の op は、ROB エントリを done=1 で割り当て、例外があれば同じ edge で `exc_q` の木に入れる (§C.1.3)。IQ にも FU にも行かない (§5.5)。
- LQ/SQ: `budget.LQ`/`budget.SQ` を持つ op にタグを割り当てる。lane l の LQ タグは `lq.o_alloc_tag[P[l][LQ] - 1]`、SQ タグも同形である。load の `sq_lim` は `sq.o_alloc_tag[P[l][SQ]]`、store の `lq_lim` は `lq.o_alloc_tag[P[l][LQ]]` で、どちらも同じ表から読む (§L.3)。エントリの中身は §L が定める。
- IQ k: `fu` から決まる IQ に `{ExTag, fu, uop, src[3], nonspec, payload}` を渡す。IQ 内のエントリ選択とポート割り当ては IQ が行う (§X.3)。
- ready の初期値: source s が `use = 0` なら 1、`src_grp = 1` なら 0、それ以外は `busy_table.prf_ready[src_p] || (同じサイクルの wake lane に src_p が出ている)`。同じサイクルの wake を畳み込まないと、その wake を取り逃がす (旧 `iq_int.veryl:677-688` と同じ規則)。
- busy_table: has_rd を持つ lane の pdst について、`prf_ready` を同じ edge で 0 にする (§X.4)。`prf_done` は M5 で最初の消費者と同時に加わり (§5.7)、そのときから同じ edge で 0 にする。

不変条件 (所有者は dispatch):

- kill.valid のサイクルと walk 中は、どの所有者にも割り当てを要求しない (checker: kill のサイクルの割り当て)。
- 受理する lane は lane 0 から連続し、受理しなかった lane は `rq` に残る (§5.3 R4)。
- 各所有者に要求する割り当て数は、その所有者が出した登録済みの credit を超えない。旧 `load_queue` は `is_full` を持っていたが割り当てには使わず (`load_queue.veryl:242` は診断 `:893` でだけ読まれ、割り当ては `:249-252` で ROB の満杯だけを見る)、LQ_N = ROB_DEPTH のときしか正しくなかった。
- `fu == NONE` の op は IQ に入らず、ROB には done=1 で入る。

### §R.6 ポートのタイミング契約 (モジュールヘッダの要約)

| モジュール | 入力 | 出力 | 契約 |
|---|---|---|---|
| `decode` | §F の DQ の出力 (登録済み)、csr の登録済み出力 | `rq.i_data` | 組合せで、状態を持たない。kill は両側の lane_queue が受ける。 |
| `rename` | `rq.o_data`、`take`、pop 窓、`i_kill`、`rob.o_walk` (登録済み)、commit の `o_rat_cm` | lane ごとの写像 (組合せ) | 投機 RAT は rn_ の edge で、優先順位 §R.3.3 に従って 1 回だけ書く。 |
| `free_list` | `i_pop_n`、push[COMMIT_W]、`i_kill` | pop 窓と `o_head_after` (登録済みの配列とポインタから組合せ)、`o_free` (登録済み) | head と tail はそれぞれ 1 サイクルに 1 回だけ代入する。 |
| `dispatch` | `rq.o_valid`/`o_data`、各所有者の credit (登録済み)、`kill`、`rob.o_walk_busy` | `rq.i_take`、各所有者への割り当て | take は登録済みの値だけから作る。下流の ready からの組合せ経路は無い (§5.3 R2)。 |

### §R.7 M1b と M3 で出荷するもの

| 項目 | M1b | M3 以降 |
|---|---|---|
| 段 | decode (組合せ) + rq + rn_ の 1 段 | rn_ の分割は、CP 分解で名指しされたときだけ |
| 回復 | 部分 kill は walk、full kill は arch RAT のコピー。NUM_CKPT=0。 | checkpoint pool (【M3 で決定】NUM_CKPT と割り当て方針)。walk は fallback として残る。 |
| walk 中の部分 kill | flush_ctrl が出さない (T8 に任せる) | §5.4 T9 の【M3 で決定】 |
| amocas.q の形 | §5.5 の【M2 で決定】(M2) | |
| VEC | dispatch しない (VQ の credit 0、DC6) | M5 で VU の alloc を接続する |
| cfg_w4 | elaborate でき、rv64ui のサブセットが通る | ゲートの梯子をすべて通す |
| rq の深さ `RQ_N`、IQ ポート割り当て方針 | 2×FETCH_W、最小占有 (§X.3) | sweep で決める |

---

## §X スケジューラと実行

範囲: dispatch が IQ に書いた後から、WB packet が PRF・ROB・busy_table に届くまで。FU 契約は §5.6、WB・wakeup・bypass の方針は §5.7、kill は §5.4 に従う。memory pipe (§L) の中身は扱わないが、memory 側の IQ と WB 予約には本章の `iq` と `wb_resv` をそのまま使う。本章が所有するモジュールは `iq`、`busy_table`、`wb_resv`、`prf`、`exec_port`、`fu_*` と、`fu_blocking_shell`、`fp_misc` (いずれも §4.2 に登録済み、中身は §X.8) である。

### §X.1 発行パイプラインとタイミング定数

```
サイクル  S                  A = S + ISS_TO_ACC         A+1 .. A+L-1     W = A + L                 W+1
          is_: select        rr_/ex1_: PRF 読み出し     FU 内部の段      o_wb (登録済み) が WB バス  PRF から読める
          WB 枠の予約        + bypass + FU 受理                          PRF/ROB/busy に書く
          (L=1 なら wake)    iq_release                                  bypass の源
wake lane: WB サイクル W の値は W - WAKE_LEAD に、その WB ポートの wake lane に出る
```

`fu_pkg` の定数。すべての構成で共通の値を取るパラメータであり、knob ではない (§2.1 P4):

| 定数 | M1 の値 | 意味 |
|---|---|---|
| `RR_DIST` | 0 | PRF を読むサイクルから FU 受理までの距離 |
| `ISS_TO_ACC` | 1 + RR_DIST = 1 | select から FU 受理 (A) までの距離。間に `stage_reg` が 1 つある。 |
| `WAKE_LEAD` | ISS_TO_ACC + 1 = 2 | wake event から WB までの距離 |
| `PRF_WR` | 1 | WB バスに出たサイクル W の値を PRF から読めるのは W+1 から |
| `LAT_<FU>`, `PIPE_<FU>` | §X.2 | §5.6 の LATENCY と PIPELINED |

導出:

- wakeup: WB サイクルが W の値を使う消費者は、W - ISS_TO_ACC に select されれば A = W となり、bypass から受け取れる。select は登録済みの ready だけを見るので、wake event は W - WAKE_LEAD に出す。pipelined FU の op をサイクル S に select した場合、W = S + ISS_TO_ACC + L なので、wake は S + L - 1 に出す。L=1 なら select と同じサイクルで、grant から組合せで出る。
- 安全条件: wake を W - WAKE_LEAD より前に出してはならない (投機 wakeup を導入するまで)。それより後に出すのは正しい。その場合、消費者は PRF から読む。
- bypass の深さ = RR_DIST + PRF_WR = 1。bypass の源は WB バス (登録済みの `o_wb`) だけで、FU 内部の中間値は使わない。そのため深さは LATENCY に依存せず、各 bypass 点の入力本数は、その source のクラスを書く WB ポートの数になる。
- 【決定】M1 は PRF の読み出しを FU の受理サイクルに置く (RR_DIST=0)。理由: bypass 点が 1 つで済み、ALU の back-to-back を保ったまま、select と PRF 読み出しの間に `stage_reg` が入る。旧コアの FP 経路では、select、PRF 読み出し、FPU の第 1 段が 1 サイクルに入っていた。RR 段を足すときは、`stage_reg` を 1 つ挟んで RR_DIST=1 とし、bypass 点を `for k in 0..=RR_DIST` で 1 つ増やす。wake のタイミングは上の式で自動的に追従する (§5.3 R6 の局所変更)。

### §X.2 構成表

#### ポート、FU、WB、PRF

cfg_w2 (2-2-2-1-2)。§5.7 で決定済みの表を、FU 単位に展開したもの:

| issue ポート | FU | LATENCY / PIPELINED | WB ポート (種別) | PRF 書込 |
|---|---|---|---|---|
| p0 | ALU, BRU, SYS | 1 / 1 | wb0 (RESERVED) | int |
| p0 | MUL | 2 / 1 | wb0 (RESERVED) | int |
| p0 | DIV | 36 (最小) / 0 | wb0 (HOLE_FILL) | int |
| p1 | ALU, FMISC | 1 / 1 | wb1 (RESERVED) | int, fp |
| p1 | FMA | 2 / 1 | wb1 (RESERVED) | fp |
| p1 | FDIV (div, sqrt, fround) | 6 (最小) / 0 | wb1 (HOLE_FILL) | fp |
| m0 | LOAD, STORE (cbo.* を含む、§5.5), ATOMIC | §L | wbm0 (load は pipe の固定レイテンシで予約、io_unit/atomic_unit は HOLE_FILL) | int, fp |

cfg_w4 (4-4-6-2-4)。§5.7 の案で、【M3 で決定】(FU ごとの使用率を sweep で測る):

| issue ポート | FU | LATENCY / PIPELINED | WB ポート (種別) | PRF 書込 |
|---|---|---|---|---|
| p0, p1 | ALU, BRU | 1 / 1 | wb0, wb1 (RESERVED) | int |
| p2 | ALU / MUL | 1 / 1、2 / 1 | wb2 (RESERVED) | int |
| p3 | ALU, SYS / DIV | 1 / 1、36 / 0 | wb3 (RESERVED / HOLE_FILL) | int |
| p4 | FMA / FMISC | 2 / 1、1 / 1 | wb4 (RESERVED) | int, fp |
| p5 | FMA / FDIV | 2 / 1、6 / 0 | wb5 (RESERVED / HOLE_FILL) | fp |
| m0, m1 | §L (§5.9 の能力表: ATOMIC は m0 だけ) | §L | wbm0, wbm1 | int, fp |

blocking FU の LATENCY は最小値 (= leaf の固定サイクル + WAKE_LEAD) で、スケジューラは使わない (§5.6 F2)。FDIV の最小は fround の 4+2、FP の単精度 div/sqrt は 17、倍精度 div は 31、倍精度 sqrt は 32。

#### PRF のポート数 (導出)

source slot ごとに、読み得るクラスを FU から決める:

| FU | s0 | s1 | s2 |
|---|---|---|---|
| ALU, BRU, MUL, DIV, SYS | INT | INT | |
| FMA | FP | FP | FP |
| FMISC | INT/FP | FP | |
| FDIV | FP | FP | |
| LOAD | INT | | |
| STORE, ATOMIC (§L が変えうる) | INT | INT/FP | |

ポートの読出本数 = slot ごとに、そのポートの FU 集合が使うクラスの和をとり、数えたもの。書込本数 = そのクラスを書ける WB ポートの数。

| | int 読出 | fp 読出 | int 書込 | fp 書込 | bypass 比較器 (読出 slot × 源の WB ポート数) |
|---|---|---|---|---|---|
| cfg_w2 | 6 (p0 2, p1 2, m0 2) | 4 (p1 3, m0 1) | 3 | 2 | int 6×3 + fp 4×2 = 26 |
| cfg_w4 (【M3 で決定】) | 13 (p0-p3 各 2, p4 1, m0/m1 各 2) | 8 (p4 3, p5 3, m0/m1 各 1) | 7 | 4 | int 13×7 + fp 8×4 = 123 |

cfg_w2 の値は §3.2 と一致する。この本数には、retire record の rd 値 (§5.12) と VU の scalar 読み出し (M5) の分は含まない。それらを PRF から読むと決めた場合は、§C/§V がその分を足す。

#### IQ の構成

| 構成 | IQ (番号 q) | 担当ポート | エントリ数 (初期値) | source 数 | wake lane | wake 比較器 |
|---|---|---|---|---|---|---|
| cfg_w2 | iq_x (0) | p0, p1 | 24 | 3 | 3 | 216 |
| cfg_w2 | iq_m (1 = `MEM_IQ`) | m0 | 16 | 2 | 3 | 96 |
| cfg_w4 | iq_int (0) | p0-p3 | 32 | 2 | 8 | 512 |
| cfg_w4 | iq_fp (1) | p4, p5 | 24 | 3 | 8 | 576 |
| cfg_w4 | iq_m (2 = `MEM_IQ`) | m0, m1 | 24 | 2 | 8 | 384 |

- 【決定】memory 側の IQ も FU トポロジ表に含める。`N_IQ`、`IQ_N[]`、`IQ_NSRC[]` は memory IQ を含めた全 IQ を数え、新しい定数 `MEM_IQ` がその番号を表す。すべての memory pipe は `MEM_IQ` から発行する。`PORT_IQ[]` は exec ポートだけを表し、`MEM_IQ` を指さない。理由: memory 側の IQ も同じ generic `iq` の instance なので、エントリ数と source 数を同じ表で持てば構成の差が表だけに閉じるため。

- 【決定】cfg_w2 では、p1 が ALU と FP を兼ねるので、整数と FP を 1 つの IQ (iq_x) に入れる。cfg_w4 では、FuKind を担当するポートが int 側と fp 側にきれいに分かれるので、IQ を分けて source 数と比較器を減らす。どちらも同じ generic `iq` の instance で、違いは構成表だけである。
- 【M3 で決定】エントリ数。初期値は IQ 合計を ROB_N の約 0.6 倍とした (旧コアは 16/32)。IQ ごとに 1 軸ずつ sweep し、IPC 曲線の膝で決める。
- wake 比較器は「エントリ × source × wake lane」で増える。cfg_w4 は cfg_w2 の約 5 倍で、シミュレーション速度 (§5.15 の cy/s) の主要な項になる。

#### 構成制約 (`CFG_ERR` で検査、§3.5)

下の各項目は §3.5 の `CFG_ERR` の bit として検査する (最後の項目を除く)。

- ある FuKind を担当するポートは、すべて同じ IQ に属する (§R.5.1)。
- 1 つの exec ポートに載せる HOLE_FILL の FU は高々 1 つ (wb_resv の HOLE_FILL 要求者が 1 つで済む)。
- SYS を持つポートはちょうど 1 つ。BRU を持つポートは 1 つ以上。
- `op_class` が出す FuKind (NONE, LOAD, STORE, ATOMIC, VEC を除く) は、どれも 1 つ以上のポートに載っている。NONE, LOAD, STORE, ATOMIC, VEC は exec ポートに載せない。
- 各 IQ は 1 本以上の issue ポート (`MEM_IQ` なら memory pipe) を持つ。`PORT_IQ[p]` は `MEM_IQ` 以外の有効な番号である。
- WB ポートが書けるクラスは、そのポートの FU の宛先クラスの和である (これは FU 集合からの導出であり、構成の検査ではない)。

これらの表は `core_cfg` (§3.6) の FU トポロジ表 `PORT_FU: FuSet [ISSUE_W]`、`PORT_IQ: u32 [ISSUE_W]`、`N_IQ: u32`、`MEM_IQ: u32`、`IQ_N: u32 [N_IQ]`、`IQ_NSRC: u32 [N_IQ]` で表し、構成によって変わるのはこれらの値だけである。

- 【決定】トポロジ表は M1b から最終形の FU 集合を持つ。M1b が instantiate するのは必要な FU だけで、残りは表の上で予約された枠とする (§X.12)。理由: 上の制約 (どの種別にも行き先がある、SYS は 1 本、HOLE_FILL は 1 つ) の検査が、最終形の FU 集合に対して働く必要があるため。

### §X.3 iq

汎用の issue queue。ポート数、エントリ数、source 数は構成表から読む (サイズを所有するのは iq、§2.1 P2)。

エントリの中身は 2 つの配列に分ける:

| 配列 | フィールド | 読み方 |
|---|---|---|
| hot (毎サイクル全エントリを走査) | `state` {FREE, WAIT, ISSUED}、`port`、`tag: ExTag`、`fu`、`src[N_SRC]` {use, pr: PReg, rdy}、`nonspec`、(memory 側の load) `obey_fence` と `bar_w` (§L.10) | wakeup、select、kill |
| cold | `uop`、`imm`、`rm`、`ftq`/`foff`、`pred_taken`、(memory 側) LQ/SQ タグなど | select された 1 エントリだけを読む |

【決定】hot と cold を別配列にする。理由: 毎サイクル全エントリを舐めるのは hot だけで、cold はポートごとに 1 回の動的読み出しで済む (シミュレーション速度。§5.15)。

エントリの寿命:

```
FREE --(dispatch の割り当て)--> WAIT --(select)--> ISSUED --(iq_release)--> FREE
任意の状態 --(killed(kill, tag.rob))--> FREE
```

- `iq_release[p] = {valid, entry}` は、そのポートの受理段 (exec_port/mem_pipe) が、op と一緒に運んできたエントリ番号で返す。M1 では FU (または pipe) の受理と同義である (§5.7)。
- 投機 load-hit wakeup を後で足すとき (§5.7 の【M3 で決定】) の追加は、入力 `i_cancel[p] = {valid, entry, src mask}` (ISSUED から WAIT に戻し、指定された source の rdy を落とす) と、`iq_release` の定義の変更 (投機が確定してから解放する) で済む。これを局所変更にするため、次を M1 から保証する: (a) payload は release まで保持する、(b) source の rdy は 1 本ずつ立て下げできる、(c) エントリ番号が select から受理まで op と一緒に運ばれる、(d) grant と release は別のポートである、(e) `o_free` は FREE の数だけを数える。dispatch と FU 契約は変わらない。busy_table には、取り消した wake の `prf_ready` を落とすクリア入力が加わる。

割り当て (dispatch のサイクル):

- この IQ に向かう op が最大 RENAME_W 個来る。i 番目の op は i 番目の空きエントリに入る。エントリ e が受け取る op は、`rank(e) = popcount(free[0..e-1])` で決まる (`free[e] && rank(e) < n_in` のとき)。popcount は `tree_pkg` の prefix で求め、直列ループで書かない。書き込みはエントリごとに 1 か所。
- 【決定】ポートの静的割り当て: 候補は、この IQ のポートのうち `PORT_FU` がその op の fu を含むもの。その中から「登録済みの割り当て数 `cnt_q[p]` + 同じ group で先に割り当てた数」が最小のポートを選び、同数なら番号の小さいポートを選ぶ (lane 方向の O(RENAME_W) 連鎖)。理由: M1 で最も単純で、lane やポートの特例を持たない。【M3 で決定】方針の比較 (最小占有、round robin、FU 種別ごとの固定) を、ポート使用率の sweep で行う。
- 割り当て後、エントリのポートは変わらない。

wakeup: 毎サイクル、各エントリの各 source について `rdy |= ∃w: wake[w].valid && wake[w].pdst == src.pr` とする (PReg の比較なのでクラスも含む)。wake lane は WB ポートと 1 対 1 で、本数は ISSUE_W + MEM_W。lane 方向の OR は synth が平衡化する AND/OR 形で書く。memory ポートの wake lane は、§L が公表する固定の先行量 (WB の何サイクル前か、0 以上 WAKE_LEAD 以下) で出る。先行量がポートごとに固定なので、どの lane でも event は 1 サイクルに高々 1 つである。M1 の load は HIT 応答を見てから wake する (§5.7) ので、先行量が WAKE_LEAD に満たない分だけ、消費者は bypass ではなく PRF から読む。

select (ポート p ごとに 1 本の木):

```
req[p][e] = state[e]==WAIT && port[e]==p && ∀s (rdy[e][s] || !use[e][s])
         && fu_avail[p][fu[e]]                                   // blocking FU: o_ready かつ issue 段に先行 op が無い
         && (fu[e] が RESERVED ⇒ wb_ok[p][claim_off(p, fu[e])])  // §X.5
         && (!nonspec[e] || (tok.valid && tok.tag == tag[e].rob)) // oldest token、§5.13 I5
         && (memory 側: !i_port_hold[p] && !(load && obey_fence[e])、§L.10。§5.7)
winner[p] = argmin_older(req[p][*])   // heap 木、段ごとの配列、1 節点に older() を 1 回
```

- `claim_off(p, fu)` は exec ポートでは ISS_TO_ACC + LAT_fu、memory ポートでは §L.2 が定める。
- `obey_fence[e]` は dispatch で `bar_w != lq.o_bar_ret` のとき立ち (より古い ld_barrier op が未 retire)、`i_load_fence {valid, seq}` (`lq` が出す、barrier が 1 つ retire したサイクルに valid で、その retire 後の `bar_ret`) の seq が `bar_w` に等しいサイクルに落ちる (§L.10)。
- 【決定】select は ROB タグの木で行う (葉は 2 の冪に詰め、無効で埋める)。理由: 任意の IQ_N に一様に書け、age の比較は `older()` の 1 本で済む。age matrix は IQ_N² bit を要する。旧コアで 8 エントリの両者を比べた測定 (2026-06-30) は、合成器がゲートの一部しか見ていなかった期間のものなので根拠にしない。select 方式の再検討は、CP 分解で select が名指しされたときだけ行う。
- grant の出力: `{valid, entry, ExTag, fu, uop, src[*].pr}` と、winner の cold payload。これらは exec_port の `stage_reg` へ。同時に wb_resv に予約を、exec_port の wake 遅延線に wake を出す。
- kill: killed() に当たるエントリは、その edge で FREE になる。rdy ビットは kill では触らない (§5.4)。

不変条件 (所有者は iq):

- ISSUED のエントリは select されない。`iq_release(p, e)` を受けたとき、e は ISSUED で、そのポートは p である (checker)。
- `o_free` は登録済みで、FREE の数に等しい。
- select が使うのは、登録済み状態、wb_resv の同じサイクルの HOLE_FILL 予約 (登録済み状態からの前向きの組合せ)、oldest token (登録済み) だけである。select から wb_resv の grant に戻る組合せ経路は無い。
- nonspec の op は、oldest token のタグが自分のタグに等しいサイクルにだけ select される。

### §X.4 busy_table

レジスタクラスごとに `prf_ready` を PRF のエントリ数だけ持つ。エントリ数は `core_types` の導出定数から取る (§3.3、P2)。【決定】`prf_done` は M1 では作らず、最初の消費者 (M5 の VU の scalar オペランド、§V) と同時に加える。理由: 読まれない状態は DEAD scaffolding である (§5.15、§5.7)。下表の `prf_done` の行は M5 からのものである。

| ポート | 本数 | 契約 |
|---|---|---|
| クリア | RENAME_W | rn_ で割り当てた pdst のビットを 0 にする (M5 からは `prf_done` も) |
| prf_ready のセット | ISSUE_W + MEM_W | wake lane |
| prf_done のセット (M5) | WB ポート数 | `wb.valid && wb.tag.has_rd` の pdst |
| prf_ready の読み出し | RENAME_W × 3 | dispatch の ready 初期値 (組合せ) |
| prf_done の読み出し (M5) | 消費者ごと | IQ を通らずに PRF を読む消費者 (VU の scalar オペランド) |

- reset 値はすべて 1 (arch に写っている pdst は ready。空きの pdst の値は割り当て時にクリアされる)。
- 同じサイクルに同じ pdst のクリアとセットが来たら、クリアが勝つ。kill の完全性 (§5.4 T7) と割り当て禁止 (T2) により、正しい動作では両者は重ならない。重なった回数は checker が数える。
- `prf_ready` はスケジュール上の wakeup で、使うのは IQ の初期値だけである。`prf_done` (M5) は「読んだ時点で値が PRF にある」ことを示す (W の終わりにセットされる)。
- checker `chk_sched` の「受理時の source が PRF にあるか、WB バスに出ているか」の検査は、checker 自身が WB を観測して持つビット表で行い、設計論理の `prf_done` には頼らない (checker は観測専用、§5.15)。
- 書き込みはエントリごとに decode した 1 か所で行う。

### §X.5 wb_resv

WB ポートごとに 1 つ (ISSUE_W + MEM_W 個)。状態は未来の WB 枠の予約ビット `resv_q[o]` で、o は現在から何サイクル先の枠かを表す。`D_p = ISS_TO_ACC + (そのポートの RESERVED FU の最大 LATENCY)` とすると、持つのは o = WAKE_LEAD..D_p-1 だけでよい。o < WAKE_LEAD の枠は、もう誰も予約できない (select の予約は ISS_TO_ACC+1 = WAKE_LEAD 以上、HOLE_FILL も WAKE_LEAD 以上)。o = D_p の枠は、サイクルの始めに必ず空いている。cfg_w2 では p0/p1 とも D_p=3 で、状態は `resv_q[2]` の 1 bit になる。LATENCY 1 の FU しか持たないポート (cfg_w4 の p0, p1, p3) では D_p=2 で、状態は無い。

- RESERVED: サイクル t に LATENCY L の op を select したら、o = ISS_TO_ACC + L の枠を予約する。select の条件は `wb_ok[o] = !resv_q[o] && !(hf.valid && hf.off == o)`。予約ビットは毎サイクル 1 つずつ近づく (`resv_d[o] = resv_q[o+1] || (今サイクルの予約 == o+1)`、`resv_q[D_p]` は 0 とみなす)。
- HOLE_FILL: 要求者 (exec ポートでは blocking shell が高々 1 つ。memory 側の保持者 `io_unit`、`atomic_unit`、VU の scalar 結果は、どれも最古の op の結果しか持たないので、同時に `hf_req` を出すのは高々 1 つである、§5.13.1) が `hf_req` を出す。`hf_req` は登録済みの値 (shell の状態、leaf の `o_valid` パルス、kill) だけから作る。grant は `hf.off = min{ o ∈ [WAKE_LEAD, D_p] : !resv_q[o] }` (prefix の first-zero で、D_p は小さい)。o = D_p の枠はサイクルの始めに必ず空いているので、grant は同じサイクルに必ず出る。保持中の結果は、要求から D_p = ISS_TO_ACC + 最大 LATENCY サイクル以内に WB する (§5.7 の上限そのもの)。
- grant の下限を WAKE_LEAD にするのは、HOLE_FILL の結果についても wake を WB の WAKE_LEAD 前に出せるようにするためである。これで、どの WB ポートでも wake lane の event は 1 サイクルに高々 1 つになる。DIV の結果が使えるのは最大 1 サイクル遅れるが、34 サイクルの演算に対しては無視できる。
- 組合せ経路の向きは、`resv_q` → hf grant → select のマスク → `resv_d` だけである。select から grant へ戻る経路は無い (§5.7)。
- kill の消費者ではない。kill された op の枠は、空のまま使われずに終わる (§5.4)。
- 1 つのポートに LATENCY の異なる FU が載る場合 (cfg_w2 の p0 の ALU 1 と MUL 2、p1 の FMISC 1 と FMA 2) の衝突は、予約で解消する。M2 から整数側 (rv64um) でも FP 側でも動く (M1b で `fu_mul` を入れればその時点から)。

例 (cfg_w2 の p0。D=3):

| サイクル | 出来事 |
|---|---|
| t0 | MUL a (L=2) を select。off 3 (WB t3) を予約し、wake 遅延線に遅延 1 で積む。 |
| t1 | a と独立な ALU b (L=1) は off 2 (= t3) を要求するが、`resv_q[2]` が埋まっているので p0 では select されない。a の wake が出る (t1 = t3 - WAKE_LEAD)。 |
| t2 | a に依存する ALU d を select (ready は t1 の終わりに立った)。off 2 (WB t4) を予約。ここでは d が b より古いとする。b は t3 に select され、WB は t5。 |
| t3 | a の WB。d が受理され、a の値を WB バスから bypass で受け取る (back-to-back)。 |
| t4 | d の WB。 |

DIV (同じ p0) の場合: 受理 A、leaf の `o_valid` は V = A+34。V に kill されていなければ `hf_req` が立ち、同じサイクルに grant (たとえば off 2) が出る。wake は遅延 0 で V に出て、WB は V+2 = A+36。WB の次のサイクルに `o_ready` が戻る。

### §X.6 prf

汎用の多ポート FF 配列 `prf #(N_ENTRY, N_READ, N_WRITE)` で、クラスごとに 1 instance。

- 読み出しは、登録済みの配列から組合せで行う。アドレスは `stage_reg` の出力 (登録済み) である。
- 書き込みはエントリごとに decode した 1 か所で、書込ポートを one-hot の AND-OR で選ぶ。pdst ごとに生産者は 1 つなので、同じエントリに 2 本の書込ポートが同時に来ることはない (checker: 二重 writeback)。
- 書き込みから読み出しへの forwarding は持たない (PRF_WR=1。W のサイクルは bypass が受け持つ)。
- エントリ 0 を特別扱いしない。すべて 0 で reset する (int の pdst 0 は x0 として永久に 0、§R.3.1)。
- 書込ポート k はクラスを書ける WB ポートに 1 対 1 で接続し、書込 enable は `wb.valid && wb.tag.has_rd && wb.tag.pdst.cls == C` とする。宛先クラスは packet が運ぶので、旧コアの `cdb_dest_is_fp` のような、優先順位をなぞる mux は存在しない (§5.7)。
- SRAM には推論させない (多ポートの RF は、実在する RF と同じく FF と書込 decoder として作る。§5.15 の「エントリごとに decode した 1 か所の書き込み」に従う)。

### §X.7 exec_port

issue ポート 1 本分。for-generate で ISSUE_W 個並べ、中身は `PORT_FU[p]` を見る generate-if だけで変わる。

- is→ex の `stage_reg` (kill を内蔵)。中身は grant の出力。
- RR と bypass (サイクル A): source slot ごとに、そのクラスを書く WB ポートの packet のうち `valid && has_rd && pdst == src.pr` のものがあればそのデータ、無ければ PRF の読み出し値を使う。一致は高々 1 つなので AND-OR で選ぶ。比較と選択は `core_types` の関数にし、memory pipe の第 1 段 (§L) も同じ関数を使う。
- FU への分配: `i_valid[k] = stage.valid && stage.fu == k`。FU 固有の入力 (`imm`、`rm`、PC と予測、CSR の読み出し値) はここで配る。動的丸めモードは、rm=DYN なら csr の frm (live。§5.5 により正しい) を使う。
- PC と予測: BRU を持つポートは、PRF と同じサイクル A に、`stage` の `(ftq, foff)` で ftq の読出ポート (§F.3) を 1 本引き、`pc = block base + 2·foff` と `pred.target` を得る。読み出しは、op が生きている間はいつでも正しい (§F の FQ1, FQ3)。
- WB packet: そのポートの FU の `o_wb` の OR。予約により、有効なのは高々 1 つである (checker)。packet は PRF の書込ポート、ROB の完了ポート、busy_table の done、全 bypass 点に配り、BRU を持つポートでは `flush_ctrl` の resolve 入力 (§C) にも配る。packet の外に sideband は無い (§5.6 F5)。
- wake 遅延線: `stage_reg` (kill を内蔵) の深さ D_p - WAKE_LEAD の列。select (遅延 L-1) と HOLE_FILL の grant (遅延 off - WAKE_LEAD) から押し込み、遅延が 0 になったものを `o_wake {valid, pdst}` に出す。予約の一意性により、1 サイクルに高々 1 つ。遅延線は kill を消費するので、kill された op の wake は edge の後には出ない。
- blocking FU の可用性: `fu_avail = fu.o_ready && !(issue 段がその FU 向けの op を保持している)`。`o_ready` は登録済みで、受理の次のサイクルにならないと落ちない。そのため、select から受理までの ISS_TO_ACC サイクルの間に 2 つ目を select しないように、このマスクを掛ける。
- `iq_release[p]`: サイクル A に、`stage.valid` とエントリ番号を IQ へ返す。

### §X.8 FU

| FU | 由来 | LATENCY / PIPELINED | 中身 |
|---|---|---|---|
| `fu_alu` | 旧 `alu.veryl` の ALU 部を移植 (MUL/DIV 部は除く) | 1 / 1 | RV64I (AUIPC を除く)、Zba/Zbb/Zbs/Zicond、Zimop (rd に 0)。PC は入力に取らない。cpop/clz/ctz (`alu.veryl:94-131` の 64 反復の直列ループ) は `fpu_pkg::popcount64`/`clz::<W>` の木に置き換える。 |
| `fu_bru` | 旧 `alu_wrap.veryl:143-187` の比較と target を移植 | 1 / 1 | 条件分岐、JAL、JALR、AUIPC。data はリンク (pc+2/pc+4) か、AUIPC の pc+imm。control op では `br = {valid, mispredict, taken, next_pc, ftq, foff}` を出す。`mispredict = taken != op.pred_taken \|\| (taken && target != pred.target)` (§F.9。「予測した次 PC と解決した次 PC の不一致」と同値)。not-taken でも `next_pc = pc + len` を出す (§C.1.4)。C 拡張があるので target の misaligned 例外は生じない。 |
| `fu_mul` | 旧 `alu.veryl:40-62, 139` の乗算を移植 | 2 / 1 | 段 1: 部分積と積、段 2: hi/lo/W の選択と符号補正、出力レジスタ。 |
| `fu_div` | `int_divider` (共有、そのまま) + `fu_blocking_shell` | 36 / 0 | leaf は 34 サイクル固定 (`int_divider.veryl:10`)。 |
| `fu_fma` | `fp_adder`/`_s`、`fp_multiplier`/`_s`、`fp_fma`/`_s` (PIPE=1、STAGE3=0) | 2 / 1 | leaf の中点レジスタは毎サイクル捕捉するので、valid/ExTag/op/rm は並走する `stage_reg` で運ぶ (§5.6 F1)。 |
| `fu_fmisc` | 新 leaf `fp_misc` (`fpu_wrap.veryl` の結果 case `:1480-2767` と fflags case `:1069-1476` から cheap-op の arm を抽出) | 1 / 1 | sgnj、min/max(m)、比較 (quiet 含む)、class、cvt (Zfhmin、fcvtmod を含む)、mv、FLI。 |
| `fu_fdiv` | `fp_divider`/`_s`、`fp_sqrt`/`_s` (共有) + fround 経路 + `fu_blocking_shell` | 6 / 0 (最小) | 一度に 1 op。fround は `fp_adder`/`_s` を 2 段直列にした経路 (PIPE=1) で、shell が入力を保持し、4 サイクルで完了する。 |
| `fu_sys` | 旧 `alu_wrap.veryl:376-393` の CSR 新値計算を移植 | 1 / 1 | §X.8.3 |

- 【決定】AUIPC と JAL も `fu_bru` で実行する。理由: PC を読めるのは ftq の読出ポートを持つ BRU ポートだけで (§F.3)、IQ に 64 bit の PC や decode で畳んだ 64 bit の定数を持たせずに済む。JAL は front end で target が確定しており mispredict しない (§F.8) が、リンクの計算に PC が要る。
- 【決定】`fu_mul` の LATENCY は 2 とする。理由: MUL を ALU から外して乗算器の数をトポロジ表で決められるようにし、さらに整数側でも、1 つの WB ポートに異なる LATENCY が混在する予約と、wake 遅延線を rv64um で動かす。【M3 で決定】最終値: coremark/dhrystone の LATENCY sweep で決める。
- 【決定】fround と froundnx は `fu_fdiv` の shell で実行し、FuKind は FDIV とする。理由: 1 FU = 1 LATENCY (§5.6) を崩さず、RESERVED ポートに 4 サイクルの経路を足さずに済む。Zfa の fround は稀で、旧コアも 4 サイクル占有の blocking 扱いだった。
- 【決定】`fu_fmisc` の中身は新しい leaf `fp_misc` (純組合せ) に抽出し、`fpu_wrap` には手を入れない (§5.6 の凍結)。M5 までは cheap-op の論理が `fpu_wrap` と `fp_misc` に 2 重にある。【M5 で決定】VU の `u_vfpu` も新しい FP FU に移して 2 重を解消するか、`fpu_wrap` を VU 専用のまま残すか: VU の vector テスト群がビット一致で通るかと、移したときの VU の LATENCY 変化で決める。
- 旧コアの `alu`、`alu_wrap`、`lsu` は `v14_` に改名される private モジュールである (§4.4) ので、instantiate せずに論理を移植する。`int_divider` と fp_* の leaf は共有モジュールで、そのまま instantiate する。

#### §X.8.1 fu_blocking_shell

`fu_div` と `fu_fdiv` が使う共通の shell。旧コアが FU ごとに別々に持っていた `started`/`done`/`owner` の 3 つのレジスタを、1 つの占有状態に置き換える (§5.6 F2)。

| 状態 | 意味 |
|---|---|
| `occ_q` | 受理から WB (または kill) まで 1 |
| `tag_q`, `op_q` | 受理時に latch した ExTag と op。完了はこのタグに帰属させ、提示中の op とは比較しない。 |
| `res_q`, `hold_q` | leaf の結果 (data、fflags) と、保持中フラグ |
| `wb_off_q` | HOLE_FILL の grant で得た WB までのサイクル数 |

- `o_ready = !occ_q` (登録済み)。受理で occ を立て、leaf の start (`i_valid` パルス) と operand を出す。受理のサイクルに kill が見えていれば、その op にも `killed()` を適用し、捕捉も start もしない。
- leaf の `o_valid` を見たサイクルに結果を捕捉し、`hf_req` を立てる。そのサイクルに `killed(kill, tag_q)` なら、`o_valid` をマスクして捕捉しない。
- grant を受けたら `wb_off_q` を数え、WB サイクルに `o_wb` を出して occ を落とす。
- kill: `killed(kill, tag_q)` で leaf の `i_flush` を駆動し、occ、hold、`hf_req` を落とす。予約済みの WB 枠は空のまま終わる。
- leaf の `o_busy` は使わない。受理のサイクルと `o_valid` のサイクルに low になるため、そのまま使うと再 start を許してしまう。
- fround は leaf が valid を持たないので、shell の中の 4 サイクルのカウンタを `o_valid` の代わりにする。

#### §X.8.2 FP の共通規則

`fpu_pkg::FpuOp` の FU への割り当て (decode の `op_class` がこの表を実装する):

| FU | FpuOp |
|---|---|
| `fu_fma` | FADD/FSUB/FMUL、FMADD/FMSUB/FNMADD/FNMSUB (S, D) |
| `fu_fmisc` | FSGNJ*/FMIN/FMAX/FMINM/FMAXM、FEQ/FLT/FLE/FLEQ/FLTQ、FCLASS、FCVT の全種 (整数との変換、S/D 間、Zfhmin の H、FCVTMOD.W.D)、FMV.X.*/FMV.*.X、FLI |
| `fu_fdiv` | FDIV/FSQRT (S, D)、FROUND/FROUNDNX (S, D) |

- 入力の NaN-unboxing (S/H)、rm=DYN の解決、結果の NaN-boxing は、`fpu_wrap` の該当部を移植し、`fpu_pkg` に関数として追加する (追加だけの変更、§4.4)。
- 宛先クラスは decode が決め、`ExTag.pdst.cls` が運ぶ。FMV.X.*、FCVT.{W,L}*、FEQ/FLT/FLE (quiet 版を含む)、FCLASS は INT、それ以外の FP op は FP である。rd=x0 の INT 宛先は has_rd=0 になるので、PRF[0] を書く経路は無い。
- fflags は packet の 5 bit で運び、ROB エントリに記録し、commit が retire した lane の分を OR する (§5.12 C3)。
- 例外: exec ポートの FU は例外を作らない。合法性はすべて decode で決まる (§5.5、§R.2)。packet の `exc` は形をそろえるために残し (§5.6 F5)、exec ポートでは定数 0 になる。0 でない `exc` を出すのは memory pipe だけである。
- §5.6 の【決定】のとおり、スカラの FMA は `fp_fma` の STAGE3=0 で使う。STAGE3=1 は rm を 2 つのサイクルで読む (`fp_fma.veryl:211, 321`) ので、tag の shift register だけでは毎サイクル投入できない。

#### §X.8.3 fu_sys と oldest token

- select の条件で oldest token を要求する (§X.3)。SYS を持つポートは 1 つだけで、oldest の op は 1 つなので、fu_sys の中にいる op は高々 1 つである。
- 受理のサイクルに csr の読出ポート (`i_rd_addr`/`o_rd_data`、読む者は fu_sys だけ) から live な値を読み、`csr_op` (RW/RS/RC、即値版) で新しい値を計算する。`o_wb.data` は旧値である。live に読んで正しいのは、op が最古であり、CSR への書き込みはすべて retire を伴うからである (§5.6 F6)。
- `o_sys` (型は §C.2.5 の `SysPending`: CSR の番地と新値、SFENCE.VMA/SINVAL.VMA/HFENCE の `XlateFlush {kind, va, asid, all_va, all_asid}`) を `o_wb` と同じサイクルに `commit` の `sys_pending` へ渡す。`all_va`/`all_asid` (rs1/rs2 が x0) は decode が `uop` に入れておく。CSR ファイルへの書き込みと TLB の flush は retire 時に commit が行う (§5.5、§5.10)。これは `fu_sys` と `commit` の間の専用の型付きチャネルで、WB packet の sideband ではない。
- 受理したサイクルに `o_started` パルスを出す。commit はこれで `head_started_q` を立てる (§5.13.1 の SYS 行。開始後に繰り返す手順は無いので、`fu_sys` 自身は latch を持たない)。受理できるのは token を持つ op だけなので、パルスはタグを運ばない (§5.2 の例外)。
- AMO/LR/SC は `fu=ATOMIC` で memory 側の `atomic_unit` が実行する (D5)。旧 `alu_wrap.veryl:283-372` の AMO 演算 (Zabha、Zacas を含む) は `atomic_unit` に移植する (§L)。fu_sys は atomics を扱わない。

#### §X.8.4 load の整形

旧 `lsu.veryl:44-95` の整形 (128 bit の窓のシフト、forward されたバイトの重ね合わせ、符号/ゼロ拡張、FLH/FLW の NaN-boxing) を関数として移植し、mem_pipe の最終段で使う (§L)。CdbBus との互換のためだけにあったフィールド (`lsu.veryl:28-31, 103-109` の pc と rs2) は捨てる。結果は wbm の WbPacket の data に入り、宛先クラスは op の `pdst.cls` で決まる。

### §X.9 kill と checker

本章の構造の kill への応答は §5.4 の消費者表が正本である (iq のエントリ、`stage_reg` と wake 遅延線、`fu_blocking_shell`、非消費者の `wb_resv`)。iq はエントリを FREE にするとき port も触らない。§5.4 の表に無い本章の規則は次の 2 つ:

| 構造 | kill への応答 |
|---|---|
| WB packet、`o_sys` | フィルタしない。状態を持つ受け手 (`rob`、`flush_ctrl`、`o_sys` を捕捉する `commit` の `sys_pending`) が `killed()` を適用する。PRF と busy_table への書き込みは無害である。その pdst は edge の後でなければ再割り当てされず、割り当て時にクリアされるからである。 |
| `busy_table`、`prf` | 消費者ではない。 |

`chk_sched` (観測専用、§5.15) が数える項目:

- 1 つの WB ポートで、同じサイクルに 2 つの FU 出力が有効 (二重 writeback)。PRF の同じエントリへの同時書き込み。
- wake lane の event に対して、WAKE_LEAD 後に同じポートで同じ pdst の WB が無い (kill されたものを除く)。
- FU 受理時に、使う source が `prf_done` でも WB バス上でもない (早すぎる wakeup)。
- INT の pdst 0 への WB。busy_table の同一 pdst のクリアとセットの同時発生、空きの pdst への wake。
- `iq_release` の対象が ISSUED でない。nonspec の op が token 無しで select された。blocking FU が `o_ready=0` のときに `i_valid` を受けた。

### §X.10 ポートのタイミング契約 (モジュールヘッダの要約)

| モジュール | 主な入力 | 主な出力 | 契約 |
|---|---|---|---|
| `iq` | `i_alloc[RENAME_W]` (rn_ の edge)、`i_wake[ISSUE_W+MEM_W]`、`i_release[N_PORT]`、`i_tok`、`i_kill`、wb_resv の `wb_ok`、`fu_avail`、(memory 側) `i_load_fence` と `i_port_hold[p]` (登録済み、§L.10、MP3) | `o_grant[N_PORT]` (S の組合せ)、`o_free` (登録済み) | select は登録済み状態と前向きの組合せ入力だけを使う。wake はその edge で rdy に入る。 |
| `busy_table` | クリア、ready のセット (M5 から done のセット) | `prf_ready` の読み出し (組合せ)。M5 から `prf_done` の読み出し | edge で更新し、クリアが勝つ。 |
| `wb_resv` | select の予約 (組合せ)、`hf_req` | `wb_ok[o]`、`hf_grant {valid, off}` (同じサイクル) | 経路は `resv_q` → grant → select → `resv_d` の一方向だけ。 |
| `prf` | 読出アドレス (登録済み)、WB ポート | 読み出しデータ (組合せ) | edge で書く。forwarding は無い。 |
| `exec_port` | grant | `o_wb` (A+L に登録済み)、`o_wake` (W - WAKE_LEAD、高々 1/cycle)、`o_release` (A)、`fu_avail` | §X.7 |
| `fu_*` | §5.6 | §5.6 | LATENCY は `fu_pkg` の値と elaborate 時に照合する (§5.6 F8)。 |
| `fu_blocking_shell` | 受理、leaf の出力、`i_wb_grant {valid, off}`、`i_kill` | `o_ready` (登録済み)、`hf_req`、`o_wb` (grant の off 後) | 完了は latch したタグに帰属させる。 |

### §X.11 CP の事実 (構造の指針としてのみ、§2.6)

- `fp_adder` を pipeline しないと 13.450 ns / 154 段で、旧コアの床だった (align 4.71、normalize 3.31、exp 2.54、round 2.48)。PIPE=1 は 4.71 / 8.74 に分ける。FP の FU が LATENCY 2 なのはこの既存の切れ目を使うためである。さらに深くするには leaf に新しい切れ目 (normalize | round) が要る。そうしたら `LAT_FMA` を 1 増やし、`stage_reg` を挟む局所変更になる。
- 旧コアの FP の発行経路は、select 2.82 + prf_fp 読み出し 1.20 + FPU operand 段 3.93 + adder が 1 サイクルに入っていた。新コアは select と RR の間に必ず `stage_reg` を置く (§X.1)。
- 旧コアの CP (15.160 ns) を決めていたのは commit + TLB + PMP + poison の scan で、実行部ではなかった。
- 実行段を 1 サイクル深くした EX_PIPE は、CP に中立のまま coremark を 12.06 % 悪化させた (そのうち WB 調停は 1.02 pt で、残りはレイテンシそのもの)。ALU を LATENCY 1 とし、WB バスからの bypass と LATENCY から導く wakeup で back-to-back を保つのはこのためである。
- synth は compare-select の鎖を再構成せず、64K cell を超えるモジュールでは再構成そのものを止める。IQ の select は段ごとの木にし、`iq`、`exec_port`、各 FU を別モジュールに保つ。`alu.veryl:94-131` の cpop/clz/ctz の直列ループは置き換える (§X.8)。
- kill の比較は旧コアの CP の壁にならなかった (§5.4 の【決定】)。

### §X.12 M1b と M3 で出荷するもの

| 項目 | M1b | M3 以降 |
|---|---|---|
| 発行パイプライン | select \| RR+受理 (RR_DIST=0)、bypass 1 段 | RR 段は CP 分解で名指しされたときだけ |
| wakeup | LATENCY から導く正確な wakeup のみ。load は §L が出す wake (投機なし) | 投機 load-hit wakeup (§5.7 の【M3 で決定】)。`i_cancel` を追加する |
| トポロジ | cfg_w2 の表 (§5.7 で決定済み)。cfg_w4 は表の案で elaborate し、rv64ui のサブセット | cfg_w4 の FU 集合、BRU ポート数、IQ 分割、PRF 読出本数 (【M3 で決定】) |
| IQ | 表の初期値、最小占有のポート割り当て、ROB タグの木 | エントリ数と割り当て方針を sweep で決める |
| FU | 表の LATENCY。FMA は STAGE3=0。fround は FDIV の shell | `LAT_MUL`、STAGE3 (§5.6) を sweep と CP 分解で決める |
| FU の範囲 | `fu_alu`、`fu_bru`、`fu_sys` (rv64ui のゲートが確かめるもの)。`fu_mul`、`fu_div` (`fu_blocking_shell`) は入れてもよい。FP の FU (`fu_fma`、`fu_fmisc`、`fu_fdiv`) は M2 で入れ、正しさを arch suite と ACT4 で確定させる。トポロジ表は最初から最終形の FU 集合を持つ (構成制約の検査に要るため、§X.2)。M1b で instantiate しない FU は表の上で予約された枠として残し、FU 集合からは外さない | |
| PC | BRU ポートが ftq の読出ポートで読む (§F.3)。IQ と ROB は持たない | |

---

## §C ROB・commit・トラップ・CSR

本章は `rob`, `commit`, `trap_unit`, `flush_ctrl` の 4 モジュールと、再利用する `csr` の接続を定める。§5.4 (kill), §5.5 (OpClass), §5.8 (例外), §5.12 (commit group と retire record), §5.13 (割込み) を前提とし、ここではモジュールの中身と、契約が決めていない部分だけを書く。旧コアの行番号は `b0f4668` のもので、無印の `:N` は `src/core/heliodor_core.veryl` を指す。

### C.0 マイルストーンごとの範囲

| 項目 | M1b | M2 | M3 | M5 |
|---|---|---|---|---|
| `rob` | 全構造 (完了ポート、`exc_q`、resolve/recovered、snapshot、walk、head 出力) | | `ROB_N` の sweep | VU の owner 幅の切り離し (§3.4) |
| `commit` | group 関数の全 outcome、副作用、`sys_pending`、`order_q`、retire record、`head_started_q` (SYS の分) | 割込み経路 (`irq_q`、`irq_take`、token の抑止) とその発火 (rv64mi/si, boot)、debug 入力による lockstep、fflags と FS dirty、HPM | `COMMIT_W=4` のゲート | vset/vstart/vxsat、VS dirty、VU の started latch (`exec_q`) |
| `trap_unit` | rv64ui の環境が使う同期例外 (ECALL、不正命令、アクセス fault)、`medeleg`、tvec、xRET | S-mode の残りの同期例外、割込みの cause と委譲、Sstc、LCOFI | trap 段の要否 | VS への委譲、htval/mtval2、GVA、tinst、cause 22 |
| `flush_ctrl` | partial kill (`BRU_N` 本の resolve から最古を選ぶ木。cfg_w2 で 1、cfg_w4 で 2) と full kill | | checkpoint、T9、kill の段数、cfg_w4 の BRU ポート数の確定 | |
| `csr` の接続 | `i_instret_cnt`、rv64ui の環境が使う CSR の読み書きと trap/xRET の入力 | 割込み関係の出力、`i_fs_dirty`、追加出力、`v14_csr` 凍結後の仕様修正 | | `i_vs_dirty`、H 関連の修正 |
| decode 時の特権検査 (規則は C.8、評価は §R) | CSR の存在・特権・RO、xRET の特権、未定義 SYSTEM | counteren、FS=Off、TVM/TSR、WFI、CBO、Sstc | | VS=Off、HLV/HSV、HFENCE、VTVM/VTSR/VTW、VS 階層の CSR |

REPLAY outcome は M1b から group 関数に入るが、発火するのは §L が順序違反の検出を入れてからである。割込み経路は M2 で実装する (rv64ui のゲートは割込みを使わない)。

---

### C.1 `rob`

#### C.1.1 ペイロードの分割

【決定】ROB エントリに置くのは、commit の判断と回復に必要で dispatch 時に決まる小さなフィールドと、完了ポートが書く数ビットだけとする。実行結果の大きなデータは所有キューが持ち、commit は所有キューの commit 窓から tag の一致で読む。理由: ROB の書込ポート数は完了ポート数 (ISSUE_W+MEM_W) に等しく、ポート数 × 幅が sim 速度と面積の両方を支配するため。

| データ | 置き場所 | 書き手 (時点) | 読み手 |
|---|---|---|---|
| `done` | エントリ | dispatch (`fu==NONE` なら 1)、完了ポート | commit |
| commit 用 class: `fu`, `drain`, `flush`, `alone`, `csr_wr`, `effect`, `is_rvc` | エントリ | dispatch | commit |
| rename 情報: `has_rd`, `cls`, `rd_arch`, `pdst`, `old_pdst` | エントリ | dispatch | commit (arch RAT, free list)、walk |
| `OpTag` の `lq`, `sq`, `ftq`, `foff` | エントリ | dispatch | commit (窓の選択、FTQ への報告) |
| `fflags` | エントリ | 完了ポート | commit (lane 間 OR) |
| `insn` (展開後 32 bit) | エントリ | dispatch | retire record のみ |
| 最古の例外 (`ExcRec`) | 単一レジスタ `exc_q` | dispatch、例外を運ぶ完了ポート | commit, `trap_unit` |
| resolve record `{mispred, taken, next_pc}` | 副配列 `res[ROB_N]` | BRU を持つ WB ポート | commit |
| `recovered` | 副配列 | `flush_ctrl` (set)、dispatch (clear) | commit |
| dispatch snapshot `{lq_tail, sq_tail, fl_int, fl_fp, bar_seq}` | 副配列 `snap[ROB_N]` | dispatch | `flush_ctrl` (読出し 1 本) |
| `rd_wdata` | 観測用副配列 `obs[ROB_N]` | 完了ポート | retire record のみ |
| load の VA/PA/size/data、poison、`PmaAttr` | `lq` | `mem_pipe`, `lq` | commit (LQ 窓) |
| store の VA/PA/mask/data、`PmaAttr` | `sq` | `mem_pipe`, `sq` | commit (SQ 窓)、`sq` から `sb` への push |
| CSR の新値と番地、SFENCE のオペランド | commit の `sys_pending` | `fu_sys` | commit |
| PC | どこにも置かない (C.2.3) | | |

- 窓の規則 (所有者は各キュー。§L はこの規則に従う): `lq` は最古から `COMMIT_W` 個、`sq` は最古から `MEM_W` 個 (SB push 予算, §3.2) のエントリを登録済みの窓として出す。commit の lane は自分が運ぶタグと窓エントリのタグの等値比較で 1 つを選ぶ (one-hot の AND-OR)。`idx - head` は計算しない (§5.2)。一致がちょうど 1 つであることは checker が検査する。
- `insn` と `obs` は retire record 専用で、設計論理には戻さない。decode 不正の tval は `ExcRec.tval` が運ぶので `insn` を使わない。synth からの除外は checker と同じ方法 (§5.15 の【M1a で決定】) による。
- 旧コアの RobEntry は 50 を超えるフィールドに予測器・store queue・CSR・vector・amocas の payload を混ぜていた (`pipeline_pkg.veryl:254-345`)。これを上の表に分解する。

#### C.1.2 例外の保持 `exc_q`

【決定】ROB エントリは例外ビットも `ExcRec` も持たない。`rob` は最古の例外 1 件だけを `exc_q {valid, tag: RobTag, rec: ExcRec}` に保持し、lane l の op が例外を持つことを `exc_q.valid && exc_q.tag == tag[l]` で判定する。理由: trap は lane 0 の最古の例外でしか起きない (§5.8)。それより若い例外はその trap の full kill で消え、より古い例外が後から報告されれば置き換わる。tval と gpa (118 bit) をエントリごとに持たずに済む。

- 入力: dispatch の lane (例外付きの `NONE` op) と、例外を運びうる WB ポート。後者は能力表で宣言し、M1-M4 では memory pipe の WB ポートだけである (`io_unit`, `atomic_unit` は wbm0 を通る)。
- 更新: `killed(i_kill, tag)` が真の報告と保持値を落とした後、`exc_q` と全報告の中の最古を `tag_pkg::older` の木で選ぶ。
- 不変条件 (所有者 `rob`): head が valid で、head の op が例外を報告済みなら `exc_q.tag == head.tag` である。
- `exc_q` はタグ型のレジスタなので kill の消費者である (§5.4 の表に記載済み)。

#### C.1.3 完了ポート

- 【決定】`rob` の完了入力はちょうど 2 種類だけで、どちらも `rob` のヘッダに宣言する: WB ポートと 1 対 1 の `WbPacket` ポート (`i_wb[ISSUE_W+MEM_W]`) と、M5 で加える VU の完了入力 `i_vu_done: VuDone` (§V.3 VA4、調停なしの予約済み入力。VEC op は alone で同時に高々 1 つ)。理由: 完了の経路を数えられる形にし、「sideband で `done` を立てる」経路を構造的に無くす。
- 完了ポートは WB ポートと 1 対 1 に対応する。各ポートは `WbPacket` を受け、`tag.rob.idx` のエントリに `done`, `fflags`, `obs` を書き、`exc.valid` なら `exc_q` の木に入れ、BRU を持つポートなら `res` を書く。
- 完了ポートはフィルタではない (T7)。エントリの valid は確認するが世代は照合しない。kill 済みの op の packet を出さないのは送り手の責任である。
- この 2 種類以外の完了経路は作らない。§L が WB を伴わない完了 (store のアドレスとデータの合流など) を必要とするなら、`WbPacket` 形式の完了ポートとして `rob` のポート一覧に追加する。sideband で `done` を立てる経路は禁止する。IO store のように ROB の done の後にも retire の条件がある op は、その条件を所有キューの commit 窓で出す (`sq.retire_ok`、§C.2.2)。
- dispatch 時完了 (§5.5 の `fu == NONE`) は割り当てと同じ書込みで `done=1` とし、例外があれば `exc_q` の木に入れる。
- タイミング: サイクル t に WB した op は、t+1 から commit 窓で done に見える。

#### C.1.4 resolve record と `recovered`

- `res[e]` は control op の WB で書く。`mispred` は BRU が「予測した次 PC と解決した次 PC の不一致」として計算する (§X)。not-taken でも `next_pc = pc + len` を書く。
- `recovered[e]` は、`flush_ctrl` が partial kill を採用したサイクルの終わりの edge で keep の index に立つ。これは BRU の `res` 書込みと同じ edge である (C.4 で採用判定を WB サイクル内に置く)。【決定】理由: `recovered` が `res` より遅れて見えると、commit が `mispred && !recovered` を見て冗長な full kill を出す。
- dispatch は割り当て時に `recovered=0` とする。予測値は上書きしない (T8)。

#### C.1.5 walk の順序づけ

【決定】walk の順序づけは `rob` が行う。partial kill (`ckpt_v=0`) を受けた `rob` は tail を `next(keep)` にした上で、旧 tail から keep の直後までのエントリを若い順に `WALK_W` 個ずつ `o_walk[WALK_W] {valid, cls, rd_arch, old_pdst}` に登録済みで出し、終わるまで `o_walk_busy` を立てる。`has_rd=0` のエントリは `valid=0` の lane として流す。理由: ROB の index を rename に見せずに済み (P2)、rename は受け取った lane を若い順に RAT へ適用するだけになる。

- walk 中は dispatch が止まっているので、旧 tail 側のエントリは上書きされない。
- full kill は walk を打ち切る (rename は arch RAT をコピーする)。partial kill は walk 中には来ない (C.4)。`ckpt_v=1` の partial kill (M3) では walk せず、tail の巻き戻しだけを行う。
- 【M3 で決定】`has_rd=0` のエントリを詰めて流すか: walk サイクル数の分布と mispredict 1 回あたりの回復コストを測り、詰める木の面積と比べて決める。

#### C.1.6 dispatch snapshot と割り当て

- `snap[e]` は、エントリ e の op を割り当てた直後の `{lq_tail, sq_tail, fl_int, fl_fp, bar_seq}` である。dispatch が lane ごとに「その lane までを割り当てた値」を書く。読出しは 1 本で、`flush_ctrl` が resolve のサイクルに、分岐自身が運ぶ `RobTag` で読む (T6)。full kill は snapshot を使わない。
- `rob` は次に割り当てる `RENAME_W` 個のタグ `o_alloc_tag[RENAME_W]` と空き数 `o_free` を登録済みで出す。dispatch はそのうち `take` 個を使う (§5.3 R4)。
- head は commit の `i_retire_cnt` だけ進む。`o_head {valid, tag}` は登録済みで、commit が gate して oldest token にする (C.2.6)。

```
// rob: reorder buffer storage, completion, oldest-exception record, walk sequencing
// Ports (timing contract):
//   i_alloc_valid[RENAME_W]/i_alloc : dispatch group, lanes contiguous from lane 0
//   o_alloc_tag[RENAME_W], o_free   : registered state only
//   i_wb[ISSUE_W+MEM_W]             : WbPacket; done visible to commit next cycle
//   i_vu_done                       : VuDone (M5); the only completion input besides i_wb
//   o_cm[COMMIT_W], o_exc, o_head   : read from registered state with the registered head
//   i_retire_cnt                    : from commit; head advances on the edge
//   i_kill                          : tail := next(keep) or empty; filters exc_q; a partial kill without ckpt starts the walk
//   i_rec_set {valid, tag}          : from flush_ctrl, on the edge that registers the partial Kill
//   i_snap_tag -> o_snap            : combinational read for flush_ctrl
//   o_walk[WALK_W], o_walk_busy     : registered, youngest first
```

---

### C.2 `commit`

#### C.2.1 lane の入力

lane l は次を見る。すべて登録済み状態であり、commit の判断は「登録済み状態 + 登録済みの `Kill` + debug 入力」の組合せ関数である。

- `rob.o_cm[l]` (done, class, rename 情報, OpTag, fflags)、`exc[l] = exc_q.valid && exc_q.tag == tag[l]`、`res[l]`, `recovered[l]`。
- load なら LQ 窓の一致エントリ (poison, `PmaAttr`, mem フィールド)、store なら SQ 窓の一致エントリ。atomic は `atomic_unit` の単一エントリ (atomic は alone で lane 0 にしか来ない)。
- `sb.ordering_empty`, `sb` の空き credit (いずれも §L の登録済み出力)。

#### C.2.2 group 関数

lane ごとの outcome (上から最初に当たったもの):

| 順 | 条件 | outcome |
|---|---|---|
| 1 | `!valid[l] \|\| !done[l]` | WAIT |
| 2 | `exc[l]` | TRAP (`exc_q.rec`) |
| 3 | load で LQ 窓の `poison` | REPLAY (`pc[l]`) |
| 4 | store で SQ 窓の `retire_ok` が偽 (`addr_v && data_v && (kind != IO \|\| wt_done)`、§L.4。IO store は `io_unit` の WT_DONE で `wt_done` が立つまで待つ) | WAIT |
| 5 | `drain[l]` かつ `!sb.ordering_empty` (C6。`ordering_empty` は `atomic_unit` の queue を含む、MP7) | WAIT |
| 6 | `flush[l] == XRET` | RETIRE_FLUSH (XRET, csr の epc) |
| 7 | `flush[l] == NEXT_PC` | RETIRE_FLUSH (SERIAL, `pc[l] + len[l]`) |
| 8 | control op で `res.mispred && !recovered` | RETIRE_FLUSH (BR_CM, `res.next_pc`) (T8) |
| 9 | それ以外 | RETIRE |

flush の kind (XRET、SERIAL、BR_CM、および TRAP、IRQ、REPLAY) は `RedirKind` (§C.4) の値をそのまま使う。

retire の式 (正本。§5.12 C1 はこの式の要約):

```
alone_eff[l] = alone[l] || ((is_ld[l] || is_st[l]) && win[l].attr.io_ordered)   // late attribute, PM2
ok[l]   = outcome[l] in {RETIRE, RETIRE_FLUSH} && !killed(i_kill, tag[l])
          && n_st[l] <= MEM_W && n_line[l] <= min(PUSH_W, sb_credit) && limit_ok[l]
cut[l]  = l > 0 && (alone_eff[l] || exc[l] || poison[l])     // these act only as the group head
end[j]  = outcome[j] == RETIRE_FLUSH || alone_eff[j]          // nothing younger joins the group
retire[l] = !irq_take && ok[l] && !cut[l] && AND over j<l of (retire[j] && !end[j])
limit_ok[l] = !i_dbg_retire_limit_en || order_q + l < i_dbg_retire_limit
```

- IO/NC の遅延属性 (§5.5) のうち、commit が合成するのは `alone_eff` だけである。nonspec と drain は `io_unit` が発行の条件 (oldest token、`ordering_empty`) として満たし (§5.14)、IO store の書き込みの完了は 4 行目の `retire_ok` が待つ。
- `n_st[l]` は lane 0..l の store 数で、IO store も数える (alone なので実害は無い)。`n_line[l]` は lane 0..l の store が `sb` に push する line 数で、line を跨ぐ store は 2、cbo.clean/flush/inval と IO store は 0 と数える (§3.2 の `PUSH_W`)。前置和と前置 AND は `tree_pkg` の prefix helper で書く (§5.15)。
- `!killed(i_kill, tag[l])` の項が要る理由: BRU の WB がサイクル t-1、partial kill の採用もサイクル t-1 なら、サイクル t には `recovered=1` の分岐 (RETIRE) と、その後ろの wrong-path の完了済み op が同時に窓に見える。tail が巻き戻るのは t の edge なので、この項が無いと wrong-path の op が retire する。full kill のサイクルはこの項で全 lane が止まり、T4 が成り立つ。
- TRAP と REPLAY は group の先頭 (窓の最古、すなわち lane 0) でだけ作用する。`trap_fire = !irq_take && outcome[0]==TRAP && !killed(i_kill, tag[0]) && limit_ok[0]`。REPLAY も同形で、TRAP が優先する。lane l>0 の TRAP/REPLAY は `cut` で group を切るだけである。
- flush は 1 サイクルに 1 つ: 優先順位は `irq_take` > `trap_fire` > `replay_fire` > 「retire した最年少 lane の RETIRE_FLUSH」。`end` により RETIRE_FLUSH の lane は group の最年少なので、retire した lane の中に RETIRE_FLUSH は高々 1 つである。
- `i_retire_cnt = popcount(retire)` (前置なので先頭からの個数と等しい)。

#### C.2.3 PC の導出と `arch_next_pc_q`

- 不変条件 (所有者 `commit`): ROB の head が valid のとき、head の op の PC は `arch_next_pc_q` に等しい。根拠: `arch_next_pc_q` は最後に retire した op のアーキ上の次 PC か、最後の flush の飛び先である。これと異なる PC の op が head に来るのは、retire 済みの control op が外れていて回復されていない場合だけであり、その場合は RETIRE_FLUSH (BR_CM) が younger を消している。予測した taken が非 control op に付いた場合は、§F の extract が rename より前に正す。
- lane の PC: `pc[0] = arch_next_pc_q`、`next_pc[l] = is_ctrl[l] ? res[l].next_pc : pc[l] + (is_rvc[l] ? 2 : 4)`、`pc[l] = next_pc[l-1]`。段ごとの配列を持つ generate で書く。
- 更新: flush があれば飛び先 (trap vector、xRET の epc、SERIAL の `pc+len`、BR_CM の `res.next_pc`)、REPLAY なら不変、retire があれば最年少 retire lane の `next_pc`。reset 値は `i_reset_pc`。
- 結果として、同期例外・割込みとも epc は `arch_next_pc_q` である (§5.8 と同値)。
- 【決定】commit は PC を ROB からも FTQ からも読まない。理由: 上の不変条件だけで足り、FTQ に `COMMIT_W` 本の読出しポートを足すことも、ROB に `ROB_N`×64 bit を置くことも要らない。front end が送った命令列と commit の PC 計算は、retire record の (pc, insn) の対が golden と一致することで相互に検査される。

#### C.2.4 retire の副作用

すべて `retire[l]` (と lane 0 の `trap_fire`/`irq_take`) だけを条件とする (C3)。

| 副作用 | 条件 | 宛先 | 本数 |
|---|---|---|---|
| arch RAT の更新 | `has_rd` | rename (`o_rat_cm[COMMIT_W]`)。同じ `rd_arch` は若い lane が勝つ | COMMIT_W |
| 旧 pdst の解放 | `has_rd` | `free_list` (`o_fl_rel[COMMIT_W]`) | COMMIT_W |
| LQ/SQ の head 前進 | load/store の個数 | `lq`, `sq` (`o_lq_ret_cnt`, `o_sq_ret_cnt`)。`sq` は retire した store を `sb` へ push する (IO store は push しない) | 1 |
| CSR 書込み | lane 0 が SYS で `csr_wr` | `csr.i_wr_*` (`sys_pending` から) | 1 |
| xRET | `flush == XRET` | `csr.i_mret_fire` / `i_sret_fire` | 1 |
| fflags | `effect.FFLAGS` の lane の OR | `csr.i_fflags_set`, `i_fflags` | 1 |
| FS/VS の dirty 化 | `effect.FS_DIRTY` / `VS_DIRTY` の OR | `csr.i_fs_dirty` / `i_vs_dirty` (新設) | 1 |
| 翻訳の無効化 | SFENCE.VMA, SINVAL.VMA, HFENCE.*, HINVAL.* | I/D の `tlb` と `ptw` (`o_xlate_flush`) | 1 |
| icache の無効化 | FENCE.I | `icache` (`o_icache_inv`) | 1 |
| atomic の retire | `fu == ATOMIC` | `atomic_unit` (reservation と watch) | 1 |
| reservation の解除事象 | trap の受付、xRET、satp への書込み | `atomic_unit` (`o_rsv_clr`) | 1 |
| FTQ と予測器 | lane ごとの `{ftq, foff, is_ctrl, res}` | `ftq`/`bpu` (解放と更新の規則は §F) | COMMIT_W |
| instret | `popcount(retire)` | `csr.i_instret_cnt` | `RETIRE_CNT_W` |

- 【決定】「trap した op はアーキ状態に書かない」(§5.8) を lane ごとの 1 本の `retire[l]` に集約し、副作用の側では例外を個別に判定しない。理由: 旧コアは消費者ごとに gate を書き、valid と ack が混在した (`commit_mret`, fflags, vset, vstart, minstret, arch_regs が valid 側, `:7146-7147, :7370-7426, :7808`)。その結果、priv-illegal の rd や trap する AMO/amocas.q の rd が漏れうる (推定。`:6427`, `:6958`、検証計画付録 B の B09 と B36)。
- reservation の解除事象は旧コアの集合 (`:8288-8312`) を受け継ぐが、satp は書込みに限る (旧コアは読み出しでも解除した)。kill では解除しない (§5.4 の非消費者)。他 hart の inv、line の追い出し、SC による解除は §L が持つ。

#### C.2.5 `sys_pending`

```veryl
struct XlateFlush { valid: logic, kind: XfKind, va: logic<64>, asid: logic<16>, all_va: logic, all_asid: logic } // kind: SFENCE, HFENCE_VVMA, HFENCE_GVMA
struct SysPending { valid: logic, tag: RobTag, csr_addr: logic<12>, csr_wdata: logic<64>, xf: XlateFlush }
```

- `fu_sys` は oldest token を持つ op を実行したサイクルに、専用ポートで `sys_pending` を書く (F6)。rd (CSR の旧値) は通常の WB packet で返す。`fu_sys` は例外を出さない (CSR の合法性はすべて decode, C.8)。
- 1 本で足りる理由: SYS は nonspec かつ alone なので、生きている SYS の実行結果は高々 1 つである。
- 不変条件 (所有者 `commit`): `retire[0] && fu[0]==SYS` ならば `sys_pending.valid && sys_pending.tag == tag[0]` (checker で検査)。retire で消費し、`killed(i_kill, tag)` でも落とす (§5.4 の表に記載済み)。
- 旧コアは SFENCE と amocas.q のオペランドを `arch_regs` から読んでいた (`:7850-7851, :8766-8769`)。`arch_regs` は持たない (§5.5)。

#### C.2.6 割込みの受付、oldest token、`head_started_q`

- `irq_q <= {csr.o_irq_pending, o_irq_cause, o_irq_to_s, o_irq_to_vs}` (I1)。
- `irq_ok = !i_dbg_irq_mask || (i_dbg_irq_allow && i_dbg_retire_limit_en && order_q == i_dbg_retire_limit)`。
- `irq_take = irq_q.pending && irq_ok && !head_started_q && !i_kill.valid` (I2)。ROB が空でも受け付ける (epc は `arch_next_pc_q`)。`!i_kill.valid` の 1 項が I2 の 2 つの条件 (kill のサイクルと、アーキ状態を変える retire の次のサイクル) を両方担う理由は §5.13 I2 にある。
- `o_oldest = {valid: rob.o_head.valid && !(irq_q.pending && irq_ok) && !(i_dbg_retire_limit_en && order_q >= i_dbg_retire_limit) && !i_kill.valid, tag: rob.o_head.tag}` (I5)。登録済み状態だけから作る。`rob.o_head` は retire の edge で進む登録済みの値なので、token の付与は retire の次のサイクルになる (§5.12)。
- `head_started_q` (§5.13.1 IR2): 各 unit が開始点の受理 edge で出すパルス `i_started[*]` の OR で立ち、lane 0 の retire、trap、full kill で落ちる。発生源は §5.13.1 の表どおり: `fu_sys`、`io_unit`、`atomic_unit`、`sq` (D ビットの `nonspec` walk)、(M5) `vu_adapter`。パルスはタグを運ばない (§5.2 の例外)。
- 受付のサイクル: lane は 1 つも retire しない。commit は flush 要求 (kind=IRQ) を出し、`trap_unit` が cause、委譲、vector を計算して `csr.i_trap_fire` を駆動する。`o_irq_evt = {cause, epc: arch_next_pc_q, order: order_q}`。
- debug 入力 (§5.13) を使うのは `limit_ok`, `o_oldest`, `irq_ok` の 3 か所だけである。

#### C.2.7 `order_q` と retire record

- `order_q` (64 bit) は毎サイクル、record の個数 (`retire[l]` の lane 数 + `trap_fire`) だけ進む。
- record の各フィールドの出所 (§5.12 の表に対応):

| フィールド | 出所 |
|---|---|
| `pc`, `next_pc` | C.2.3 (trap record の `next_pc` は 0) |
| `insn`, `is_rvc` | ROB エントリ |
| `trap`, `cause`, `tval` | `exc_q.rec` と `trap_unit` が選んだ tval (C.3) |
| `priv`, `virt` | retire サイクルの csr の現在値 |
| `rd_kind`, `rd_addr`, `rd_wdata` | `has_rd`, `cls`, `rd_arch`, `obs` |
| `rd2_*` | amocas.q の形 (§5.5 の【M2 で決定】) に従う |
| `mem_*` | LQ/SQ 窓、atomic は `atomic_unit`。load の `mem_rdata` は `obs` (rd に書いた値) から作る。LQ はデータを持たないので、rd=x0 の load の `mem_rdata` は再構成できず、MASK とする (検証計画の正規化規則) |
| `csr_*` | `sys_pending` (`csr_wr` のとき) |
| `fflags` | ROB エントリ |
| `vec_v`, `vrf_wcnt`, `vrf_hash`, `vtype`, `vl`, `vstart` | M5 まで 0。M5 では VU の retire 情報 (§V) |

- 【決定】`o_retire[COMMIT_W]` と `o_irq_evt` は retire の次のサイクルに登録済みで出す。理由: 観測ポートの組み立てが commit の判断経路を延ばさないようにする。

---

### C.3 `trap_unit`

commit サイクルに評価する組合せモジュールで、入力はすべて登録済みである (`exc_q.rec`, `irq_q`, csr の状態, `arch_next_pc_q`)。出力は csr の `i_trap_*` と、commit への飛び先。

| 項目 | 規則 | 旧コア |
|---|---|---|
| cause | 同期は `exc_q.rec.cause` をそのまま使う。優先順位は発生源が `exc_pkg::exc_prio` で解決済み (§5.8)。割込みは `irq_q.cause`。head の例外と割込みが同時なら割込みを取る (C.2.6)。 | 優先順位のエンコーダが core にあり、FS-off を load/store fault より下に置いていた (`:7213-7230`) |
| 同期の委譲 | `to_s = priv != M && medeleg[cause]`、`to_vs = to_s && virt && hedeleg[cause]` (to_vs は M5) | `o_priv_prev`/`o_virt_prev` を使用 (`:7255-7265`) |
| 割込みの委譲 | `irq_q.to_s`, `irq_q.to_vs` (csr が計算済み) | 同じ |
| tval | `exc_q.rec.tval`。ただし cause 3 (breakpoint) は epc。割込みは 0。 | EBREAK は 0、不正 RVC は展開形 (`:7338-7346`) |
| htval/mtval2 | HS/M に入る trap で、cause ∈ {20, 21, 23} なら `gpa >> 2`、それ以外は 0 (M5) | GPF 以外では古い値が残る |
| GVA | `exc_q.rec.gva` (HS/M に入る trap)。M5。 | ROB 経由の store/AMO GPF で live な MMU 値を読む (`:7281`) |
| tinst/htinst | 0 | 同じ |
| trap vector | `tvec = to_vs ? vstvec : to_s ? stvec : mtvec`、`base = {tvec[63:2], 2'b00}`、`target = base + (tvec[0] && is_irq ? 4 * code : 0)` | 同じ (`:7480-7491`) |
| xRET の飛び先 | MRET は `mepc`、SRET は `virt ? vsepc : sepc`。retire サイクルの csr 出力を読む (更新は次の edge)。 | 同じ (`:7714-7725`) |

- 【決定】priv と V は csr の現在値を使い、旧コアの `o_priv_prev`/`o_virt_prev` は使わない。理由: priv と V が変わるのは trap と xRET の retire だけで、どちらも full kill を伴う。したがって retire サイクルの現在値は、その op を実行したときのモードと常に等しい。
- 【決定】breakpoint の tval は `trap_unit` が epc で埋める。理由: ACT4 の構成 (`test/act/config/heliodor/heliodor.yaml:171`, REPORT_VA_IN_MTVAL_ON_BREAKPOINT) と一致させる。Sdtrig を持たないので cause 3 の発生源は EBREAK だけであり、decode に PC を配る必要もない。
- decode 不正の tval は元の符号化 (RVC なら 16 bit) を発生源が `ExcRec.tval` に載せる (ACT4 構成の REPORT_ENCODING_IN_MTVAL_ON_ILLEGAL_INSTRUCTION)。cause 22 も同じ規則とする (M5)。
- 特権検査はしない。合法性はすべて decode で済んでいる (C.8)。
- 【M5 で決定】VS-stage の暗黙アクセスによる guest-page fault で、spec が tinst に擬似命令値を要求するかを照合する。要るなら `ExcRec` に `implicit` bit を足す (§5.8 で予告済み)。
- 【M3 で決定】trap 段を足すか: 深さは「cause から委譲ビットの選択、tvec の加算」で、入力はすべて登録済みである。CP の分解で `trap_unit` が名指しされた場合に限り、出力を登録し、commit は lane 0 の TRAP を 1 サイクル待たせる。commit の outcome に 1 条件を足すだけの局所変更である。

---

### C.4 `flush_ctrl`

入力: BRU を持つ WB ポートの resolve (`BRU_N` 本。FU トポロジ表から導くパラメータで、M1b から任意の本数を受ける。cfg_w2 で 1、cfg_w4 で 2)、commit の flush 要求 `{valid, kind, pc}`、`rob.o_walk_busy`、snapshot の読出し、自分の出力 `Kill` の帰還。

選択 (サイクル t、組合せ):

1. commit の flush 要求があれば full kill を採用し、partial の候補はすべて捨てる (T1)。
2. なければ、`mispred && !killed(kill_q, tag)` の resolve の中から最古を `older` の木で選ぶ (`BRU_N=1` なら木は退化する)。
3. partial を採用するのは `!kill_q.valid && !rob.o_walk_busy` のときだけである。捨てた resolve は T8 が commit で拾う。

登録 (t+1 に有効):

- full: `Kill {valid, full=1}`。`Redirect.pc` は commit の要求 pc。
- partial: `keep` = 分岐のタグ、`lq_tail/sq_tail/fl_int/fl_fp/bar_seq` = `snap[keep]`、`ftq_tail = next(br.ftq)` (`BrResolve` が運ぶ分岐の FTQ タグ。keep は RobTag なので FTQ タグを持たない)、`ckpt` (M3)。`Redirect = {pc: res.next_pc, ftq_keep: br.ftq, foff: br.foff, taken: res.taken, kind: BR}`。
- full で commit の要求が T8 の backstop (BR_CM) のとき: `Redirect = {pc: res.next_pc, ftq_keep: 分岐の ftq, foff, taken, kind: BR_CM}`。それ以外の full では `foff`/`taken` は無効で、`kind` は要求の kind。
- partial を採用したサイクルの edge で `rob` の `recovered[keep]` を立てる (C.1.4)。

`RedirKind` (定義は `core_types`、§5.4。生成するのは `flush_ctrl` だけ): `BR` (BRU の resolve による部分 kill)、`BR_CM` (commit 時の検査 T8 による full kill)、`TRAP`, `IRQ`, `XRET`, `SERIAL`, `REPLAY`。`BR` と `BR_CM` のときだけ `Redirect.foff`/`taken` が有効である。§F はこれを予測器の回復方針と発火カウンタにだけ使い、飛び先の計算には使わない。

不変条件 (所有者 `flush_ctrl`):

- `Kill` と `Redirect` は同じサイクルに有効になる。`Kill` は 1 サイクルに 1 つ (T1)。
- full kill の `Redirect.pc` は commit が決めたアーキ上の次 PC であり、fetch 側のポインタは使わない。
- 連続する partial kill は出さない。kill の直後のサイクルは、rob が walk を始める前でも partial を採用しない。

- 【M3 で決定】kill の配布に段を足すか: cfg_w4 の CP 分解で kill の fan-out が名指しされた場合に限る。制約: `rob.recovered` は Kill を登録するのと同じ edge で書く (C.1.4、C.2.2 の `!killed()` 項の論拠)。段を足すときは `i_rec_set` も同じ段だけ遅らせ、両者が同じサイクルに見えるようにする。Kill だけを遅らせると、`recovered=1` が見えていて Kill がまだ無効なサイクルに wrong-path の op が retire する。したがってこの変更は §2.1 P3 の意味での局所変更ではなく、`flush_ctrl` と `rob` の 2 か所と、遅れた間に T8 が冗長な full kill を出しうる分の発火数の確認を伴う。測るものは、段を足したときの冗長な T8 の発生数と CP の改善量である。
- T9 (walk 中により古い kill を受け入れるか) は §5.4 のとおり M3 で測って決める。

---

### C.5 `csr` の接続

【決定】csr の commit 側は 1 本のインタフェースのまま再利用し、lane 間の集約は commit が行う。理由: csr の累積器は、同じサイクルの CSR 書込みや trap と排他であることを前提にしている (`csr.veryl:1163-1189` のコメント「1-wide commit makes this mutually exclusive」)。alone 規則と、trap が group を空にする規則で、この排他が構造的に成り立つ。

| csr のポート | 駆動元 | 条件・備考 |
|---|---|---|
| `i_rd_addr` / `o_rd_data` | `fu_sys` | 唯一の読み手。token 保持 op の実行時だけ |
| `i_wr_en/addr/data` | commit | `retire[0] && fu==SYS && csr_wr`、値は `sys_pending` |
| `i_trap_fire/pc/cause/tval/to_s/to_vs`, `i_htval`, `i_trap_gva` | `trap_unit` | `trap_fire \|\| irq_take`。M1-M4 は `to_vs`, `htval`, `gva` を 0 に固定 |
| `i_mret_fire`, `i_sret_fire` | commit | lane 0 の XRET の retire |
| `i_instret_cnt` (幅パラメータ `INSTRET_CNT_W` 付き、既定 1。旧コアは既定値のまま) | commit | `popcount(retire)` |
| `i_fflags_set`, `i_fflags` | commit | lane 間 OR |
| `i_fs_dirty` (新)、`i_vs_dirty` (新, M5) | commit | lane 間 OR。V=1 では vsstatus 側も dirty にする (M5) |
| `i_vxsat_set`, `i_vset_wr`…, `i_vstart_wr`… | commit (M5) | 【M5 で決定】VU が head でしか実行しない性質を使い、`sys_pending` と同形の単一レジスタで渡すか |
| `i_hpm_events` | 各所有者の登録済みビットを top で連結 (C.7) | |
| `i_mtime`, `i_irq_*` | core の外部ポート | |
| `o_priv`, `o_virt`, status/envcfg/counteren 系 | decode (C.8)、`tlb`/`ptw` (X1)、`trap_unit` | |
| `o_irq_pending/cause/to_s/to_vs` | commit (`irq_q`) | |
| `o_priv_prev`, `o_virt_prev`, `o_dbg_*` | 新コアは使わない | M6 で旧コアと一緒に消える |

- 不変条件 (所有者 `commit`): 1 サイクルに csr へ入るのは、{trap, xRET, CSR 書込み} のうち高々 1 つで、それがあるサイクルには fflags、dirty、vset、vstart の入力は 0 である。これで csr の NBA 上の上書き順 (累積器が同サイクルの書込みに勝つ、trap が書込みを捨てる) は観測されない。
- minstret の書込み: minstret に書く CSR op は alone なので、そのサイクルの増分は書込みで抑止され、書いた op 自身は数えない (C8, rv64mi `instret_overflow` の期待どおり)。
- csr の変更 (§4.4):
  - 追加のみ (M1-M2): `i_instret_cnt` (幅はパラメータ `INSTRET_CNT_W`、既定 1 で旧コアは従来の 1 bit を与える)、`i_fs_dirty`/`i_vs_dirty` (旧コアは 0)、decode 用の出力 (mcounteren, scounteren, hcounteren, mstatus.TW, hstatus.VTW, menvcfg/senvcfg/henvcfg の CBIE/CBCFE/CBZE と STCE)。
  - 挙動の修正 (C.9 で「csr 修正」とした行): 最初の修正が必要になった時点 (M2 を想定) で `src/v14/v14_csr` を凍結コピーし、旧コアはそちらを使う。

---

### C.6 fence 系と satp

各命令の OpClass (fu、nonspec、drain、flush、alone、`ld_barrier`) の正本は §5.5 の表であり、本表は retire の条件と retire 時の動作を定める。

| 命令 | retire の条件 | retire 時の動作 | 旧コアとの差 |
|---|---|---|---|
| FENCE, FENCE.TSO | C6 | なし (若い load の待ちは §L.10 の `ld_barrier` 規則で解ける) | 同じ |
| PAUSE、rd=x0 の hint | なし | なし | 同じ |
| FENCE.I | `sb.ordering_empty` | `o_icache_inv`、full kill で `pc+4` から refetch (FENCE.I には RVC の形が無い) | dcache の sweep を持たない (D3) |
| SFENCE.VMA, SINVAL.VMA | 同上 + `sys_pending` | `o_xlate_flush {va, asid, all_va: rs1==x0, all_asid: rs2==x0}`、full kill | 旧は refetch せず (`:8451` の commit_redirect に sfence の arm が無い)、オペランドは `arch_regs` |
| SFENCE.W.INVAL, SFENCE.INVAL.IR | `sb.ordering_empty` (C6。SYS op ではないので `sys_pending` は無い) | full kill だけ | 同じ |
| HFENCE.VVMA/GVMA, HINVAL.* (M5) | SFENCE.VMA と同じ (`sb.ordering_empty` + `sys_pending`。SYS op、§5.5) | `o_xlate_flush {kind, ...}`、full kill | 旧は `is_sfence` に相乗り |
| CSR 書込み (satp を含む) | なし | csr 書込み、full kill | 旧は satp/frm/fcsr だけ redirect |

- `o_xlate_flush` は I/D の `tlb` と `ptw` の両方に入る。契約 (所有者 `tlb`/`ptw`, §M): 同じサイクルの install より flush が勝つ。`ptw` は flush を full kill と同じく epoch の更新として扱い、flush より前に始まった walk の結果を install しない。理由: flush パルス (retire サイクル t) と full kill (t+1) の間に完了した walk が、古い翻訳を TLB に入れないようにするため。
- FENCE.I が成り立つ前提 (所有者 §S、§S.6): `sb` から L1D に入った store を、I read slot の fill が観測できること (coherent ifetch)。tohost の検出は retire ポートで行うので、FENCE.I に依存しない (PM5)。
- satp: 【決定】`satp_shadow` も偽の ifault 注入も持たない (X5)。csrw satp は CSR 書込みとして retire し、full kill 後の refetch は新しい satp で翻訳する。Linux head.S の trampoline では、satp 書込みの直後の `pc+4` の fetch が本物の instruction page fault (cause 12, epc = tval = `pc+4`) を起こす。旧コアは同じ trap を偽造し、satp の書込みを捨てていた (`:7050`, `csr.veryl:905` と `:1047`)。差は C.9 の #1 (検証計画付録 B の B02) で吸収する。
- satp の書込みは TLB を flush しない (spec どおり。ASID 付きの TLB が文脈を区別する)。
- vsatp, hgatp, hstatus, PMP, envcfg への書込みも、同じ「CSR 書込みは full kill」の規則に入る。旧コアの翻訳 barrier (`rob.veryl:751-774`) はこれらを覆っていなかった。

---

### C.7 カウンタと HPM 事象

- mcycle は csr 内部のまま。minstret は `i_instret_cnt`。time は `i_mtime` (lockstep 時の tick は §S.5 と検証計画)。
- 【決定】csr の 8 bit HPM バスの符号化は保ち、各ビットの意味を新コアの構造で定義し直す。各ビットは所有モジュールの登録済み出力であり、top は連結するだけである (§2.2 M2)。理由: 旧 synth では `dcache_stall -> rob_commit_ack -> mhpm` が最長経路の終点だった。計数は統計なので 1 サイクルの遅れはどのテストにも影響しない。

| sel | 事象 | 所有者 | 備考 |
|---|---|---|---|
| 1 | retire した control op の `res.mispred` (recovered を含む) | `commit` | |
| 2 | `Redirect` の発行 | `flush_ctrl` | |
| 3 | rename の入口が空 (stall でも redirect でもない) | rename (§R) | |
| 4 | rename/dispatch が資源不足で止まった | dispatch (§R) | |
| 5 | memory port のいずれかが要求を運んだ (MEM_W 本の OR。load, drain, PTW, VU) | `mem_port_arb` (§L) | `test_arch_hpm_counter` と `test_arch_sscofpmf` が 0 より大を要求する |
| 6 | retire した lane が 0 | `commit` | |
| 7 | 発行済みの load が memory を待っている | `lq` (§L) | 旧コアと意味が変わる |
| 8 | 予約 | | 【M3 で決定】ポート飽和の事象を足すか: M3 の sweep で使う場合に限る |

- 旧コアの事象源 (`:13196-13207`) はどれも新コアに存在しない構造である。
- counter CSR の読み値は lockstep で比較しない (検証計画付録 B の B15、MASK:CNT)。

---

### C.8 decode 時の特権・状態検査 (規則表)

§5.5 の決定により、特権と状態に依存する合法性はすべて decode で、commit 済みの CSR 状態に対して評価し、不正な op は `NONE` に例外を付けた op にする。本節は規則表の所有者で、評価は §R の `decode` が実装する。CSR の存在、最低特権、読み出し専用、FS/VS ゲート、counteren ビット、H 階層は、`csr_pkg` に追加する CSR 属性表 1 つから引く (追加のみ)。旧コアは CSR 番地を 3 か所に持ち (`csr_pkg`, `csr.veryl:208-316`, core のリテラル)、`csr_pkg` の定数はどこからも参照されていなかった。

| 検査 | 不正の条件 (V=1 の扱いは M5) | cause | 旧コア | M |
|---|---|---|---|---|
| CSR の存在 | 属性表に無い番地 | 2 | 0 を読み書込みを捨てる | M1b |
| CSR の特権 | `addr[9:8]` > 実効特権 | 2 (VS 階層は 22) | 2 のみ | M1b |
| RO への書込み | `addr[11:10]==3 && csr_wr` | 2 | 書込み意図ではなく opcode で判定 | M1b |
| xRET | MRET は priv != M。SRET は U、または S で TSR=1 | 2 (VU/VTSR は 22) | 検査なし (`:7146-7147`) | M1b |
| SYSTEM の未定義 | SYSTEM funct3=000 の未定義 funct12 (DRET 等) | 2 | NOP として実行 | M1b |
| counteren | S/U からの cycle/time/instret/hpmcounterN で mcounteren (U は scounteren も、V=1 は hcounteren も) のビットが 0 | 2 / 22 | 検査なし | M2 |
| Sstc | stimecmp は mcounteren.TM && menvcfg.STCE (vstimecmp は hcounteren/henvcfg も) | 2 / 22 | 検査なし | M2 |
| FS=Off | FP 演算、FP load/store、fflags/frm/fcsr | 2 | commit で判定、メモリアクセスの後、FP CSR は対象外 | M2 |
| TVM | S での satp アクセス、SFENCE.VMA/SINVAL.VMA | 2 (VTVM は 22) | commit で判定 | M2 |
| U の SFENCE 系 | U での SFENCE/SINVAL/Svinval fence | 2 (VU は 22) | VU は検査なし | M2 |
| WFI | U、または S で TW=1 | 2 (VTW は 22) | 常に NOP | M2 |
| CBO | S/U で menvcfg (U は senvcfg も) の CBIE/CBCFE/CBZE が禁止 | 2 / 22 | 検査なし | M2 |
| 予約符号化 | AMO の予約 funct5/幅、静的な予約 rm | 2 | 実行 | M2 |
| 動的丸めの予約値 | rm=DYN の FP 命令で、frm が予約値 (101-111) を持つ (§R DC2) | 2 | 実行 | M2 |
| 不正な OP-V | decoder が `illegal` を立てた vector 符号化 | 2 | ROB head が wedge (`:5971, :6075`) | M2 |
| VS=Off, vill | vector 命令と vector CSR | 2 | mstatus.VS のみ、VU 実行後 | M5 |
| H 命令 | HLV/HSV/HFENCE/HINVAL を V=1 で、U で HU=0 | 22 / 2 | VU の HFENCE は検査なし | M5 |

- 【決定】属性表に mvendorid, marchid, mimpid, mconfigptr, mcountinhibit を「存在・RO・値 0」で登録する。理由: 旧コアはこれらを未実装のまま 0 で読ませており、boot の firmware が m*id を読む。存在しない CSR を trap にしても boot の挙動は変わらない。
- 【決定】WFI は、合法なら NOP (D2)、上表の条件では trap とする。理由: ACT4 の参照である Sail は U-mode の WFI と TW=1 の S-mode の WFI を illegal にする。NOP は「有界時間で完了する」ので spec 上は trap しなくてもよいが、ACT4 の比較対象に合わせる。boot の WFI は S-mode・TW=0 だけなので lockstep には影響しない。M2 の ACT4 結果で Sail との一致を確認する。
- 不正判定が decode にあるので、FS=Off の FP load がメモリに触れることも、illegal と load fault の優先順位が逆転することも構造的に起きない。

---

### C.9 旧コアの仕様逸脱と allow-list (D4)

新コアはアーキテクチャ的に正しく作り、golden との差は検証計画 (`doc/phase15_verification_plan.md`) 付録 B の許容差異表で吸収する。【決定】allow-list の語彙と行番号は検証計画付録 B のものを唯一の正本とし、本節は付録 B の行番号 (B01-B47) で参照する。本節が決めるのは新コア側の挙動だけである。扱いの語彙 (REPLAY、NORM、MASK:<tag>、EXCL:<tag>、STOP:<tag>、OUT、SAME) の意味も付録 B に従う。理由: 2 か所でタグ名を持つと、書式だけでなく扱いの意味まで分かれる。「推定」の行は M2 の前に golden 上の directed test で確かめる (D4)。本表は commit・trap・CSR の範囲に限る。misaligned や fetch の straddle などは §L, §M, §F の表にある。

| # | 旧コアの逸脱 (根拠) | 新コア | 付録 B の行と扱い |
|---|---|---|---|
| 1 | 最初の S-mode Sv39 satp 書込みで偽の instruction page fault。書込みは捨てられ retire にも数えない (`:7050`, `csr.veryl:905` 対 `:1047`) | retire 後に `pc+4` で本物の fault (C.6) | B02: NORM (N4) と MASK:SATP_ENABLE_WIN |
| 2 | MMU は sfence か satp アクセスまで古い satp を使う (`:7181`) | 書込み直後から新しい satp | B03: boot に影響しなければ SAME、影響すれば EXCL:SATP_LAG (M2 前に golden で判定) |
| 3 | CSR の読み出しが書き戻す: counter の巻き戻し、mip/sip の LCOFIP 消去、csrr satp/frm/fcsr による flush と reservation 解除 (`:7000`) | `csr_wr` のときだけ書く | B13: NORM (N9)、値の差は MASK:CNT と STOP:SD |
| 4 | minstret が retire 数でない: 保持サイクルと replay を数え、slot 1 を数えない (`:7420`) | `popcount(retire)` | B14: MASK:CNT |
| 5 | frm/fcsr への CSR op と同じサイクルに slot 1 が retire し、`pc+4` の refetch で 2 回実行される (`:8451` に `commit_csrw_frm` が無い) | group 規則で起きない | B04: NORM (N6)、冪等でない op は STOP:FRM_CORETIRE |
| 6 | poison された SC が retire した後に replay される (record が 2 つ) (`:6402`) | SC は REPLAY されない (D8: 失敗は rd=1 で retire する) | B05: NORM (N1)、rd==rs1 は STOP:SC_REPLAY |
| 7 | 割込みを ROB が空になってから受け付ける (`:7144`) | flush-at-head (§5.13) | B01: REPLAY (D2 の schedule replay) |
| 8 | MRET を S/U で、SRET を U で実行できる | decode で trap (C.8) | B12: STOP |
| 9 | M 未満へ戻る xRET が MPRV を消さない (`csr.veryl:981-1021`) | 消す (csr 修正) | B24: STOP |
| 10 | FS が FP load や FP CSR 書込みで dirty にならない、VS は常に dirty にならない、SD を書込みで保存する (`csr.veryl:1163-1169, :1060`) | `effect` から `i_fs_dirty`/`i_vs_dirty`、SD は読み出し時に計算 (csr 修正) | B27: STOP:FS_DIRTY (5.15 は FPU off で 0 回)。SD は B13 の STOP:SD。arch suite で発火したテストは lockstep から外して pass/fail で判定する |
| 11 | FS/VS=Off を commit で判定し、メモリアクセスの後、優先順位も load/store fault より下 (`:7213-7230`) | decode で `NONE` | B26: STOP。FP/vector CSR の Off 検査は B28: STOP |
| 12 | 不正 RVC の tval が展開形 (実質 0) (`:7345`) | 16 bit の符号化 | B16: MASK:RVC_ILL |
| 13 | EBREAK の tval が 0 | epc (C.3) | B17: MASK:EBREAK_TVAL |
| 14 | counteren を強制しない (`csr.veryl:408-409`) | decode で trap | B32: STOP |
| 15 | 未実装 CSR が 0 を読む、未定義 SYSTEM と予約 AMO 符号化を実行する | decode で trap (C.8) | 未実装 CSR は B31 (golden が 0 を読ませる必須 CSR は存在表に入れて SAME、それ以外は STOP:CSR_EXIST)。予約符号化は B30: STOP |
| 16 | WFI が常に NOP | 合法なら NOP、U-mode と TW=1 の S-mode では trap (C.8) | B29: S-mode・TW=0 の WFI は SAME (5.15 の idle ループはこれだけ)。trap する条件の WFI は STOP:WFI_TRAP |
| 17 | trap した op の rd が残りうる: priv-illegal の rd が `arch_regs` に入る (`:7808`)、trap する AMO/amocas.q の rd (`:6958`, `:6427`) | `retire[l]` に集約 (C.2.4) | B09: NORM (adapter は arch_regs を読まない)、オペランドに影響したら STOP:PRIV_ILL_RD。amocas.q は B36: STOP |
| 18 | 翻訳 barrier が hstatus, hgatp, vsatp(0x280), PMP, envcfg を覆わない | すべての CSR 書込みで full kill | B21: STOP |
| 19 | SFENCE.VMA が younger を refetch しない | full kill | B22: STOP |
| 20 | satp の MODE が WARL でない (`csr.veryl:1088`) | Bare と Sv39 以外の書込みを無視 (csr 修正) | B43 の satp 部分: STOP:SATP_WARL (5.15 は MODE を probe しないので 0 回)。B43 の残り (mstatus[63]、mip、misa) は SAME |
| 21 | OF が既に立っていても LCOFI を再び pend する (`csr.veryl:1226-1239`) | OF の 0→1 でだけ pend (csr 修正) | B45: STOP:LCOFI |
| 22 | H 関連: HS への trap で SPVP を書く、htval/mtval2 が GPF 以外で残る、ROB 経由の store/AMO GPF が cause 15、VU の SFENCE/HFENCE と VS の HFENCE を trap しない、VU の S-CSR アクセスが cause 2、vsstatus.VS 未検査、VSINH/VUINH を無視、cause 22 の tval が 0 | spec どおり (csr 修正を含む) | B11、B18、B23、B25: OUT (M5 の hvlinux と H directed test) |

意図して直さない差: misa が F/D/C を欠くこと (firmware が読みうるので golden を動かさない。M6 の後にユーザが判断)、tinst/htinst=0 (spec 上合法)、WFI が待たないこと (D2)。mtvec や mepc などの WARL 正規化は【M2 で決定】: ACT4 と Sail が要求する分だけを csr 修正として入れ、残りは本表に行を足す。

---

### C.10 発火カウンタと checker

`o_perf` に出す本章の事象 (§5.15): retire した lane 数ごとのサイクル数、group を切った理由ごと (alone, 例外, poison, store 予算, drain 待ち, limit, irq, kill)、outcome の種別ごと (TRAP, REPLAY, RETIRE_FLUSH の kind 別, T8 backstop)、`irq_take`、`head_started_q` による受付待ちサイクル、partial kill の採用と破棄 (walk 中、連続、full 優先)、full kill の kind 別、walk サイクル数、`exc_q` の置き換え。

`chk_commit` と `chk_rob` (観測専用、sticky) の項目:

- retire が lane 0 から連続している。1 サイクルの flush は高々 1 つ。TRAP、REPLAY、割込み受付のサイクルに lane の record が他に無い。
- `killed()` が選ぶタグを retire していない。`sys_pending.tag` が lane 0 の SYS op と一致する。LQ/SQ 窓との一致がちょうど 1 つ。
- 未割り当てエントリへの完了と二重完了が無い (§5.15 の最低限の項目)。
- T8 backstop の発火数は、捨てた mispredict の resolve 数を超えない。超えたら、早期 kill の採用経路か `recovered` の書込みに欠陥がある。

---

## §L LSU・LSQ・アトミック・I/O

本章は memory pipe (`mem_pipe`)、`lq`、`sq`、`sb`、`atomic_unit`、`io_unit`、`mem_port_arb` を定める。dcache の CPU 側 (`dcache_port_adapter` と M3 の再構築)、`tlb`/`ptw`/`pmp_check` は §M、型と横断契約は §5.9 (メモリポート)、§5.10 (翻訳)、§5.11 (PMA)、§5.14 (I/O) に従う。D5 に従い LSQ は新規に設計し、旧コアから移植するのはアルゴリズムと実測済みの契約だけである。移植元の行番号は L.19 にまとめる。

### L.1 モジュールと責務

| モジュール | 責務 | 所有する不変条件 (要約) |
|---|---|---|
| `mem_pipe` (×MEM_W) | AGU、翻訳要求、PMP/PMA、dcache 要求、forward 照会、load 整形、WB packet | 入口は m0 の 1 か所だけ。すべての op は同じ段 (m2+RESP_LAT) で packet を出す。 |
| `lq` | load の実行状態 (park と再 issue)、store-resolve scan、CoRR line scan、commit 窓の poison 出力 | poison を判定するのは `lq` だけ (§5.12 C7)。kill 後に古い応答を受け取らない。 |
| `sq` | commit 前の store (STA/STD)、forward 照会の SQ 部分、retire 可否の出力 | SQ には commit 前の store しか無い (§5.4 T5)。SQ からの pop と SB への push は同じエッジで行う。 |
| `sb` | commit 済み store の line write-combining、drain、forward 照会の SB 部分 | 可視性契約 (§5.9 MP7) と `ordering_empty`/`resource_empty` の区別。 |
| `atomic_unit` | AMO/LR/SC/amocas、reservation、watch、queued atomic (M4) | 書き込みはすべて exclusive write (§5.9 MP6)。watch 中に line が離れたら書かない。 |
| `io_unit` | IO/NC の load と store を exactly-once で実行する (§5.14) | 受理 (PENDING) 後は再提示しない。同時に未完了の要求は 1 本だけ。 |
| `mem_port_arb` (×MEM_W) | port ごとに m0 の slot を要求者クラスに割り当て、要求と応答を多重化する | クラスごとの待ちに上限 B を持つ (§5.9 MP4)。 |

【決定】forwarding 網は「PA を鍵とする 1 つの網」とし、物理的には `sq`、`atomic_unit`、`sb` の lookup ポートと、`mem_pipe` での優先順位による合成に分けて置く (L.5)。理由: サイズ (`SQ_N`, `SB_N`) を参照してよいのは所有モジュールだけであり (§2.1 P2)、網を 1 モジュールにまとめると両方のサイズを参照することになる。鍵 (PA)、照会の型、照会する段はどれも 1 つしかない。旧コアのように VA 網と PA 網を OR で合成することはしない。

§L が `core_types::<CFG>` に追加する型 (幅はすべて §5.1 の型から導く):

```veryl
enum LqState: logic<3> { ISSUE, INFLIGHT, PARK, READY, DONE }
enum ParkWhy: logic<3> { FILL, BUSY, XLATE, SQ, AQ, HEAD, DBIT }   // DBIT: SQ only
struct FwdQuery {                    // one per memory pipe, presented in m2
    valid : logic, line: logic<50>, dw: logic<3>,
    mask  : logic<16>,               // bytes of dwords dw and dw+1 (same line)
    sq_lim: SqTag,                   // only SQ entries older than this are candidates
}
struct FwdPart {                     // returned by sq, atomic_unit and sb in the same cycle
    cover : logic<16>, data: logic<128>,
    wait  : logic, wait_sq: SqTag,   // a covering entry cannot supply data yet
}
struct StaWrite {                    // mem_pipe -> sq (and the store-resolve scan request to lq)
    valid: logic, sq: SqTag, lq_lim: LqTag, half: logic,
    line : logic<50>, dw: logic<3>, mask: logic<16>,
    attr : pma_pkg::PmaAttr, exc: exc_pkg::ExcRec,
}
```

### L.2 memory pipe の段構成

| 段 | 処理 | 出力 |
|---|---|---|
| m0 | slot の受理 (IQ からの新規 issue、LQ/SQ からの再 issue、非 pipe 要求者の slot token のいずれか 1 つ)。AGU: `rs1 + imm` (atomic は imm=0)、Supm/Ssnpm の pointer masking、line 跨ぎの判定、misaligned atomic の判定 | VA、split 情報 |
| m1 | `XlateReq` を `tlb` の lookup ポート p へ出す。`pmp_check` と `pma_pkg::pma_check` を並べて評価する (§5.11 PM2)。例外を `exc_pkg::exc_prio` で合流させる | PA、`PmaAttr`、`ExcRec`、TLB hit/miss |
| m2 | load: `MemReq` を出し、同じサイクルに forward 照会を行い、LQ に snapshot (`seen`, PA) を書く。store: SQ に STA (と STD) を書く。atomic: `atomic_unit` に渡す。park する op (TLB miss、IO/NC、line 跨ぎ load) は LQ/SQ に状態を書く | 要求、forward 結果 (段レジスタで運ぶ) |
| m2+1 ... m2+RESP_LAT | store: m2+1 に store-resolve scan を行う (L.6)。load: m2+RESP_LAT に応答を受け、forward した byte を応答データに重ね、`lsu.veryl` から移植した整形関数 (shift、符号拡張、NaN-boxing) を通す | `WbPacket` を wbm_p に登録する |

- 【決定】すべての op (load、store、fault した op) は m2+RESP_LAT の段で packet を出す。store の packet は ROB の完了だけを運ぶ (`has_rd=0`)。理由: 段ごとに出口が違うと、wbm_p 上で段の違う 2 つの op が衝突する。応答が HIT 以外 (MISS、RETRY、PENDING) のときは packet を出さず、その WB サイクルは空く。
- サイクルの関係 (memory IQ の select を S とする): m0 = S + ISS_TO_ACC、m1 = m0+1、m2 = m0+2 = adapter の受理サイクル A。応答サイクル R = m2 + RESP_LAT。packet は R の edge で登録し、W = R+1 に wbm_p に出る。公表レイテンシ `LD_LAT` (m0 から W まで) = 3 + RESP_LAT (RESP_LAT=2 なら 5) で、`claim_off(p, LOAD)` = ISS_TO_ACC + LD_LAT とし、wb_resv はこの枠を select の時点で予約する (§X.3、§X.5)。依存 op の wake は HIT 応答を受けた R に出す (先行量 1。WAKE_LEAD に満たない分、消費者は PRF から読む。§5.7、投機 wakeup は無し)。`LD_LAT`、`FWD_SKEW`、`SHADOW_LEN` は `fu_pkg` に置く (§2.1 P4)。IQ エントリは m0 の受理で解放する。miss した load の再実行は LQ の責任である (旧コアの「miss 経路を持たない構造に可変レイテンシ op を入れるな」という教訓、`iq_int.veryl:534-542`)。
- 【M3 で決定】AGU と翻訳を 1 段にまとめるか、整形を応答サイクルの組合せに入れるか。旧コアでは EX が 1 サイクル延びると CoreMark が約 12 % 落ちたので、M3 の latency sweep で load-use 鎖に対する IPC 感度を測って決める。段の増減は §5.3 R6 の局所変更で済み、`LD_LAT` と `FWD_SKEW` (L.5) が追従する。
- 翻訳の文脈 (特権、SUM、MXR、PMLEN など) は m0/m1 で CSR ファイルから読む。これが正しいのは §5.10 X1 による。
- m1 で TLB が miss したら、`ptw` の要求キューに valid/ready で walk 要求を出し (§5.10 X4、タグは `MemTag{LQ または SQ, idx, rob}`。`rob` は owner の RobTag)、op は m2 で park する。要求キューが ready でなければ「walk 未要求」として park し、次に walk 完了の broadcast (`PtwEvent`、§5.10 X2) を受けたときに再 issue して要求をやり直す。

### L.3 LQ/SQ のエントリ、割り当て、kill

割り当て: `dispatch` が `OpClass.budget` (LQ, SQ) に従って割り当てる (§5.2)。インタフェースは §R.5.1 の形で、`lq`/`sq` は登録済みの空き数 `o_free` (`tail - head` から計算し、別のカウンタは持たない) と、次に割り当てるタグの表 `o_alloc_tag[RENAME_W+1]` (`o_alloc_tag[k]` は k 個割り当てた後の tail) を出す。dispatch は group 内の前置和 `P[l]` でこの表を引くだけで、`next()` もリングのサイズも使わない (§2.1 P2、§R.5.3)。各 load には `sq_lim` (その load より若い最初の SQ 位置、`sq.o_alloc_tag[P[l][SQ]]`) を、各 store には `lq_lim` (同じく `lq.o_alloc_tag[P[l][LQ]]`) を持たせる。旧 `load_queue` は `is_full` (`load_queue.veryl:242`) を割り当てに使わず (割り当ては `:249-252` で ROB の満杯だけを見る)、`LQ_N == ROB_DEPTH` でしか正しくなかった。新しい LQ/SQ は credit による背圧を持つので、どのサイズでも正しく動く (§3.3)。

| 割り当て先 | 対象 op |
|---|---|
| LQ | 通常 load、FP load、IO/NC load、LR |
| SQ | 通常 store、FP store、cbo.zero、cbo.clean/flush/inval、AMO、SC、amocas (store 側のふるまいを持つ atomic) |
| どちらも無し | FENCE |

【決定】LR は LQ に割り当てる。理由: TLB miss した LR が park し、walk を自分のタグで要求する場所が要る (§5.10 X4)。LR の LQ エントリは翻訳待ちの park と walk 要求の名義のためだけにあり、`seen` を立てない (store-resolve scan と CoRR scan の対象外)。LR の順序と結果は `atomic_unit` (reservation、watch、§L.11) が持つ。

LQ エントリ: `{ex: ExTag (rob, pdst, has_rd), ldk (size, signed, fp), sq_lim, va, line[2], mask[2], split, attr, exc, state, why, key (fill_id か SqTag), seen, poison}`。SQ エントリ: `{rob, lq_lim, kind (STORE, ZERO, CMO, AMO, SC, CAS, IO), size, va, line[2], mask[2], split, attr, addr_v, data, data_v, exc, state, why}`。`[2]` は line 跨ぎの lo/hi の半分である (L.15)。どちらも load の値そのものは持たない (例外は L.15 の split buffer 1 本)。

主なポート (lane/port は for-generate の配列、タイミングはヘッダに書く):

| モジュール | 入力 | 出力 |
|---|---|---|
| `lq` | `i_alloc` (dispatch、RENAME_W lane)、`i_snap[MEM_W]` (m2 の snapshot と park)、`i_verdict[MEM_W]` (m2+RESP_LAT の応答の判定)、`i_sta[MEM_W]` (scan 要求)、`i_mem_ev` (`MemEvent`)、`i_coh_ev` (inv/inv2/evict の line、§M が型を定める)、`i_xlate_ev` (walk 完了の broadcast と fault 応答)、`i_sq_ev` (STD 書き込みと SQ からの退出)、`i_retire_cnt`、`i_oldest`、`i_bar_alloc`/`i_bar_ret` (§L.10)、`i_kill` | `o_free`、`o_alloc_tag[RENAME_W+1]`、`o_bar_after[RENAME_W+1]`、`o_bar_ret`、`o_load_fence` (§L.10)、`o_reissue_req`、`o_commit_win[COMMIT_W]` (`{tag, poison}`)、`o_head_rec` (retire record 用の va/pa/size)、`o_split_data`、`o_perf` |
| `sq` | `i_alloc`、`i_sta[MEM_W]`、`i_std[MEM_W]`、`i_fwd_q[MEM_W]`、`i_xlate_ev`、`i_wt_done` (`io_unit`)、`i_retire_cnt`、`i_oldest`、`i_kill` | `o_free`、`o_alloc_tag[RENAME_W+1]`、`o_fwd[MEM_W]`、`o_commit_win[MEM_W]` (`{tag, retire_ok}`)、`o_started` (D ビットの `nonspec` walk、§5.13.1)、`o_sb_push[PUSH_W]` (retire と同じエッジ)、`o_sq_ev`、`o_reissue_req`、`o_head_rec` |
| `sb` | `i_push[PUSH_W]`、`i_vu_push` (M5)、`i_fwd_q[MEM_W]`、`i_drain_ack`、`i_aq_empty` | `o_fwd[MEM_W]`、drain ポート (`line`, 8 lane の data と strobe、`urgent`)、`o_free`、`o_resource_empty`、`o_drained`、`o_ordering_empty` |

kill への応答は §5.4 の消費者表 (`lq`、`sq` の行) と T5 のとおりで、生存数の popcount は使わない。

- 不変条件 (所有者 `mem_pipe`、`lq`/`sq`): pipe が出した要求の応答は、その op を運んでいる段レジスタが受け取り、判定 (`i_verdict`) として LQ/SQ に渡す。op が kill されていれば段レジスタは空なので、応答はそこで捨てられる (§5.3 `stage_reg`、§5.4 T3)。したがって、巻き戻されて同じタグで再割り当てされたエントリに古い応答が届くことはない。LQ/SQ が直接受け取るものは 2 つあり、どちらも別の仕組みで守る。fill の event は `fill_id` の世代で照合する (§5.9 MP2)。walk の応答 (成功でも fault でも完全な XlateResp) は、walk 要求が owner の RobTag (`MemTag.rob`) を運び、`ptw` の要求キューが `killed()` を適用して kill された owner への応答を出さないことで守る (§5.4 の消費者表)。要求を保持する `io_unit` と `atomic_unit` も同じく `MemTag.rob` に `killed()` を適用する (§5.9)。
- retire: `commit` が lane ごとの retire mask から load 数と store 数を数え、`lq`/`sq` の head を進める (§5.12 C3)。

`lq` のヘッダ (§5.15 の書式。他の §L モジュールも同じ粒度で書く):

```
// lq: load queue; owns each load's execution state, ordering-violation poison, and the commit window
//
// Ports (timing contract):
//   i_alloc[RENAME_W] : group handshake from dispatch, lanes contiguous; never valid in a kill cycle
//   o_free, o_alloc_tag[RENAME_W+1] : registered state only (free = LQ_N - (tail - head); o_alloc_tag[k] = tail advanced by k)
//   i_snap[MEM_W]     : m2 of each pipe; sets seen on the capture edge
//   i_sta[MEM_W]      : store-resolve request; scanned the cycle after the store's SQ write
//   i_verdict[MEM_W]  : m2+RESP_LAT; only for ops still live in the pipe stage registers
//   o_commit_win      : registered {tag, poison} of the COMMIT_W oldest entries; commit matches by tag equality
//   i_kill            : tail := kill.lq_tail (partial) or empty (full); applied on the capture edge
// Owns:
//   - poison is set only on entries with seen=1 and is cleared by the snapshot of a re-issue
//   - a store's scan covers every load whose snapshot did not include that store
//   - no entry leaves PARK except on its own key (fill_id generation, SqTag) or a broadcast
// Rationale:
//   - commit-time replay only, with no dependence predictor and no precision filters:
//     both levers were measured to be negligible against the cost of the structure
```

### L.4 store: execute 時の翻訳と address/data の分離

- 【決定】すべての store を execute 時 (m1) に翻訳する。SQ エントリは PA、`PmaAttr`、例外を持ち、commit は TLB を再駆動しない (§5.12 C5)。理由: 旧コアの事前翻訳は空きポートがあるときだけ動いたため、store 側の PA 被覆率は 31-39 % にとどまった。その結果、PA で比較する網を作れなかった。
- SQ のインタフェースは M1 から 2 系統の書込ポートを持つ。STA (`{line, mask, attr, exc, addr_v}`, `mem_pipe` から) と STD (`{data, data_v}`)。
- 【決定】M1-M2 では、store は rs1 と rs2 の両方が揃ってから 1 つの op として issue し、m2 で STA と STD を同時に書く。理由: skeleton の段階では issue の経路が 1 本で済む。インタフェースは分離してあるので、M3 で issue を分けても `sq` は変わらない。
- 【M3 で決定】STA と STD を別々に issue するか (STD は実行ポートの op として SQ の STD ポートに書く案)。M3 の sweep で 2 つを測って決める: store-resolve scan による replay の数 (STA の遅れが原因の分) と、STA の準備ができていて data だけを待っている store の滞在サイクル数。
- retire 可否: `sq` は最古の MEM_W 個のエントリについて、登録済みの `{tag, retire_ok}` を commit 窓として出す。`retire_ok = addr_v && data_v && (kind != IO || wt_done)` で、IO store の `wt_done` は `io_unit` が WT_DONE を受けたサイクルに立てる (L.13)。commit はタグの等値比較で自分の lane のエントリを選び、`retire_ok` が偽なら WAIT にする (§C.2.2 の 4 行目)。例外は `exc_q` が運ぶので `retire_ok` には入れない。cbo.clean/flush/inval (kind CMO) は翻訳と権限検査 (Zicbom) だけを行い、cache への要求を出さず、SB にも何も入れない。retire は no-op である (プラットフォームが完全に coherent なため、§5.5、§M)。cbo.zero (kind ZERO) は line 全体の 0 を `sb` に push する (常に新しいエントリを割り当てる、L.8)。
- 不変条件 (所有者 `mem_pipe`): store の ROB 完了 packet (R で登録、L.2) は、その store の store-resolve scan (m2+1) が立てた poison が登録された後に出る。これは RESP_LAT ≥ 1 で成り立つ。こうしておけば、若い load が store と同じ group で poison を逃れて retire することはない。
- IO/NC の store は SQ に入るが、forward の送り手にならず、SB にも入らない (§5.14)。

### L.5 forwarding 網 (PA キー、memory port ごと)

照会: `mem_pipe` は m2 で `FwdQuery{line, dw, mask(16), sq_lim}` を `sq`、`atomic_unit`、`sb` に同時に出す (port ごとに 1 本)。line 跨ぎのアクセスは半分ごとに別の pass になるので、照会は常に 1 line、隣接 2 dword の範囲に収まる (§5.9 MP5)。

byte ごとの優先順位 (高い順):

1. SQ: `sq_lim` より古く、`addr_v` で、その byte を覆うエントリのうち最も若いもの。比較は `older()` で行う (§5.2)。そのエントリの `data_v=0` なら照会の結果は WAIT (key = その SqTag) になる。
2. `atomic_unit` の queued atomic (M4): その byte を覆えば WAIT。
3. SB: その byte を覆うエントリのうち最も若いもの (SB は program order に並んでいる)。drain shadow のエントリは SB のどのエントリよりも古い (L.8)。
4. dcache の応答。

- 送り手から除くもの: IO/NC の store、CMO。atomic (AMO/SC/CAS) の SQ エントリは「覆うなら WAIT」の送り手であり、data は渡さない (旧 ASQ の重なり待ち `heliodor_core.veryl:9843-9851` と同じ意味)。cbo.zero は line 全体を 0 で覆う送り手になる。
- 受け手から除くもの: IO/NC の load (oldest token を持ち、`ordering_empty` の後でしか発行しないので、送り手は存在しない)。
- 実装: 各候補について line を 1 回比較し、byte の被覆は strobe の AND で求める。byte ごとの最若選択は `tree_pkg` の argmax 木で行い、直列の累積は書かない (§5.15)。旧網は `ROB_DEPTH=32` 前提で木を手で展開しており、32 より小さければ隣の byte の候補を読み、大きければ候補を落としていた (`heliodor_core.veryl:8079-8116`)。網のコストは MEM_W × 16 byte × (SQ_N + SB_N + 1) であり、旧コアの port あたり 8 × ROB_DEPTH を置き換える。
- 不変条件 (所有者 `sq`/`sb`): retire する store は、SQ からの pop と SB への push を同じエッジで行う。どのサイクルでも、その store は SQ か SB のちょうど一方に見えている。
- 【決定】forward の snapshot は dcache の配列読み出し (要求の受理、Stage-A) と同じサイクル m2 に取る。したがって `fu_pkg` の `FWD_SKEW` (配列 snapshot から forward 判定までの段数。`SNAP_OFS` と forward 判定段の差として導く) は 0 である。理由: これなら drain の ack と同じエッジに読む load も、配列か SB のどちらかでその store を必ず見る。adapter が配列をもう一度読む場合 (nf 経路など) は、配列読み出しが forward より後になるが、この向きの skew は安全である (drain 済みの store は配列に入っている)。forward を 2 段に分けるときは `FWD_SKEW` が 1 になり、L.8 の shadow が 1 段になる。

### L.6 順序違反の検出と commit 時の replay

store-resolve scan (所有者 `lq`、`mem_pipe` ごとに 1 ポート): store S の STA は m2 の終わりのエッジで SQ に書かれ、S の scan は m2+1 に行う。対象は、`lq_lim(S)` 以降の LQ エントリのうち、`seen=1` で、IO/NC ではなく、S の byte と PA で重なるもの。それらに poison を立てる。

- load は forward snapshot を取った m2 の終わりのエッジで `seen` を立てる。この時刻の割り当てによって、同じサイクルの畳み込み (fold) が要らなくなる。m2 が S の STA 書き込みと同じサイクルかそれより前の load は S を forward で見ないが、S の scan の時点では `seen` が登録済みである。m2 がそれより後の load は S を forward で見る。2 本の pipe で load と store が同じサイクルに来る場合も、この時刻規則だけで覆える。旧コアは同じサイクルの畳み込みを scan ごとに書いており、1 本漏れると違反を見逃した (`load_queue.veryl:332-349`、`efcdf7c`)。
- 【決定】精度を上げる工夫 (S より若い store から forward した load を除外する、など) はしない。理由: 精度レバーの実測天井は 0.41 % と 0.02 % だった。
- 【決定】record 時の self-scan は持たない。理由: self-scan は、VA キーの forward 網が見逃しうる「既に住所が分かっていた古い store」を PA で拾い直すために存在し、そのせいで「網が実際に供給した byte は免除する」という網と LQ の結合 (S16/P1_SERVED、`FWD_PA` との flip 結合) を必要とした。port 1 にだけこの免除が欠けていたことが poison の大半の出所だった (`b3266ab`)。PA キーの網が 1 つだけなら、load の snapshot は STA 済みの古い store をすべて見ており、それより後の STA は上の時刻規則で scan が拾うので、self-scan が捕まえるべき事象は残らない。

CoRR line scan (§5.9 MP8、所有者 `lq`): dcache の inv、inv2、evict の各 event (line PA) を受け、line (lo か hi) が一致し、`seen=1` で IO/NC でないエントリをすべて poison する。旧アルゴリズム (`load_queue.veryl:534-557`) をそのまま移植する。PA 同士で比較するので Sv39 でも健全である (旧コアでは VA の record に対して PA の event を比べていたため、Sv39 で一度も一致しなかった)。

- 不変条件 (所有者 `lq` と §M の adapter): m2 の snapshot と同じサイクル t に届いた inv/evict は、adapter が `RETRY(INV_RACE)` で返す。t+1 以降の event は登録済みの `seen` で捕まえる。
- 【決定】再 issue した load は、新しい m2 snapshot を取るときに `seen` と `poison` を消す。理由: 値を決めるのは最後の snapshot だけである。MISS で値を得ていない load への poison は、再 issue が無効にする。

commit 時の replay (§5.12 C7): `lq` は最古の COMMIT_W 個のエントリについて登録済みの `{tag, poison}` を出す。`commit` の各 lane は自分が運ぶ LqTag と窓エントリのタグの等値比較で 1 つを選ぶ (§C.1.1 の窓の規則。位置 head+k では対応させない)。poison された load が lane 0 にあれば REPLAY、lane l>0 にあればその手前で group を切る。

- 【決定】D5 に従い、回復は commit 時の full kill + refetch だけで行い、依存予測器は作らない。理由: 予測器の天井は 0.13 % だった (完全な予測器でも +0.66 %)。
- 【M3 で決定】replay のコスト (旧コアでは 1 件 10.8 サイクル、boot の 1.33-1.57 %) を cfg_w4 で測る。実行時の部分 kill (keep = load の直前) に変える価値があるかをそれで判断する。変える場合も `lq` が出す poison の意味は変わらず、`flush_ctrl` 側の変更で済む。

### L.7 非ブロッキング load: park、wakeup、再 issue

LQ エントリの状態:

| 状態 | 入る条件 | 起きる条件 (READY へ) |
|---|---|---|
| ISSUE | 割り当て | (IQ から m0 に入ると INFLIGHT) |
| INFLIGHT | m0 で受理された | 応答による (下の行) |
| PARK(FILL, fill_id) | `MISS(fill_id)` | 同じ `fill_id` で `FILL_CRIT` (crit dword が自分の dword と一致)、`FILL_DONE`、`FILL_ABORT` |
| PARK(BUSY) | `RETRY(FILL_BUSY)` | 任意の `FILL_DONE` か `FILL_ABORT` |
| READY | `RETRY(INV_RACE / PREEMPTED / WB_BLOCKED / BANK_CONFLICT)` | 次のサイクルに直ちに |
| PARK(XLATE) (M2) | TLB miss | `ptw` の walk 完了の broadcast (install でも fault でも)。walk の受理から park の edge までに同じキーの event が来ていれば park せず READY (§5.10 X2 の同サイクル規則)。自分のタグ宛ての fault 応答を受けたら `exc` を保存して READY |
| PARK(SQ, SqTag) | forward が WAIT (覆う store の data が無い、または atomic) | その SQ エントリに STD が書かれたか、エントリが SQ を出た |
| PARK(AQ) | queued atomic と重なった (M4) | `atomic_unit` の queue が空になった |
| PARK(HEAD) | IO/NC load (`io_unit` が実行する)、line 跨ぎの load (M1-M2) | IO/NC: `io_unit` が完了させる。line 跨ぎ: oldest token が自分のタグに等しい |
| DONE | HIT、全 byte の forward、例外 | retire で解放 |

- 【決定】park した load は event の data を使わず、必ず再 issue で値を得る。理由: 再 issue すれば forward の snapshot も取り直せる。また load の WB 経路が「pipe の固定レイテンシで予約した wbm_p」の 1 本だけで済む (§5.7 LOAD)。M1-M2 の adapter は、`FILL_CRIT` の後で crit dword を要求されたとき、fill 中の critical word を HIT として返す (§M)。
- 再 issue の調停 (所有者 `lq`): READY のエントリから最古のものを `tree_pkg` の argmin 木 (`older()`) で選び、`mem_port_arb` に REISSUE クラスとして要求する。再 issue する op は m0 から入り、VA と、保持している `{line, attr}` または `exc` を運ぶ。m1 はそれらがあれば TLB の結果の代わりに使う。fault を保持していたエントリは m2+RESP_LAT で例外付きの完了 packet を出すので、例外の報告経路は 1 本に保たれる (§5.8)。
- 【決定】`RETRY(BANK_CONFLICT)` を受けたエントリは READY に戻り、他の READY エントリと同じく最古優先の再 issue 調停 (下記) で、空いているどの pipe からでも再 issue する。特定の pipe へ回す規則は持たない (§2.3 R4)。前進の論拠: port 0 を含むどの論理ポートも衝突に負けうるが、衝突の勝者は予約の無い限り `MemTag.rob` の古い方である (§M.2.6、M3 は §M.6.3)。したがって machine の最古の load は衝突に負けず、他の load はより古い load が退いた後に前進する。adapter が HOLD 中に全要求を BANK_CONFLICT で返す間の空回りは、HOLD の終わり (fill の開始) で終わる。
- 【M3 で決定】1 サイクルに再 issue する数 `REISSUE_W` (初期値 1、上限 MEM_W)。FILL_DONE のあとに READY のまま待ったサイクル数の分布を、cfg_w4 の boot と memcpy bench で測って決める。
- `sq` も同じ形で再 issue する。対象は、TLB miss の STA、line 跨ぎの hi 側の STA、D bit を待つ STA (L.16) である。
- M1-M2 の adapter は fill 中のアクセスを (行 4 の critical-word 早期完了を除いて) HIT にしないので (§M.2.3)、fill 中の load はすべて PARK(BUSY) になる。pipe は止まらず、load 以外の op は進み続ける。fill 中の hit (`o_hit_safe`) は §M の M3 の測定項目である。

### L.8 SB: line write-combining、drain、可視性契約

エントリ: `{line: logic<50>, data: logic<512>, strb: logic<64>}`。循環バッファで、旧コアの shift FIFO のように merge 先の index がずれることは無い (`heliodor_core.veryl:9926`)。

push (所有者 `sb`、ポート数 `PUSH_W = max(MEM_W, 2)`、単位は line):

- 同じサイクルの push は program order (ポート順) に処理する。push k は、既存エントリと、同じサイクルの push j<k が作るエントリの中から、同じ line を持つ最も若いエントリに merge する。見つからなければ新しいエントリを割り当てる。旧コアの「最も若い同一 line に merge する」規則 (`heliodor_core.veryl:9806-9825`) と同じであり、byte ごとの最若選択の forward とこの規則が組になって正しさを保つ。
- 【決定】次の 2 つは merge 先にしない: drain の ack を受けたサイクルの head エントリ、cbo.zero が割り当てたエントリ以外への cbo.zero 自身 (cbo.zero は常に新しいエントリを割り当てる)。cbo.zero のエントリへ後の store が merge するのは許す。
- 契約 (読み手への明示): merge は、間に別の line のエントリがあっても古いエントリに入る。したがって、別の line への store は program order と異なる順に見えるようになる。RVWMO ではこれが許される。順序を回復するのは `ordering_empty` を待つ操作だけである (FENCE、IO、atomic、VU)。Ztso は支援しない。
- tohost の store は普通の cacheable store として扱う。harness 用の write-through 窓は持たない (§5.11 PM5、D3)。

drain (§5.9 MP7、所有者 `sb`): drain ポートを駆動するのは head エントリだけで、line 幅、8 lane の data と strobe を出し、ack まで保持する。ack のエッジで pop する。

- `o_drain_urgent = (占有数 >= SB_N - 1)` を dcache の `i_sdrain_urgent` に渡し、新しい load miss の fill 開始よりも drain の RFO を優先させる。【決定】旧コアの「`sb_cnt >= 3` で load の issue を止める」水位制御は持ち込まない。理由: N_FILL=1 なので、urgent があれば drain が待つのは実行中の fill 1 本までで、待ちは有界になる。M4 の N=4 boot で SB 満杯のサイクル数と drain の最大待ちを `o_perf` で確かめる (旧コアの N=4 の drain 飢餓が再発しないこと)。
- 出力 (旧 `sb_empty` は 15 か所で 2 つの問いに使われていた。これを 3 つに分ける):

| 出力 | 意味 | 使ってよい消費者 |
|---|---|---|
| `o_resource_empty` | drain するエントリが無い | dcache への drain 要求だけ |
| `o_drained` | エントリも shadow も無い (commit 済みの通常 store がすべて可視) | `atomic_unit` が queued atomic の RMW を始めるとき |
| `o_ordering_empty` | `o_drained && atomic_unit の queue が空` | FENCE、IO、atomic の開始、VU、D bit 更新 |

- 可視性契約の具体化: shadow の長さは `SHADOW_LEN = FWD_SKEW` (L.5)。ack のエッジで pop したエントリの line、data、strobe は SHADOW_LEN サイクルの間、最古の SB 候補として forward に見え続け、`o_drained` も偽のまま保たれる。初期の段構成では SHADOW_LEN=0 なので shadow のハードウェアは生成されない。それでも長さは定数として定義し、段の追加で自動的に追従させる (旧コアの shadow は Block T と L1 が別々の扉から同じ窓を開けた後で作られた。`heliodor_core.veryl:9967-10040`)。
- §S への依存: full line の write-through drain (`wt_fires`) は、bus の grant で ack を返し、自分の S コピーを落とす。その後にこの hart の load がその line を refill したとき、merge 済みの line が返ることは L2/バスの順序で保証されている。旧コアではこれを検査で閉じただけで、テストは無い (`48b2f51`)。M4 で directed test を追加する。

### L.9 store の複数 lane での retire

- 1 サイクルに retire できる store は MEM_W 個まで、push する line は PUSH_W 個までとする (§3.2)。上限を超える store の lane の手前で group を切る (§C.2.2 の予算)。どの lane の store でも retire できる (C5)。
- 予算の式の正本は §C.2.2 で、`n_st[l] <= MEM_W` かつ `n_line[l] <= min(PUSH_W, sb_credit)` とする。`sb_credit` は SB の空きエントリ数で、line 単位で数える (SB のエントリは line なので、store の個数ではない)。予算は登録済みの値 (`sb_credit` と `sq.o_retire_ok[0..MEM_W-1]`) だけから作る。【決定】満杯時に merge できる store を受け入れる旧コアの特例はやめ、空きエントリ数だけで判定する。理由: merge の判定は line 比較の組合せ経路を commit に引き込む。代償は SB が満杯のサイクルにだけ現れ、旧コアの N=1 boot では 1.03 % だった。
- line 跨ぎの store は 2 line を push するので、PUSH_W を 2 つ消費する。cfg_w2 (MEM_W=1) でも PUSH_W=2 なので、この store は 1 サイクルで retire できる。

### L.10 特殊アクセスの順序規則

`ordering_empty` は L.8 の `sb.o_ordering_empty` を指す。oldest token は §5.12/§5.13 I5 の `nonspec_ok` 付きの token である。

| アクセス | 実行を始める条件 | 若い load | 若い store | forward | poison/replay | retire の条件 | 所有者 |
|---|---|---|---|---|---|---|---|
| cacheable load | 投機的に issue してよい。アドレス未知の古い store も追い越す | | | 受け手 | store-resolve scan と CoRR scan、commit で REPLAY | done && !poison | `lq` |
| cacheable store | STA/STD を投機的に実行してよい | 重なる load は forward か WAIT | | 送り手 | | L.9 | `sq`/`sb` |
| IO load (NC load も M1-M2 では同じ) | 翻訳までは投機的。その後 park し、oldest token、`ordering_empty`、`atomic_unit` が空、のすべてが成り立ったら 1 回だけ発行する | 投機を続けてよい (IO の強順序は IO 同士にだけ効く) | | 受け手でない | 対象外 (§5.14) | `io_unit` が完了させる | `io_unit` |
| IO store (NC store も M1-M2 では同じ) | oldest token && `ordering_empty`。non-posted で 1 回だけ発行する | 後続の IO load は head 条件で自然に待つ | in-order retire で待つ | 送り手でない | | `WT_DONE` の後 | `io_unit` |
| AMO、SC、amocas (aq/rl 無し) | oldest token && `ordering_empty` (すべての atomic を release として扱う) | 重なる load は WAIT。重ならない load は投機してよい | in-order retire で待つ | WAIT を返す送り手 | L.11 | L.11 | `atomic_unit` |
| aq 付きの AMO/LR/SC | 同上 | `ld_barrier=1`: より若い load は retire するまで issue しない (下記) | 同上 | 同上 | | | `decode` (OpClass)、`lq` |
| rl 付き | 上の `ordering_empty` で満たされる | | | | | | |
| LR | oldest token && `ordering_empty`。`LOAD_EXCL` で読む | 投機してよい (CoRR scan が守る) | | | | 結果の WB の後 | `atomic_unit` |
| queued atomic (M4) | retire して queue に入り、`sb.o_drained` の後に RMW を行う | 重なる load は PARK(AQ) | queue が空になるまで store を retire させない | WAIT を返す送り手 | | queue に空きがある | `atomic_unit` |
| FENCE (pred/succ、.TSO にかかわらず rw,rw として扱う) | なし | `ld_barrier=1` (下記) | | | | `ordering_empty` (§5.5 の drain=1。MP7 により atomic の queue も含む) | `commit` |
| FENCE.I、SFENCE.VMA、HFENCE など | なし | NEXT_PC flush で refetch される | | | | `ordering_empty`、retire 後に flush | `commit` |
| cbo.clean/flush/inval | m1 で翻訳と権限検査だけ行う (fault を出す)。コヒーレントな SoC ではメモリへの効果を持たない | | | 送り手でない | | 通常の store と同じ | `sq` |
| cbo.zero | store と同じ。SB に full line の 0 を割り当てる | 重なる load は 0 を forward | | 送り手 | | 通常の store と同じ | `sq`/`sb` |
| PAUSE | NOP (FENCE として扱わない) | | | | | | `decode` |
| VU のメモリ op (M5) | oldest token && `ordering_empty`。mem_pipe 0 の issue slot (HEAD クラス) を使う client として要求する。forward も load 整形も行わず、128 bit の生の応答を受ける | vector store の retire で NEXT_PC flush | vector store は `sb.i_vu_push` から `sb` に入る | | | §V | §V |
| Svadu の D bit 更新 | store が oldest token を持つ受理 edge で `nonspec` walk を出したとき (L.16、§5.13.1) | | | | | | `sq`/`ptw` |

- 【決定】atomic はすべて `ordering_empty` を待ってから始める。理由: release の有無で場合を分けずに済む。旧コアの穴 H2 (rl 付きの読み出しが queued atomic を見ない) と H3 (VU が queued atomic を見ない、`heliodor_core.veryl:11324`) は、どの消費者も `ordering_empty` という同じ 1 つの述語を読むことで構造的に消える。atomic はもともと head でしか動かないので、待ちのコストは SB の drain だけであり、その 96.6 % はローカル merge である。
- 【決定】atomic の `OpClass.drain` は 0 とする。理由: 待つのは `atomic_unit` が最初の要求を出す前であって、retire の時点ではない。`ld_barrier` は aq bit に等しい (§5.5 の ATOMIC 行)。

`ld_barrier` の規則 (所有者 `lq`、消費者 memory 側の `iq`):

- 契約: load L が issue してよいのは、L より古い未 retire の `ld_barrier` op が無いときだけである。すなわち、未 retire の `ld_barrier` op のうち最古のものを B とすると、`older(B.tag, L.tag)` の load は待ち、それ以外の load (B より古い load と、B が無いときの全 load) は決して止めない。B より古い load を止めると、B は自分より古い load の完了を待って head に来られず、デッドロックする。
- 実装: タグを保持して比較する代わりに、`lq` が barrier の通し番号を持つ。`bar_alloc_q` は dispatch した `ld_barrier` op の数、`bar_ret_q` は retire した数で、どちらも `BarSeq` (幅 `ROB_IDX_W+2` の巡回カウンタ。未 retire の barrier は ROB_N 個以下なので巡回しても比較は曖昧にならない)。dispatch は load ごとに `bar_w` = 「その load より前の lane までを数えた `bar_alloc`」(`lq.o_bar_after[P[l][BAR]]`、§R.5.3) を IQ に書き、`bar_w != bar_ret_q` なら `obey_fence` を立てる。barrier は alone なので 1 サイクルに retire するのは高々 1 つであり、`bar_ret_q` は 1 ずつ進む。`lq` は barrier が retire したサイクルに `o_load_fence {valid, seq: 進んだ後の bar_ret}` を出し、iq は `seq == bar_w` のエントリの `obey_fence` を落とす。`bar_w` 以前の barrier がすべて retire したことと、最古の未 retire の barrier が L より古くないことは同値なので、上の契約が成り立つ。
- kill: 部分 kill は `bar_alloc_q := Kill.bar_seq` (keep の dispatch snapshot、§5.4 T5/T6)、full kill は `bar_alloc_q := bar_ret_q`。生き残る load の `bar_w` は keep 以前の barrier しか数えていないので、巻き戻しの影響を受けない。
- `ld_barrier` を持つ op は FENCE と aq 付きの atomic である (§5.5)。M1b は FENCE だけで発火する。

### L.11 atomic_unit

入力: m2 で `mem_pipe` から受け取る翻訳済みの atomic `{OpTag, op (funct5, size, aq, rl), pa, attr, rs2 の値}` (rs1 と rs2 は通常の issue と同じく memory IQ の 2 source で読む)。例外を持つ atomic は `mem_pipe` が自分で完了させ、`atomic_unit` には渡さない。oldest token を持つ atomic の要求は port 0 の HEAD クラス、queued atomic (M4) の要求は ASQ クラスの slot で出す (L.14)。開始と開始後の再要求は §5.13.1 の規則に従う: 最初の `LOAD_EXCL` (SC は `STORE_EXCL`) の受理 edge で `started_q` を立て、それ以降の再要求 (MISS と FILL_DONE の後、RETRY の後、FAIL と watch による読み直し、`STORE_EXCL`) はすべて `started_q` で出す。LR も同じ扱いである (LOAD_EXCL の slot は fill の DONE まで保持され、§M.2.6 はそれが kill されないことを前提にしている)。

【決定】amocas の追加オペランド (比較値の rd、amocas.q の rd+1 と rs2+1) は、`atomic_unit` が開始時に自分で読む。arch RAT の読出ポートで写像を引き、PRF の読出ポートで値を読む。理由: op は最古なので、より古い op はすべて retire しており、arch RAT の写像がそのままこの op の source の写像であり、値は PRF にある (§V.3 VA3 と同じ論法)。これで `DecOp.src[3]`、memory IQ の `IQ_NSRC=2`、§X.2 の slot 表を amocas のために広げずに済む。この読出ポート (arch RAT の int 読み 4 本と PRF の int 読み 4 本、amocas の開始時だけ使う) は §X.2 の本数に含まれず、M2 で amocas を入れるときに足す。結果は wbm0 に HOLE_FILL で書く (§5.7)。

dcache との契約 (§5.9 MP6、§M):

- `LOAD_EXCL` は所有権付きの読み出しである。E/M なら hit、S なら upgrade、miss なら RFO を起こす (`MISS(fill_id)` の後、`FILL_DONE` で再要求する)。データが届くと dcache は有界の probe 延期 pin を張る (64 サイクル。同じ line を読み直しても延長しない。`dcache.veryl:621-638`)。
- `STORE_EXCL` は試行したサイクルで PASS か FAIL に確定する。所有している hit にサイクルを足してはならない。
- watch (所有者 `atomic_unit`): 要求を受理したサイクルから、対象 line の inv、inv2、evict の各 event を監視する。読み出しから書き込みまでの間に line が離れたら、書き込みを試みない。理由: line がいったん離れてから若い load の fill で E 状態に戻ると、dcache の試行時の所有権検査は PASS してしまい、その間に入った remote の書き込みが失われる。presence ポートの監視 (旧コア) は使わず、event だけで判定する。

【決定】(D8) AMO と SC の書き込みは、op が oldest のまま `LOAD_EXCL` → 計算 → `STORE_EXCL` を続けて行い、PASS してから rd を WB する。AMO の FAIL と watch の発火は、`atomic_unit` の中で読み出しからやり直す (hart id の全 bit を種にした指数 backoff 付き)。SC は reservation が有効なら `STORE_EXCL` を出し、rd は PASS なら 0、FAIL なら 1 とする (偽の失敗は仕様上許される)。理由: atomic の pipeline replay が無くなり、REPLAY の発生源は `lq` だけになる (§5.12 C7)。読み出しから書き込みまでの窓が数サイクルになり、64 サイクルの pin の中に必ず収まる。書き込みは retire より前だが、op は oldest で、例外も起こりえず、`head_started_q` によって割込みも待たせるので (§5.13.1)、アーキ的には retire 時の書き込みと区別できない。

dcache との契約 (ownership read、pin、MP6、watch) と queued atomic (ASQ) という旧方式の中身は変わらず、変わるのは書き込みの時点だけであり、D5 の「既存方式のまま」はこの範囲で読み替える (D8。旧方式を採らなかった経緯は付録 §L)。

- LR: `LOAD_EXCL` が HIT したら reservation を張り (L.12)、rd を WB する。書き込みは無い。
- amocas.w/d/q: 比較値は上の【決定】のとおり `atomic_unit` が arch RAT と PRF から読む (旧コアの `arch_regs` の shadow は持たない)。amocas.q は 16 B 境界に整列している必要があり (整列していなければ misaligned AMO として access fault)、`LOAD_EXCL` と `STORE_EXCL` に 2 dword の mask と 128 bit の data を使う。line は跨がない。rd の対をどう書くかは §5.5 の【M2 で決定】に従う。
- AMO の演算 (swap/add/xor/and/or/min/max/minu/maxu、Zabha の幅) は `atomic_unit` の中の関数 1 つで行う。旧コアは execute 側と ASQ の drain 側に同じ演算を 2 つ持っていた (`heliodor_core.veryl:10958-10991`)。
- 不変条件 (所有者 `atomic_unit`): FAIL した AMO、watch が発火した AMO、例外を持つ atomic は、rd もメモリも書かない。atomic の分類は decode の op 種別と翻訳時の `PmaAttr` だけから決め、横の latch からは決めない。

queued atomic (ASQ、M4):

- クラス: rd=x0、RMW の funct5 (LR/SC/amocas は除く)、aq 無し、`attr.cacheable && attr.amo == FULL`、例外無し。分類は m1 の翻訳結果で確定するので、旧コアの「uncacheable と分かったら replay する」fallback (`amo_fread_q`) は要らない。
- retire すると、`{pa, op, src, size}` を持って queue (深さ 1) に入る。SQ からの pop と queue への push は同じエッジで行う (L.5 の SQ と SB の関係と同じ不変条件)。若い store は queue が空になるまで retire しない (旧 `asq_st_block`)。若い load のうち重なるものは PARK(AQ) で待つ。`o_ordering_empty` は queue が空であることを含む。
- RMW は `sb.o_drained` の後に `LOAD_EXCL` → `STORE_EXCL` を、watch と backoff 付きで行う。FAIL は内部でやり直す。MP6 の pass/fail があるので、旧コアの 128 サイクルの watchdog と「書き込み完了が同じサイクルの poison に勝つ」という特例 (`heliodor_core.veryl:10898-10931`) は要らない。
- 旧コアの穴の扱い: H1 (aq 付きの queued atomic が younger load を順序づけなかった) は aq をクラスから除いて閉じる。H2/H3 は `ordering_empty` で閉じる (L.10)。backoff の種には hart id の全 bit を使う (旧コアは `HART_ID[1:0]` だけだったため、N=8 では 2 つの hart が同じ系列を使っていた)。
- 【M4 で決定】ASQ クラスを入れるか。旧コアでは `ATOMIC_SQ` の flip が N=4 boot で −4.2 % (N=1 は +0.03 %、N=2 は同一) だった。新コアの N=4 boot でブランチ実験 (あり/なし) を行い、差で判断する。入れない場合、この種の atomic は head での RMW になる。

### L.12 LR/SC の reservation と前進保証

reservation (所有者 `atomic_unit`、1 hart に 1 つ): `{valid, pa (LR の正確な PA), line}`。

- 張る: LR の `LOAD_EXCL` が HIT したとき。line は所有権付きで pin されている。
- SC の成功条件: `valid && SC の PA == reservation.pa` で、かつ `STORE_EXCL` が PASS すること。【決定】アドレスは PA で正確に一致させる。理由: Sail と ACT4 の Zalrsc は正確なアドレス一致を期待しており、旧コアの VA の正確な一致と同じ挙動になる。
- 消す (仕様と旧コアの livelock の教訓に従う): SC の retire (成否にかかわらず)、trap の受付、xRET、その line の inv/inv2/evict の event。【決定】次の場合には消さない: 分岐の mispredict と部分 kill (旧コアでは消したことで read_lock が livelock した。`heliodor_core.veryl:8296-8312`)、REPLAY や CSR 書き込みによる full kill、同じ hart の store (仕様は自 hart の store による失敗を要求しない。旧コアは issue 時に VA が一致すると消していたため、wrong path の store で正しい reservation が消えた)。
- precise invalidation の下では、line が L1 を離れると remote の書き込みは見えなくなる。したがって evict の event で消すことは必須であり、方針として選べるものではない。

前進保証 (N ポートのコアでの論拠):

1. remote 側: LR は所有権付きで読み、64 サイクルの pin が remote の probe を延期する。制約付きの LR/SC ループ (16 命令以下、他のメモリ op 無し) では、SC は D8 により oldest のまま数サイクルで書き込む。`ordering_empty` の待ちも、ループ中に store が無いので生じない。
2. 自 hart の投機: 部分 kill でも自 hart の store でも消えないので、wrong path の op が reservation を壊すことは無い。
3. 自 hart の追い出し: 若い投機 load の fill がその set の victim に reservation の line を選ぶと消える。tree-PLRU の 4-way で MRU の line が victim になるには、その set で 3 回以上の fill が必要であり、N_FILL=1 なら 64 サイクルの窓の中では起こりにくい。しかし M3 以降で MLP を上げると、この論拠は崩れる。
- 【M4 で決定】fill の victim 選択から pin 中の line を除外するか (§M の変更)。`o_perf` の `rsv_lost_evict` (自 hart の追い出しで消えた reservation) と、SC の連続失敗の最大長を、cfg_w4 の N=4 boot と litmus で数えて決める。0 でなければ除外を入れる。
- 【M2 で決定】lockstep での SC の扱い。新コアの SC が失敗するのは、D8 により reservation が失われた場合 (追い出し、inv) か watch が発火した場合だけである。旧コアの SC の成否はマイクロアーキに依存する (追い出し、issue 時の VA 一致による消去)。golden の N=1 boot で SC が失敗した回数を数え、0 なら何もしない。0 でなければ検証計画の allow-list (D4) か、tb による成否の強制で吸収する。

### L.13 io_unit

- 対象: `!attr.cacheable` の load と store。IO (`attr.io_ordered=1`) のほか、M1-M2 では NC (`io_ordered=0`) もここで実行する。
- IO load: LQ に PARK(HEAD) で置かれ、`io_unit` は次の条件がすべて成り立つと HEAD クラスの slot を要求する: oldest token == エントリのタグ、`ordering_empty`、`atomic_unit` が空 (§5.14)。`UNC_READ` (タグは `MemTag{IO, LqTag}`) が受理された edge で `started_q` を立て、`o_started` を出す (§5.13.1。RETRY が返っても retire まで下ろさず、RETRY の後の再要求は token ではなく `started_q` で出す。mem_ctrl は非 DRAM の読み出しを grant のサイクルに行うので、要求を出した時点で副作用が起こりうる)。`PENDING(fill_id)` の後、同じ `fill_id` の `UNC_DONE` の event で data を受け取る。
- IO store: oldest token と `ordering_empty` が成り立ったら、`STORE_WT` を出し、受理 edge で同じく `started_q` を立てる。`WT_DONE` を受けたら `sq.i_wt_done` で SQ エントリの `wt_done` を立てる。retire はその後である (non-posted、§C.2.2 の 4 行目)。旧コアの doorbell 規則 (mailbox への store の後、fence 無しで CLINT の msip を書く。`heliodor_core.veryl:6369-6374`) を `ordering_empty` で満たす。
- 不変条件 (所有者 `io_unit`): 同時に未完了の要求は 1 本だけ。要求を再提示してよいのは RETRY を受けたときだけで、PENDING の後は決して再提示しない。結果は `io_unit` の結果レジスタ 1 本で捕まえ、wbm0 に HOLE_FILL で書く。LQ エントリは完了だけを記録する。
- misaligned アクセス、AMO、LR/SC が IO/NC 領域を指したら、m1 で access fault にする (§5.14)。
- DRAM の PA を指す NC/IO アクセス (Svpbmt): §5.11 の【M2 で決定】の基本線に従う。`io_unit` は uncached アクセスの前に、自 hart の dirty line を `CMO` (clean) 要求で書き戻す。`CMO` クラスの要求者は現時点でこれだけである。
- 【M3 で決定】NC load の投機的な発行 (§5.14) は boot と bench で NC load の発生数を数えて決める。発生数が 0 なら head での発行のまま確定する。

### L.14 mem_port_arb

- 要求者クラスと port の能力 (定数配列 `PORT_CLASSES[p]`。サイズではなく能力の表で、`core_types` が `MEM_W` から導く: port 0 は全クラス、port ≥1 は NEW/LQ/SQ。lane 番号による特例は書かない):

| クラス | 要求者 | port 0 | port ≥1 |
|---|---|---|---|
| NEW | memory IQ の select | ✓ | ✓ |
| LQ | `lq` の再 issue | ✓ | ✓ |
| SQ | `sq` の再 issue | ✓ | ✓ |
| HEAD | `atomic_unit`、`io_unit`、VU (M5)。要求の資格は「token のタグが自分の op と等しい」か「自分の `started_q`」(§5.13.1 IR1)。どちらも最古の op にしか成り立たないので、要求者は互いに排他 | ✓ | |
| PTW | D-`ptw` の `PTW_READ` | ✓ | |
| AD | D-`ptw` と I-`ptw` の A/D 書き込み (`STORE_WT`、M4 からは `LOAD_EXCL`+`STORE_EXCL`)。クラス内は round-robin | ✓ | |
| ASQ | `atomic_unit` の queued atomic (M4) | ✓ | |

- slot: `mem_port_arb[p]` はサイクル t に、登録済みの要求だけから、t+1 の m0 の slot の持ち主を決める (§5.9 MP3)。NEW 以外が勝ったサイクルは、memory IQ が pipe p の select をしない。非 pipe のクラスが勝つと slot token が m0 から m2 へ流れ、token が m2 に達したサイクルに勝者が `MemReq` を出す。応答は `MemTag.client` で振り分ける。pipe の op は自分の段で応答を受ける。
- LQ と SQ の slot は、その op が m2+RESP_LAT で使う wbm_p のサイクルが wb_resv で空いていることを条件とする (memory IQ の select と同じ規則。§5.7)。非 pipe のクラスの token はその WB サイクルを使わないので、そこが HOLE_FILL の空きになる。
- 【決定】全クラスを round-robin にし、絶対優先のクラスは作らない。VU (M5) も HEAD クラスの普通の要求者であり、例外にしない。理由: HEAD に絶対優先を与えると、M5 の VU の要素の連続要求が、VU 自身が必要とする PTW を飢えさせ、デッドロックしうる。待ちの上限は B = (その port のクラス数 − 1) slot、すなわち port 0 で 6、port ≥1 で 2 であり、モジュールのヘッダに書く (MP4)。
- 旧コアでは、1 本の dcache ポートの調停が、要求者ごとの譲歩条件の OR としてファイル全体に散っていた (`heliodor_core.veryl:10651-10676, 10859-10860, 11102-11222`)。排他性が構造で保証されていなかったので、probe P1-P4 が必要だった。新コアではこれを slot の付与 1 つに置き換える。

### L.15 misaligned アクセス (§5.9 MP5)

- line 内の misaligned (隣接 2 dword 以内): 1 回の要求で行う。forward も 1 回の照会で済む。Zama16b の原子性が保たれる。
- line 跨ぎ: m0 で検出し、2 つの pass に分ける。同じ page の中なら hi の line = lo の line + 1 で、翻訳は 1 回で済む。page を跨ぐなら、hi 側を SQ/LQ からの再 issue で別に翻訳し、PMP/PMA を検査する (旧コアは 1 回しか翻訳せず、hi 側を PA+8 に書いていた)。
- store: SQ エントリが lo と hi の 2 つの半分を持つ。retire は両方の半分が翻訳と検査を終えてからなので、どちらの半分も先に書かれることは無い。SB には 2 line を push する (L.9)。
- 【決定】M1-M2 の line 跨ぎの load は、oldest token を持ったときだけ、2 pass で実行する。lo 側の byte は `lq` の split buffer (128 bit、1 本) に置き、hi 側の pass で合成して WB する。理由: LQ の各エントリに data を持たせずに済む。line を跨ぐアクセスは原子的でなくてよい (granule = 64)。【M3 で決定】投機的に実行するかは、boot と bench で line 跨ぎの load の比率を数えて決める。
- 例外: misaligned atomic は翻訳の前に access fault (cause 5/7) とする (Sail の順序。旧 `heliodor_core.veryl:7939-7952`)。load/store の address-misaligned 例外 (cause 4/6) は出さない。page を跨ぐアクセスの fault の tval は、fault した半分の先頭の VA とする (特権仕様の "portion" の規定)。ACT4 の `sail.json` の設定と M2 で照合する。
- ACT4 の `MISALIGNED_MAX_ATOMICITY_GRANULE_SIZE` は M2 で 64 に下げる (MP5)。

### L.16 Svadu: A/D の更新

- A bit: walk 中の投機的な更新を許す (特権仕様が許している)。
- 【決定】D bit の更新は exact にする。具体的には、store (と AMO/SC) がその命令自身の oldest token を持つときにだけ行う。理由: 仕様は、明示的な store による D の更新が非投機的で、自 hart から program order に見えることを要求している。execute 時に翻訳する新コアでは、これを head の条件で担保するしかない (旧コアは commit 時に翻訳していたので、自然に満たしていた)。
- 流れ: m1 で ADUE=1 かつ D=0 と分かった store (atomic を含む。atomic も SQ エントリを持つ) は、SQ に PARK(DBIT) として置かれ、アドレス未知の store として扱われる (若い load はこれを追い越して投機し、後の scan が守る)。oldest token が自分のタグに等しくなったら `sq` が再 issue し、m1 が `nonspec=1` の walk を要求する。`ptw` の要求キューがその要求を受理した edge で、その受理サイクルの token がまだ自分のタグに等しければ、`sq` は `started_q` を立てて `o_started` を出す (§5.13.1 の開始点。token を失っていたら `nonspec` を付けずに PARK(DBIT) に戻る)。`ptw` が AD クラスで PTE を書き、TLB に install して owner に応答する。その後の STA を完了させる再 issue は token ではなく `started_q` で出す。m1 で既に token を持っていた store も、同じく受理 edge の照合を通る。
- ADUE=0 (Svade) で A=0 か D=0 なら、m1 で page fault を記録し、commit で precise に trap する。AMO は W と D の権限で翻訳する (旧コアは AMO の W/D の検査を逃していた。`heliodor_core.veryl:8733-8736`、`mmu.veryl:584-594`、検証計画付録 B の B10)。

### L.17 構造サイズ (初期値) と、それを決める census

| 定数 | 所有者 | cfg_w2 / cfg_w4 | 状態 | 決め方 |
|---|---|---|---|---|
| `LQ_N` | `lq` | 32 / 64 | 【M3 で決定】 | LQ の占有ヒストグラムと、「LQ 予算で dispatch の group を切ったサイクル数」(`o_perf.ds_cut_lq`) を、各構成の boot、coremark、memcpy で測り、IPC 曲線の膝を選ぶ。旧コアの LQ の high-water は ROB 32 で boot 16、suite 8 だった。 |
| `SQ_N` | `sq` | 16 / 32 | 【M3 で決定】 | 旧コアには「in-flight の store 数」の census が存在しない (ROB の index で store を持っていたため)。M3 で初めて、SQ の占有ヒストグラムと `ds_cut_sq` を同じ負荷で測る。memcpy と boot の store の密度が上限を決める。 |
| `SB_N` | `sb` | 4 / 8 | 【M3 で決定】、N=4 での確認は M4 | 旧コアの N=1 boot の値: 2 本目の line が待つ 9.96 %、3 本目 3.39 %、SB 満杯 1.03 %。N=4 での SB の占有は未測定 (watermark が存在したのは、N=4 で drain が飢えたため)。M3 で N=1、M4 で N=4 の boot について、占有ヒストグラム、SB 満杯による retire の停止、drain の最大待ちを測る。 |
| `REISSUE_W` (`core_cfg`) | `lq` | 1 / 1 | 【M3 で決定】 | L.7 |

占有数は `o_perf` に値として出し、tb がヒストグラムにする (§5.15)。

### L.18 マイルストーンごとの出荷範囲

| M | §L が出荷するもの |
|---|---|
| M1b | `mem_pipe` (m0-m2+RESP_LAT、Bare の翻訳経路、PMP/PMA)、`lq` (credit、store-resolve scan、PARK(FILL/BUSY/SQ/HEAD)、再 issue、commit 窓の poison、`ld_barrier` の通し番号、kill)、`sq` (STA/STD ポート、一括 issue)、`sb` (PUSH_W ポート、write-combining、drain、3 つの empty)、`mem_port_arb` (NEW/LQ/SQ)、PA キーの forward、FENCE/FENCE.I の順序、line 内と line 跨ぎの misaligned (rv64ui の ma_data)。cfg_w4 は MEM_W=2 で elaborate でき、論理ポートの衝突は負けた側の `RETRY(BANK_CONFLICT)` になる。 |
| M2 | `atomic_unit` (AMO/LR/SC/amocas/Zabha、watch、reservation、started latch)、`io_unit` (IO/NC、DRAM 上の Svpbmt と CMO clean)、`tlb`/`ptw` と Sv39 の TLB miss の park (PARK(XLATE)) と D-PTW (PTW クラス)、Svadu (AD クラスは `STORE_WT`)、cbo.*、PMA/PMP の fault、IO/AMO の misaligned fault、CoRR scan (N=1 でも追い出しで発火する)。gate は arch suite、ACT4、5.15 N=1 の lockstep。 |
| M3 | 2 ポートの dcache で MEM_W=2 を実働させる。port ごとの forward と scan、複数 lane からの store retire、STA/STD 分離の判定、REISSUE_W、サイズの sweep、NC の投機の判定、line 跨ぎ load の投機の判定、`LD_LAT` の圧縮の判定、replay コストの測定。 |
| M4 | コヒーレンスの下での CoRR、reservation、watch の検証 (litmus N=2/4、N=2/4 boot。メモリ系の変更には N=4 boot を必須とする)。ASQ の判定、AD クラスを所有権付き RMW に変える、victim 除外の判定、drain の飢餓の確認、`wt_fires` の directed test。 |
| M5 | VU を mem_pipe 0 の issue slot の client (HEAD クラス、forward と整形なし、128 bit の生の応答) として接続し、vector store を `sb.i_vu_push` で `sb` に入れる (§V、§5.9)。HLV/HSV、VU の IO アクセスの判定 (§5.14)。 |

### L.19 アルゴリズムの移植元 (旧コア `b0f4668`)

| アルゴリズム | 旧コアの位置 | 新コアでの変更 |
|---|---|---|
| 年齢順の LQ、store-resolve scan | `load_queue.veryl:244-289, 351-385` | PA で正確に比較する。page offset の近似と page を跨ぐ包括判定を捨てる。scan の時刻規則によって同じサイクルの畳み込みを不要にする。 |
| CoRR line scan | `load_queue.veryl:534-557`、入力 `heliodor_core.veryl:6832-6839` | `SMP_COHERENT` の条件を捨て、常に有効にする。 |
| byte ごとの最若選択の forward 木 | `heliodor_core.veryl:7991-8127` (`pick_youngest_fwd` は 8053)、SB 側は 10042-10260 | VA と PA の 2 つの網を、PA キーの 1 つの網に置き換える。 |
| SB の write-combining | `heliodor_core.veryl:9806-9825, 9883-9965` | 循環バッファ、PUSH_W ポートでの in-order merge。 |
| drain shadow、`sb_empty_eff` | `heliodor_core.veryl:9967-10040` (理由は 1009-1024) | 長さを `FWD_SKEW` から導き、出力を 3 つに分ける。 |
| drain ポート、urgency | `heliodor_core.veryl:9957-9965, 10715-10738` | watermark を `SB_N-1` から導く。load の issue は止めない。 |
| commit 時の replay | `heliodor_core.veryl:6303-6325, 7729-7752` | load だけに使う (D8)。 |
| ASQ (クラス、queue、drain) | `heliodor_core.veryl:1028-1090, 6390-6401, 10803-11003` | aq を除外する。pass/fail で watchdog を不要にする。オペランドは op が運ぶ。 |
| reservation、SC watch、AMO watch | `heliodor_core.veryl:8200-8361, 8363-8407, 8408-8447` | PA で正確に比較し、event で監視する。age gate は head での実行で不要になる。 |
| misaligned atomic の fault | `heliodor_core.veryl:7939-7952` | そのまま。 |
| AGU と pointer masking | `heliodor_core.veryl:7893-7920` (と `alu_wrap.veryl:219-229`) | 3 つあったコピーを pipe ごとに 1 つにする。 |
| fill の帰属 (line と dword) | `heliodor_core.veryl:11999-12014` | `fill_id` による照合に置き換える (§5.9 MP2)。 |
| load の整形 | `lsu.veryl` | 関数として移植する。 |
| MMIO store の doorbell 順序 | `heliodor_core.veryl:6369-6374, 9779-9793` | `ordering_empty` で満たす。 |

旧コアの DEAD な fallback (`LQ_REAL=0`、ROB の `sh_load_*` scan、`SQ_RETRY`、`FWD_PA`、`S15_SELF_SCAN`) は golden の挙動に含まれないので、移植しない。

### L.20 checker と発火カウンタ

- `chk_lsq` (観測専用、§5.15): LQ/SQ の各エントリの rob タグが ROB で生きていること。walk の fault 応答が、PARK(XLATE) で生きているエントリにだけ届くこと。SB への push が retire した store に限られること。HEAD クラスの要求が oldest token を持たない op から出ていないこと。`io_unit` の未完了の要求が 2 本以上にならないこと。`resource_empty` を順序の待ちに使っていないこと (`ordering_empty` の消費者一覧と照合する)。
- 発火カウンタ (`o_perf`): forward (全 byte、部分、WAIT)、store-resolve の poison、CoRR の poison (inv と evict 別)、REPLAY、park の理由別、RETRY の理由別、再 issue、SB の merge と満杯、drain の urgent、`ordering_empty` の待ち、EXCL_FAIL、watch の発火、reservation が消えた理由別 (`rsv_lost_evict` を含む)、IO の読み書き、D bit の head 更新、line 跨ぎ、AD 書き込み。どれも少なくとも 1 つの gate で 0 より大きくなければならない。ACT4 と litmus だけで発火するもの (EXCL_FAIL など) は、そのゲートを明記する。
- directed test (自己検査型、golden とは比べない): 特殊アクセスの順序 (L.10 の表の各行)、IO 群 (claim の読み出し回数、wrong path の claim、UART の THR/RBR の同じ offset、misaligned IO の fault。検証計画 §8)。aq 付きの queued atomic の litmus 形 (H1)。page を跨ぐ misaligned store の fault。

---

## §M dcache/MMU の CPU 側・TLB・PTW・PMP/PMA

本章は、メモリポートの CPU 側 (§5.9 の型を実装する側)、翻訳 (`tlb`, `ptw`)、保護 (`pmp_check`, PMA の評価点) を定める。要求者側 (`mem_pipe`, `lq`, `sq`, `sb`, `atomic_unit`, `io_unit`, `mem_port_arb`) は §L、icache の CPU ポートと `ifu` は §F、L2 以下と SoC は §S が扱う。§5.9-§5.11 の契約は再掲せず、その実装と、契約が §M に委ねた決定だけを書く。旧コアの行番号は `b0f4668` のもの。

前半 (M.1-M.6) は dcache の CPU 側と L1/L2 の境界、後半 (M.7-M.12) は MMU、M.13 は両者に共通の検査である (§M が防ぐバグ類は付録 §M)。

### M.1 マイルストーンごとの範囲

| 項目 | M1b | M2 | M3 | M4 | M5 |
|---|---|---|---|---|---|
| dcache CPU 側 | `dcache_port_adapter` (論理 `MEM_W` ポート、物理 1 経路) | 同左 | 2 ポートに再構築 (bank 化、ポートごとの tag lookup、`fill_id = {index, 世代}` の MSHR file の構造、`MSHR_N=1`)。N=1 のゲート (M.6) | 新コアの N=4 boot ができた後に `MSHR_N` を増やす (各コミットを N=4 boot でゲート) | VU の要素アクセス (§V) |
| 再利用 dcache への変更 | 追加 export E1/E3/E5 (M.2.2) | 同左 | `src/v14/v14_dcache` を凍結して本体を改造 (§4.4) | | |
| `tlb` | (無し。Bare の翻訳を `mem_pipe`/`ifu` の m1/f1 で行う) | V=0、`LOOKUP_PORTS=MEM_W`、`ENTRIES` = `DTLB_N`/`ITLB_N` | DTLB 2 lookup ポートの実働、`ENTRIES` と ptw キュー深さの sweep | | V=1 エントリ |
| `ptw` (D, I) | (無し) | V=0 Sv39 (Svade、Svnapot、Svpbmt、PTE の PMP/PMA)、Svadu (A/D は STORE_WT) | | A/D を owned RMW に | 二段翻訳 |
| PMP/PMA | ポートごとに評価 | PMP 端点検査の要否 (M.10) | | | guest PBMT |
| 主なゲート | rv64ui trace (Bare, U-mode) | `tb/test_mmu.veryl` を載せ替えた unit test、arch (rv64si を含む)、ACT4 の Sv 系、5.15 N=1 lockstep | 両構成の N=1 の梯子 (M.6.1。新コアの SMP は M4 から) | litmus N=2/N=4、新コアの N=2/N=4 boot | hvlinux |

【決定】`tlb` と `ptw` は M2 で最終形の module として入れる。M1b の `mem_pipe` と `ifu` は Bare の翻訳 (PA = VA、`pma_check`、`pmp_check`) だけを持つ。理由: rv64ui は Bare の U-mode で走るので、M1b のゲートは `tlb`/`ptw` を動かさない (§2.5 の M1 分割)。§L の状態機械を作り直さずに済むのは、翻訳待ちの状態 (PARK(XLATE)、`XlateReq`/`XlateResp`/`PtwEvent` の型、§5.10 X2 の同サイクル規則) を本書が最初から定めているからで、M2 で足すのは遷移と module であり状態の形ではない。

### M.2 `dcache_port_adapter` (M1-M2)

#### M.2.1 構造

- 再利用 dcache の主ポート (`i_addr`/`i_ren` と修飾入力) と Stage-A 折り返し (`i_addr_r`/`i_ren_r`/`i_ren_folded`) を駆動するのは adapter だけである。drain ポート (`i_saddr`/`i_swen`/`i_swdata`/`i_swstrb`/`i_sdrain_urgent` → `o_sdrain_ack`) は `sb` が直接駆動し、adapter は触らない (MP7)。第 2 hit ポート (`i_addr2`) と hi-dword 系 (`i_wstrb_hi`、misaligned 書き込み) は 0 に固定する (MP5)。
- 物理経路は 1 本で、位置が 2 つある。A 位置は、受理したサイクルに Stage A を提示する要求で、1 サイクルだけ存在する。B 位置 (`slot`) は、主ポートを駆動している要求である。`slot` は M1 の 1 エントリ MSHR を兼ねる (§5.9)。1 サイクルに物理経路へ入る要求は 1 つだけ。
- 論理ポートは `MEM_W` 本で、`o_ready[p]` は登録済みの定数 1 とする。物理経路に入れなかった要求には、理由を問わず RETRY(BANK_CONFLICT) を返す。1 bank の adapter では、経路が塞がっていることが bank 衝突に当たる (§3.2)。

```veryl
module dcache_port_adapter::<CFG: core_cfg> (
    i_kill         : input  Kill,
    i_req_valid    : input  logic   [CFG::MEM_W], i_req: input MemReq [CFG::MEM_W],
    o_req_ready    : output logic   [CFG::MEM_W],   // registered constant 1
    o_resp         : output MemResp [CFG::MEM_W],   // registered, RESP_LAT cycles after accept
    o_evt          : output MemEvent,               // registered, one per cycle
    i_p0_resv_next : input  logic,                  // mem_port_arb: port 0 reserved for a non-pipe client next cycle
    // to the reused dcache: main port + Stage-A fold + qualifiers; E1/E3/E5 and fill outputs back
);
```

- 要求クラスは主ポートの使い方で 2 群に分かれる。

| 群 | クラス | 主ポートの使い方 | 判定サイクル |
|---|---|---|---|
| fold 群 | LOAD (1 line 内の 1-2 dword)、PTW_READ | A で `i_addr_r`/`i_ren_r`、A+1 で `i_addr`/`i_ren`/`i_ren_folded=1` | V = A+1 |
| nf 群 | LOAD_EXCL | A で `i_addr`/`i_ren`/`i_amo_read` (2 dword は `i_load_next`) | V = A+1 (nf の登録読み) |
| nf 群 | STORE_EXCL | A で `i_wen`/`i_wen_excl` (2 dword は `i_wen_excl_q` と `i_wdata_hi`) | A |
| nf 群 | STORE_WT | A から `i_wen`/`i_wstrb`/`i_wdata` | 書き込みが fire したサイクル |
| nf 群 | UNC_READ | A から `i_addr`/`i_ren`/`i_uncached` | grant のサイクル |
| (下記) | CMO (`io_unit` の自 line clean だけ) | 下記 | A |

- 【決定】nf 群は、受理サイクルに B 位置が空いているときだけ物理経路に入れる。A-1 に受理した fold 群の要求が A で `i_addr` を使うからである。nf 群の要求者はすべて port 0 の非 pipe client (`atomic_unit`, `io_unit`, A/D 書き込み) で、`mem_port_arb` が 1 サイクル前に port 0 を予約する (MP3)。adapter はこの予約を `i_p0_resv_next` として受ける。これは nf 群の要求が受理されるサイクル A (slot token が m2 に達するサイクル) の 1 サイクル前 (A-1) に立つ登録済みの信号で、`mem_port_arb` の決定を token と一緒に運んで作る (§5.9 MP3)。adapter は A-1 に全論理ポートの fold 群を RETRY(BANK_CONFLICT) にして、A に B 位置を空ける。これで nf 群の待ちは「保持中の slot の解放」だけで有界になる。fold 群を 1 つ捨てるが、nf 群は稀である。
- 【決定】2 dword の LOAD も fold 群に入れ、上位 dword は新しい export E5 から取る。理由: nf 群にすると B 位置の空きを要し、hit が毎サイクル続く間 misaligned load が RETRY を受け続けて飢餓しうる。旧コアの ma_data の事故は、lo を登録済み line から、hi を live 読みから取った混在が原因だった。両方を同じ登録済み line から取れば起きない。
- 【決定】cbo.clean/flush/inval の命令は dcache に要求を出さない (§5.5、§5.9)。翻訳と権限検査だけを行い、retire は no-op である。理由: プラットフォーム上の全エージェントが coherent であり (DMA 無し、L2 は inclusive)、旧コアも PMP 検査だけの NOP として扱っている (`heliodor_core.veryl:8797`)。cbo.zero は `sb` の全 line store である (§L)。
- CMO クラスの要求者は `io_unit` だけで、uncached な DRAM アクセスの前に自 hart の line を clean する (§5.11 の M2 基本線、§L L.13)。adapter はこれを、§5.11 の【M2 で決定】で clean が要ると判定されるまでは受理と同時の HIT として扱い、要ると判定されたら UNC 系の要求の前段の clean として実装する (再利用 dcache への入力追加。v14 は 0 に固定)。

#### M.2.2 再利用 dcache への追加 export

いずれも既存の内部信号を出力ポートに出すだけで、v14 コアは未接続にする。受入条件は §4.4 のビット一致。

| ID | 出力 | 中身 (既存信号) | 用途 |
|---|---|---|---|
| E1 | `o_fill_start`, `o_fill_start_line`, `o_fill_start_off`, `o_fill_start_rfo` | `fill_start_fire` (`dcache.veryl:1137`) と、そのサイクルにエントリへ latch される `{f_tag, f_index}`, `f_offset`, `f_rfo` | FILL_START、`fill_id` の採番、slot の解放判定 |
| E1 | `o_fill_busy`, `o_fill_line`, `o_fill_off` | `state` が FILL か DONE、`m_tag_q`/`m_index_q`/`m_off_q` | attach と FILL_BUSY の判定、FILL_CRIT/DONE/ABORT の line |
| E3 | `o_stall_terms` (struct) | `o_stall` の項を分解したもの (`:3304-3305`): `dhit_miss`, `nf_gap_stall`, `nf_reg_stall`, `miss`, `dhit_c3_squash`, `dhit_cap_pre_q`, `inv_hits_active \|\| inv2_hits_active`, `write_wait_grant`, `write_during_fill`, `write_wait_local`, `uncached_active && !i_memr_grant`。加えて実際の発火信号 `wenl_fires` (`:1597`) と `wen_fires` | 判定表 (M.2.3) |
| E5 | `o_dhit_used`, `o_dhit_rdata_next` | `dhit_use` (`:1277`) と、折り返し読みの登録済み line (`dhit_way` の way) の dword `dhit_off_q + 1` | 1 line 内 2 dword の fold LOAD |

- store-RFO を含む全 fill を E1 で見るので、旧コアの `fill_busy_q` の盲点 (RFO fill が見えず、boot の 8.7 % を誤ラベルした) は起きない。`o_miss_valid` と `o_miss_offset` は使わない。fill の帰属は E1 の latch 値だけで決め、ポートを誰が駆動しているかは見ない。
- 排他書き込みの FAIL は E3 の `write_wait_local` で判定し、adapter が要求を取り下げる。dcache に fail 出力を足す必要は無い。

#### M.2.3 判定表

fold 群と LOAD_EXCL は、判定サイクル V に次の行を上から評価する。応答は V の値を登録して A+2 に出す (`RESP_LAT=2`)。

| 行 | 条件 (V の値) | 応答 | slot |
|---|---|---|---|
| 1 | `MemTag.rob` が有効で `killed()` が真 (M.2.6) | RETRY(PREEMPTED) | 解放 |
| 2 | E3 の inv 競合、`dhit_c3_squash`、`dhit_cap_pre_q` | RETRY(INV_RACE) | 解放 |
| 3 | `!o_stall && o_data_valid` (2 dword の要求はさらに `o_dhit_used`) | HIT (`o_rdata`。2 dword なら E5 を上位に) | 解放 |
| 4 | `o_fill_busy`、`o_fill_line` = slot の line、1 dword の要求で `o_fill_off` = slot の dword、`o_fill_data_ready` | HIT (`o_fill_rdata`) | 解放 |
| 5 | `o_fill_busy`、`o_fill_line` = slot の line | MISS(`fill_id_q`) (attach) | LOAD_EXCL は保持、他は解放 |
| 6 | `o_fill_busy` (別の line) | RETRY(FILL_BUSY) | 解放 |
| 7 | 上のいずれでもなく、過渡的な stall の項 (`dhit_miss`/`nf_gap_stall`/`nf_reg_stall`) | MISS(`gen_q`) | 保持 (HOLD, M.2.4)。fill を伴わずに hit で終わったら空の世代の FILL_ABORT を出す |
| 8 | 上のいずれでもなく `miss` (slot の line と dword に対する本物の miss) | MISS(`gen_q`) | 保持 (HOLD, M.2.4) |

- 行 4 は、旧コアの MSHR owner が使っていた critical-word 早期完了 (`o_fill_data_ready`/`o_fill_rdata`, `dcache.veryl:2908-2917, 2990`) であり、新しい組み合わせではない。これにより、FILL_CRIT を受けた要求者の再 issue (MP2) が fill の途中で完了する。中断が早期完了の後に来ることは正当な順序である。
- hit-under-fill (FILL 中の別 set への hit を `o_hit_safe` で返すこと) は M1-M2 ではしない。理由: 出荷形の LSR は `!o_stall` でしか完了しておらず、`o_hit_safe` を使う折り返し hit はどのゲートも通っていない組み合わせである。M3 の再構築で既定の経路にする (M.6.5)。
- 書き込みと uncached の判定:

| クラス | 条件 | 応答と処置 |
|---|---|---|
| STORE_EXCL | A で `wenl_fires` | EXCL_PASS。merge は A の edge で入る (MP6) |
| STORE_EXCL | A で `write_wait_local` | EXCL_FAIL。A+1 で `i_wen` を落とす |
| STORE_EXCL | A で `o_fill_busy` (上の 2 つはどちらも `m_arr_free` を要するので、3 行で排他かつ網羅) | RETRY(FILL_BUSY) |
| STORE_WT | 常に | PENDING(id)。`wen_fires` のサイクルに slot を解放して WT_DONE(id) |
| UNC_READ | 常に | PENDING(id)。`i_memr_grant` のサイクルに `o_rdata` を捕捉し、次のサイクルに `i_ren` を落として UNC_DONE(id, data)。デバイスの読み出しは 1 回だけ起こる |

- adapter が `i_wen` を出している間は `sb` の drain がすべて止まる (`store_can_drain` は `!i_wen` を要する, `dcache.veryl:1414`)。`i_wen` を出すのは STORE_EXCL の A と STORE_WT の保持中だけで、どちらも有界である。
- 再利用 dcache は、UNC_READ と drain RFO の間で read channel の grant を調停しない。§5.14 により UNC_READ は `sb.ordering_empty` の下でしか出ないので、両者は重ならない。checker が「UNC_READ の保持中に `o_fill_start`」を検査する。

#### M.2.4 HOLD の終わり方

【決定】過渡的な場合 (行 7) も MISS で保持する。保持した slot が fill を伴わずに hit で終わったときは、adapter が `gen_q` を 1 つ進めてその世代の `FILL_ABORT` を出し (空の世代)、park した要求者を再 issue させる。理由: `dhit_miss` は折り返し経路での本物の miss の最初のサイクルでもあり (`dcache.veryl:1278-1286`。`miss_q` は 1 サイクル遅れて立つ)、ここで RETRY すると再 issue のたびに同じ項に当たって fill に到達しない。

行 8 の slot は、V+1 からは非折り返し (`i_ren_folded=0`) で同じ要求を毎サイクル提示し続け、次のいずれかで終わる (上が優先)。この表は V 自身でも評価する。V に別の line の fill が始まると、約束した `gen_q` はその fill に使われるからである。

| 事象 | 処置 | 要求者への通知 |
|---|---|---|
| `o_fill_start` で start line = slot の line | 自分の fill (または同じ line の RFO fill)。LOAD_EXCL 以外は解放 | 約束した `gen_q` を id とする FILL_START/CRIT/DONE/ABORT |
| `o_fill_start` で別の line | 黙って解放 | 約束した `gen_q` はその fill の id になるので、その DONE/ABORT で再 issue する |
| 要求が `killed()` で選ばれた (M.2.6) | 黙って解放 | 無し (要求者は死んでいる) |

- 【決定】LOAD_EXCL の slot は、自分の fill の DONE (または ABORT) まで `i_amo_read` 付きで保持する。理由: RFO fill 完了時の ownership pin は `pin_arm_fill = DONE && fill_rfo && i_amo_read` (`dcache.veryl:1602`) なので、DONE に AMO 読みが提示されていなければ張られない。pin が無いと、DONE から `atomic_unit` の再 issue までの間に remote recall が line を奪い、競合する atomic が livelock しうる (`:1297-1302` と同じ事故類)。`atomic_unit` は、FILL_DONE から pin の窓 (64 サイクル) 以内に LOAD_EXCL を再 issue する義務を負う。
- 不変条件 (所有者 adapter、checker で検査): 要求者が生きている MISS(g) と PENDING(g) には、ちょうど 1 つの終端イベント (FILL_DONE/FILL_ABORT、または UNC_DONE/WT_DONE) が有界時間内に続く。

例 (単一の論理ポート。R1 と R2 は同じ set の別 line、R0 は hit):

| サイクル | A 位置 (`i_addr_r`) | B 位置 (`i_addr`) | dcache | adapter の判定 | 出力 |
|---|---|---|---|---|---|
| t | R0 | | | | |
| t+1 | R1 | R0 (`i_ren_folded`) | R0 hit | R0: 行 3、解放。同じサイクルに R1 を A に入れる (back-to-back) | |
| t+2 | (R2 は経路に入れない) | R1 | `miss` | R1: 行 8、MISS(`gen_q`=g)、HOLD。R2 は RETRY(BANK_CONFLICT) | R0 HIT |
| t+3 | | R1 (非折り返し) | `o_fill_start`、line = R1 | R1: 自分の fill なので解放 | R1 MISS(g) |
| t+4 | | | FILL | | FILL_START(g)、R2 RETRY(BANK_CONFLICT) |
| t+5 | R2 (再 issue) | | FILL | | |
| t+6 | | R2 | FILL | R2: 行 6 | |
| t+7 | | | FILL | | R2 RETRY(FILL_BUSY) |
| DONE の次 | | | | | FILL_DONE(g): R1 と R2 が再 issue |

#### M.2.5 `fill_id` と MemEvent

- `gen_q` (adapter が持つ `FillId`) は、`o_fill_start` のサイクルと、行 7 の slot が fill を伴わずに hit で終わったサイクル (空の世代、`FILL_ABORT` を出す) にだけ 1 つ進む。fill の開始時に `fill_id_q := gen_q` を latch する。
- MISS(g) は「次に開始する fill の id」を約束するだけで、その fill が自分の line である必要はない。別の line なら再 issue が 1 回増えるだけである。行 8 の `miss` は dcache の fill FSM を起動するので、次の fill の開始は有界時間内に必ず来る。fill を伴わない hit で HOLD が終わる場合は行 7 に分けたので、HOLD 中に「fill なしの hit」が観測されたら checker が flag を立てる。
- PENDING の id は FILL 系とは別の空間として扱い、要求者はイベント種別で区別する (`io_unit` と A/D 書き込みの client は UNC_DONE/WT_DONE だけを見る)。adapter では PENDING は同時に高々 1 つなので、値は `gen_q` をそのまま使い、進めない。

| EvKind | 発生条件 | fill_id | line / crit / data |
|---|---|---|---|
| FILL_START | `o_fill_start` (RFO と持ち主の無い fill を含む全 fill) | `gen_q` | E1 の start 値 |
| FILL_CRIT | `o_fill_data_ready` の立ち上がり | `fill_id_q` | `o_fill_line`, `o_fill_off`, `o_fill_rdata` |
| FILL_DONE | `o_fill_complete` | `fill_id_q` | `o_fill_line` |
| FILL_ABORT | `o_fill_aborted` | `fill_id_q` | `o_fill_line` |
| UNC_DONE | UNC_READ の grant | PENDING の id | data = `o_rdata` |
| WT_DONE | STORE_WT の書き込みが fire | PENDING の id | |

- 【決定】MemEvent は、それを生む dcache の状態から 1 サイクル登録して出す。応答も判定サイクルから登録して出すので、判定に関わるイベントが応答より前に出ることはない。要求者は、応答と同じサイクルに来たイベントを「その応答の後に起きたもの」として扱う (要求者の義務。§L)。理由: DONE のサイクルに attach や FILL_BUSY と判定された要求が、その DONE を取りこぼして永久に待つことを防ぐ。
- MemEvent は 1 サイクルに 1 つである。dcache 起源の FILL_* は互いに同じサイクルに起きない。WT_DONE だけは FILL_START と同じサイクルに起きうる (read channel と write channel は独立) ので、1 エントリの skid に入れ、dcache 起源のイベントが無い最初のサイクルに出す。

#### M.2.6 kill、論理ポートの調停、公表定数

- `i_kill: Kill` を持つ (§5.15)。kill は `MemTag.rob` が有効な要求に `killed(kill, tag.rob)` で適用する (§5.9)。LQ 用の別 helper は持たない。PTW_READ と AD の要求は walker 自身の要求として `rob` を無効にして出すので取り消されない (walk は owner が死んでも続く、X2)。ATOMIC と IO の要求は started latch を立てた op のものであり、§5.13.1 IR4 によりその op は自分の retire か trap 以外の kill に選ばれないので、adapter がそれらを取り消すことは無い (選ばれたら checker が flag を立てる)。
- 取り消せるのは fill の開始前だけである (§5.9)。fill 開始後も保持する slot は LOAD_EXCL だけで、これは kill されない。
- `MEM_W=2`: 両方の論理ポートが同じサイクルに有効なら、1 本だけが物理経路に入る。`mem_port_arb` が port 0 に非 pipe client の予約 (登録済み) を出していれば port 0 が勝つ。そうでなければ `MemTag.rob` が `older()` で古い方が勝つ (port ≥1 には LOAD しか来ないので、比べる両方が有効な RobTag を持つ)。負けた側は、port 0 であっても RETRY(BANK_CONFLICT) を受ける。【決定】age で決め、toggle は使わない。理由: 最古の load が衝突に負けないことが、再 issue を特定の pipe に回さずに前進を保証する論拠になる (§L.7)。
- 公表定数 (`fu_pkg` に置く。§5.3 R6 の「経路のレイテンシ定数」):

| 定数 | 値 | 定義 |
|---|---|---|
| `RESP_LAT` | 2 | 受理サイクル A から応答まで。【M1b で決定】adapter の実装で、応答が登録済みであり、要求者へ組合せ経路が戻らないことを確かめて確定する (MP1)。 |
| `SNAP_OFS` | 0 | A から data array の snapshot (登録読み) までの距離。HIT のデータは常に A の edge で登録された line から来る。`sb` の drain shadow の長さ (MP7) は、これと `mem_pipe` の forward 判定段から導く。 |

- shadow が要る具体例: 全 line の write-through drain は local merge をせず、ack の edge で自分の S コピーを落とす。A で登録された古い S line は Stage B で HIT になり、`dhit_c3_squash` は inv ポートしか見ない (`dcache.veryl:2534`)。この load は SB の shadow からの forward でしか正しい値を得られない。
- 発火イベント (`o_perf`): RETRY の理由別、空の世代の FILL_ABORT、HOLD への入り、attach、行 4 の早期完了、fold 群の back-to-back 受理 (A と V の重なり)、nf 群の BANK_CONFLICT。

### M.3 一貫性、presence、invalidate のポート

| ポート | 出所 | 消費者 | 契約 |
|---|---|---|---|
| `i_inv_valid/addr`, `i_inv2_*` | mem_ctrl (§S) | dcache (同じサイクルに適用。fill の abort と、完了サイクルへの畳み込みを含む)、`lq` (CoRR の line scan)、`atomic_unit` (reservation と SC/AMO watch) | 3 者に同じサイクルで届く。gate しない。 |
| `o_evict1_*`, `o_evict2_*` | dcache (fill victim、probe、全 line WT drain による自 S コピーの廃棄、flush capture) | `lq`, `atomic_unit` | 旧コアの `SMP_COHERENT` による gate は廃止し、常に配線する。 |
| `i_chk_addr`→`o_chk_present`、`chk2`、`chk3` | dcache | `atomic_unit` (reservation、SC watch、AMO watch) | 登録済み状態だけを反映する。消費者は必ず、同じサイクルの inv/inv2/evict との line 比較と組にする。3 本の割り当ては §L。 |
| `i_probe_*` → `o_probe_ack` | mem_ctrl | dcache 内部だけ | pin による defer は 64 サイクル以内。 |
| `i_flush_req` | なし | | 0 に固定。COHERENT_IFETCH=0 の構成は D3 により存在しない。 |

- precise invalidation の下では、L1 を去った line への remote 書き込みはこの hart にパルスを生まない。CoRR と LR/SC の健全性は、退出時 (evict) の poison と、すべての load 経路が同じサイクルの inv を見ることに依存する。adapter では判定表の行 2 がこれを担い、M3 ではポートごとの再検証 (M.6.2) が担う。
- D3 で SoC を 1 つにするので、N=1 でも invalidate が配線される。旧 N=1 SoC は abort-invalidate を捨てていたが、それが安全だったのは「dcache が自分の fill 中に書かない」(`m_arr_free`) からにすぎない。M3 の beat 単位 drain (M.6.6) はこの前提を崩すので、配線の統一はその前提条件である。

### M.4 L1↔L2 / mem_ctrl インタフェース

【決定】L1↔L2 のインタフェースは bit 単位で変えない。対象は D read slot (`o_memr_req/addr/ren/rfo`, `i_memr_grant`, `i_mem_rdata`, `i_fill_excl`)、write channel (`o_memw_*`, `o_memw_wb`)、probe/ack、inv/inv2。理由: N 本の CPU 側ポートは L1 内部の事情であり、mem_ctrl/l2cache/memory_bus を触らずに済む。

- 【決定】D read slot の束は `[N_FILL]` の配列として宣言し、`N_FILL=1` だけを支援する (§3.2, §3.4)。SoC の slot 数は `SPH = N_FILL + 1` (D と I)。
- L1 側の義務 (M1-M2 は再利用 dcache が、M3 以降は再構築した CPU 側が守る):
  - grant は fill の開始と同じサイクルである。開始できない間 (WB buffer に dirty victim、または取りに行く line そのものがある間) は要求を出さない。
  - accept まで要求を保持し続ける。mem_ctrl の 64 サイクル aging (3da1aa2) は、要求が落ちると年齢をリセットする。
  - STREAM の 8 beat では毎サイクル slot の line を提示する。dword は自由に選べる。beat の受理を自分の要求で gate しない (STREAM は `i_hreq` に依存しない、9d9f013)。
  - write channel の属性は要求と同じサイクルに有効にする。posted な write-through は、S を含む自分のコピーを更新する。全 line の write-through drain は自分の S コピーを落とす。
  - probe には WB か ack で答える。defer してよいのは pin の 64 サイクルだけである。
  - uncached 読みは exact-address の 1 beat で、デバイスの read enable は grant のサイクルに 1 回だけ立つ。
  - misaligned の hi-dword バイパス (`o_dmem_wdata_hi`/`o_dmem_wstrb_hi`) は使わない (MP5)。再利用モジュールの該当入力は 0 に固定する。
- `SPH > 2` (`N_FILL ≥ 2`) に必要なもの。M4 で新コアの N=4 boot ができるまでは範囲外で (§2.6)、上げるときは N=4 boot を入口ゲートとする (§2.5、§3.4):
  - mem_ctrl の `o_inst_hart = h as 3` (`mem_ctrl.veryl:1067`) を `h % N_HARTS` に直す。N=1/2/4 でも、番号 `h ≥ N_HARTS` の slot が install すると sharer mask が壊れる。
  - slot の割り当てを (N_HARTS, N_FILL) から生成する (slot-major、D 系を先に)。`inst_sel_h`/`lkc_nin` の `logic<4>` (N_SLOTS ≤ 16) を導出幅にする。lookup と install の選択にも aging を入れる。
  - L1 に、MSHR エントリごとの line buffer を置く。STREAM は back-pressure できず、複数の slot が同じサイクルに流し込むからである。mem_ctrl は同じ line の accept を直列化するので、secondary-miss merge も L1 で行う。
  - store 側の MLP は、`sb` が head 以外の line を提示しない限り増えない。旧コアの測定では、fill 中に別の line を待つ母集団 (load と drain の合計) は boot の 1.26 % で、これが `N_FILL` を増やす利得の上限である。

### M.5 I 側: icache、I read slot、I-PTW

- I read slot (§4.5) の使い手は 3 つある: icache の line fill、I-PTW の PTE 読み、非 cacheable な fetch の 1 beat 読み。【決定】この共有を新モジュール `islot_arb` に置く。理由: 旧コアではこの調停 (`ic_owns`/`is_ptw_q`/`iptw_addr_q`, `heliodor_core.veryl:12215-12312`) が core top に直書きされており、§2.2 M2 (top は配線のみ) に反する。
- `islot_arb` の規則:
  - 優先順位は I-PTW > icache fill > 非 cacheable fetch。fetch は in-order で、翻訳が済まなければ fill も始まらないので、固定優先でも飢餓しない (待ちの上限は walk 1 本分)。
  - accept から 8 beat の終わりまで所有者を latch する。所有者の要求が途中で落ちても (redirect)、beat は所有者に流し続ける。
  - I-PTW の読みは、要求時に PTE アドレスを latch し、8 beat すべてで同じ dword offset を提示する。旧コアでは、読みの途中の redirect が offset を書き換えて PTE を壊した。
  - 非 cacheable fetch は、要求者の属性 (`pma.cacheable=0`) で single-beat 要求として出す。SoC が要求者の属性で legacy grant に回すこと (PM7) が前提で、これは M1a で入れる §S.4 の変更である (SoC は今 I slot を DRAM 固定にしている、`heliodor_soc_smp.veryl:447`)。
  - I-PTW と icache の読みは `i_iread=1` (計数しない coherent 読み、owned なら recall) を使う。自 hart の L1 にある dirty line も recall で見える。SB の中の store は見えないが、sfence は drain を待つ (§5.5) ので問題ない。
- I-PTW の A ビット書き込みは、旧コアの drain ポート借用をやめ、`mem_port_arb` の port 0 に client=AD、STORE_WT として出す (M.8.4)。

### M.6 M3: dcache CPU 側の再構築

#### M.6.1 順序とゲート

【決定】dcache の作業を次の順に行う。新コアの SMP は M4 から存在するので (§2.5)、M3 の作業はすべて N=1 のゲートで検査する。
1. (M3) cfg_w4 (adapter の 2 論理ポートは M1b から、`tlb` の 2 lookup ポートは M2 から elaborate 済み) で、adapter の上のまま両構成の N=1 の梯子を通す。
2. (M3) 旧コアのブランチで N2.2a の livelock の原因を確かめる。候補は、ALLOC→FILL の launch でエントリの line と live ポート由来の `o_miss_offset` が組になること (`dcache.veryl:2898-2907`) である。`MSHR_ALLOC=1` 単独と、それに `o_miss_offset` をエントリ由来に直したものを、それぞれ旧コアの N=4 boot で判定する (hart 0 の retire stream を健全なトレースと diff)。結果は master に残さない。旧コアの N=4 boot は M3 でも回せるので、この手順は新コアの SMP を待たない。
3. (M3) CPU 側を 2 ポートに再構築する: data の bank 化 (M.6.3)、ポートごとの tag lookup (M.6.2)、`fill_id = {index, 世代}` を持つ MSHR file の構造 (M.6.4)。支援する `MSHR_N`/`N_FILL` は 1 のままとし、N=1 のゲート (両構成の梯子、N=1 boot) で検査する。DTLB の 2 lookup ポートもここで実働させる。
4. (M4) 新コアの N=2/N=4 boot を通す。N=4 boot の扱い (D7) は M3 で決め、M4 から適用する。
5. (M4) 新コアの N=4 boot ができた後に限り、`MSHR_N` (と、必要なら `N_FILL`) を 1 より大きくする。そのコミットはすべて新コアの N=4 boot をゲートとする。

理由: 非ブロッキングのポートでは、grant をまだ得ていない miss を保持できるのはエントリだけである。accept aging は要求が保持され続けることを要件とするので、grant 前の確保 (N2.2a の ALLOC と同じ形) は避けられない。N2.2a はこの形で N=1 のビット一致を保ったまま N=4 boot を livelock させ、18 コミットの間露見しなかった (95753c8)。したがって、grant 前の確保が複数エントリで並走しうる構成 (`MSHR_N > 1`) は、N=4 boot が回せるようになるまで出荷しない。`MSHR_N=1` の構造は旧コアの出荷形と同じ並走しか作らないので、N=1 のゲートで足りる。

- 再構築は §4.4 の「追加では済まない変更」に当たる。着手時に `src/v14/v14_dcache` を凍結する。作り直す CPU 側 (ポート、bank の調停、MSHR file) は §2.1 P5a の新規モジュールとして書き、新規モジュールの規則 (knob 0 個、ヘッダ、600 行の目安、cold-reader gate) をすべて適用する。再利用する内部 (fill FSM、tag/data 配列、coherence) は子として残し、P5 で免除する。

#### M.6.2 ポートと tag

- 要求ポートは `MEM_W` 本で、能力は §5.9 の表に従う (port ≥1 は LOAD だけ)。`RESP_LAT=2` と `SNAP_OFS=0` を保つ。
- 【決定】tag 読みは 1 アクセスにつき 1 回、Stage A (受理サイクル) でだけ行う。ポートごとに `dcache_tagbank` を 1 つ持ち、hit/way/excl/dirty を登録する。Stage B では、同じサイクルの inv/inv2/probe/evict/fill install のうち同じ line のものとだけ比較して再検証する。理由: 旧形 (Stage A の C0b と Stage B の live な C0) は 1 ポートに 2 copy を要し、hit と miss で配送経路が 2 つに分かれていた。
- 再検証には自 hart の退出 (evict、全 line WT drain による自 S コピーの廃棄) を含める。旧 `dhit_c3_squash` は inv ポートしか見ていない。
- 時分割で読む snoop 系 (victim、probe、inv×2、presence×3) は、1 つの dual-tag copy と小さな調停器にまとめる。【M3 で決定】必要な copy 数: presence 要求の頻度と probe の頻度を測って決める。

#### M.6.3 data の bank と bank 衝突

- data array を dword interleave の `NB` bank に分ける。bank `b` は、line 内 offset `o` が `o % NB == b` の dword を 4 way 分 (256 bit) 持つ 1R1W SRAM である。way の選択は Stage B で行う。2 dword のアクセスは隣り合う 2 bank を読む。
- 【M3 で決定】`NB` ∈ {2, 4, 8}: cfg_w4 の bench と N=1 boot で、1000 load あたりの RETRY(BANK_CONFLICT) と IPC を sweep して決める (§3.2)。
- 読み側の調停 (bank ごと、Stage A):
  - 同じ line の同じ dword なら、1 回の読みを共有する。
  - それ以外の衝突は、M.2.6 と同じく `MemTag.rob` の古い方を勝者とし、敗者に RETRY(BANK_CONFLICT) を返す。最古の load は負けないので前進は保証される (§L.7)。
  - WB capture は全 bank の読み口を 1 サイクル使う。1 サイクル前に登録済み状態から予約し、そのサイクルの要求には RETRY(PREEMPTED) を返す。
- 書き側 (bank ごとに 1 サイクル 1 書き込み) の優先順位: fill beat (1 bank) > STORE_EXCL/STORE_WT の merge (1-2 bank) > drain merge (strobe のある bank)。fill beat は back-pressure できないので最優先とする。
- 登録読みの write-forward bypass を bank とポートごとに置き、Verilator のゲートを通す。Veryl sim は read-new、Verilator と実 SRAM は read-old であり、bypass が無いと Verilator でだけ boot が止まった (0267094)。
- 【決定】data の複製はしない。理由: 131 Kbit の array の複製は realism 規則 (大きな array は 1R1W/1RW の実在構成で作る) に反する。複製版は bring-up の比較用にブランチで持つだけにする。

#### M.6.4 MSHR file

```veryl
struct MshrEnt {
    st  : MshrSt,     // FREE, WAIT_LAUNCH, FILL, DONE
    line: logic<50>, crit: logic<3>, rfo: logic, way: logic<2>,
    gen : logic<GEN_W>, abort: logic,
}
// FillId = {idx: logic<idx_w(MSHR_N)>, gen: logic<GEN_W>} (section 5.9); the LQ side is unchanged
```

- 確保は、ポートの判定サイクルの miss で行う。同じ line のエントリがあれば attach して、そのエントリの `fill_id` で MISS を返す。空きが無いか、同じ set に有効なエントリがあれば RETRY(FILL_BUSY)。同じ set を拒むのは、victim 選択と way 除外を「1 set に 1 fill」で作るためである。
- launch: WAIT_LAUNCH のエントリが read channel を要求し、grant まで保持する。grant のサイクルに FILL へ移る (grant は fill の開始)。fill 文脈は `N_FILL=1` 個なので、FILL/DONE のエントリは同時に高々 1 つで、launch の順は確保の順とする。
- N2.2a の livelock の候補を、すべて構造で消す:
  - イベント (FILL_START/CRIT/DONE/ABORT) と critical word は、エントリが latch した `{line, crit}` だけから作る。ポート由来のフィールドは使わない。
  - victim は launch のサイクルに、登録済みの PLRU から選ぶ。clean な victim の退出も、同じサイクルに evict イベントを出す (N2.2a では launch 時の退出に evict が出なかった)。
  - 大域の stall は無い。WAIT_LAUNCH のエントリが塞ぐのは、他の miss の確保 (FILL_BUSY) だけである。
  - 旧 `state == IDLE` が持っていた 3 つの意味を分ける: エントリごとの状態、「このサイクルに array の書き込み口が空いている」、「次の read channel の grant の持ち主」。3 つ目は、launch するエントリか uncached 読みのどちらか 1 つを、登録済みの選択で決める。N2.2a で、他人の grant を自分の launch と誤認した事故はこの 3 つ目の混同である。
- 自 hart の probe (`i_probe_self`) は自分の fill を abort しない。他 hart の probe と inv は、WAIT_LAUNCH を含む全エントリの line と比較し、fill 中のエントリに当たれば abort する。
- `MSHR_N` は M3 では 1 とする (M.6.1)。【M4 で決定】`MSHR_N` を 1/2/4 で sweep する (新コアの N=4 boot ができた後、各点を N=4 boot でゲートする)。測定済みの天井 (fill 中に別の line を待つ load は boot の 0.79 %) から見て、IPC の利得は小さい。主な価値は構造 (ポートが miss で塞がらないこと) なので、IPC が下がらない最小値を採る。

#### M.6.5 hit-under-fill

- 【決定】ポートごとの fill-safe hit を既定の hit 経路にする。除外するのは、有効なエントリの set の victim way だけ (way 単位) である。理由: 旧 `dhit_use` は fill 中の set 全体を折り返しから外しており (`dcache.veryl:1277`)、出荷形の LSR は `!o_stall` でしか完了しなかったので、無関係な hit も fill の全期間を待っていた。way 単位の除外は `o_hit_safe` (`:2926-2940`) に既にある。
- fill 中の line への要求: critical dword が到着済みならエントリの critical-word buffer から HIT、それ以外は attach する。

#### M.6.6 store drain と fill の beat 単位調停

- drain ポートは、`sb` 専用の line 幅の書込ポート 1 本のままとする (MP7)。
- 【決定】drain の merge は fill の全期間ではなく beat ごとに調停する。drain が止まるのは次の 3 つの場合だけである: (a) 同じサイクルに同じ bank へ fill beat がある、(b) merge 先が fill 中の victim way である、(c) 同じ set のエントリがそのサイクルに launch する。理由: 旧コアの測定は「fill 全期間の締め出し」のコストを最大 1.7 % とし、beat 単位の調停を釣り合った修正と結論した。非ブロッキングでは fill の重なる時間が伸びるので、効き目は旧コアより大きい。(c) は、ack 済みの drain が同じ set の fill 開始と同じサイクルに重なって消えた事故 (litmus MP 違反、`dcache.veryl:1402-1415`) を防ぐ。
- 所有していない部分 line の drain は RFO (drain ポートから rfo=1 のエントリを確保)、全 line の drain は write-through のままとする (全 line を RFO にしたら boot が 5 倍以上遅くなった、`:701-706`)。

#### M.6.7 その他

- misaligned: 1 要求は 1 line 内の隣接 2 dword まで (MP5)。`i_load_next`、`hi_miss`、xline の直列化、`i_wstrb_hi` は再構築版から無くなる。
- PLRU: 全ポートの hit で更新する。同じ set への同時の更新は、登録済みの toggle で 1 つを採る (PLRU は性能だけに効くので age で決める必要は無い)。victim の選択は launch 時に行う。
- LOAD_EXCL: S hit か miss なら rfo=1 のエントリを確保する。pin は「owned な AMO 読みを受理した最初のサイクル」までに張る (旧 `pin_arm_hit`/`pin_arm_fill` の条件を、ポートの提示ではなくエントリ基準で書き直す)。owned な hit にサイクルを足さない (MP6)。
- UNC_READ: 「grant を受けたら要求を落とす」を dcache の内部で保証する。旧形のように、要求者が `i_ren` を落とす義務を負わない。
- RETRY(WB_BLOCKED) は、確保に dirty victim が要るのに、WB buffer が別の dirty line を持っているときに返す。

#### M.6.8 再構築した CPU 側の不変条件 (所有者 dcache)

- 受理した要求には、ちょうど `RESP_LAT` 後に応答が 1 つ返る。ポートの ready は登録済みの定数 1 で、応答から要求者への組合せ経路は無い。
- MISS(f) を返した要求者が生きていれば、f のエントリは FILL_DONE(f) か FILL_ABORT(f) を必ず出す。WAIT_LAUNCH のエントリは grant まで要求を落とさない。
- どのイベントのフィールドも、エントリの latch 値とエントリ自身の状態からだけ作る。
- 1 set に有効なエントリは高々 1 つ。FILL/DONE のエントリは高々 `N_FILL` 個。
- fill 中の victim way から HIT を返さない。ack した drain は、同じサイクルの fill 開始や probe に負けない (負けるなら ack しない)。
- HIT のデータは受理サイクル A の edge の snapshot であり (`SNAP_OFS=0`)、同じサイクルの書き込みは bypass で含む。

### M.7 `tlb`

```veryl
module tlb #(param ENTRIES: u32, param LOOKUP_PORTS: u32) (
    i_lk  : input  TlbLookup [LOOKUP_PORTS],   // {valid, vpn, asid}; M5 adds {virt, vmid, vs_mode}
    o_lk  : output TlbEntry  [LOOKUP_PORTS],   // combinational: {hit, ppn, level, r, w, x, u, d, g, pbmt, napot}
    i_fill: input  TlbFill,                    // from ptw only; round-robin victim
    i_inv : input  TlbInv,                     // sfence/hfence operands, applied at retire
);
```

- 照合、選択、PA の構成、選択的 flush の述語は `mmu.veryl` から移植する: level ごとの VPN 照合と一致ベクトルの clz による選択木 (`:250-282`)、level による PA の構成 (`:285-292`)、sfence の述語 (`:645-668`)。サイズのリテラル (`[16]`、`logic<4>` の置換ポインタ) は `ENTRIES` から導く。
- lookup は組合せで、副作用を持たない (X4)。登録済みの出力を作るのは `mem_pipe`/`ifu` の段レジスタである。TLB+PMP と順序検査の間には段の境界を置く (旧コアの残る CP は commit + Sv39 TLB + PMP + 順序検査が 1 サイクルにあることだった)。
- 置換は fill ごとの round-robin で、hit では更新しない。理由: 書き手が `ptw` だけになり、`LOOKUP_PORTS` に依存しない。
- 同じサイクルに install と無効化が重なったら、無効化を優先する。
- A=1 のエントリしか入れない (A=0 の leaf は、Svade なら fault、Svadu なら `ptw` が A を立ててから入れる)。W と D は別々に持つ。旧コアは W を `w && d` に畳んでいたため (`mmu.veryl:918-921`)、ADUE=1 で D=0 のエントリに当たった store が D の更新ではなく page fault になっていた。
- 【決定】権限検査は純関数 `xlate_pkg::perm(entry, acc, ctx) -> {ok, need_d, cause}` に置き、`mem_pipe`、`ifu`、`ptw` が共用する。理由: 旧コアにはこの検査の近いコピーが 4 つあった (`mmu.veryl:294-308, 383-388, 1183-1187, 580-595`)。`ctx` (実効特権、SUM、MXR、ASID。M5 で VMID と V) は X1 に従い、lookup 時に CSR から作る。
- インスタンス: DTLB は `LOOKUP_PORTS=MEM_W`、ITLB は `LOOKUP_PORTS=1` (`FETCH_BYTES ≤ 32` の block は 4 KiB の page をまたがない)。`ENTRIES` は core top が instantiate 時に `CFG::DTLB_N`/`CFG::ITLB_N` を束縛する (§3.3、P1)。初期値は 16/16。【M3 で決定】`ENTRIES` ∈ {16, 32, 64}: boot の walk 回数と IPC で sweep して決める。
- Sv39 で canonical でない VA (`VA[63:39]` が `VA[38]` の符号拡張でない) は、lookup も walk もせずに page fault とする。Bare では PA = VA とし、`VA[63:56] ≠ 0` は PMA の hole としてアクセス fault にする (PM4)。

### M.8 `ptw` (D と I)

#### M.8.1 要求キュー、合流、epoch

- D と I に 1 つずつ instantiate する。walker の状態遷移は `mmu.veryl` の LEVEL2/1/0、GST_L2/1/0、VS_RD、WRITE_AD (`:744-1137`) と、leaf と non-leaf の検査 (`:525-560`。予約 bit、W&!R、PBMT、N bit、superpage の整列) を移植する。DONE/FAULT/FAULT2/TS_DONE/TS_FAULT/TS_FAULT2 のような結果を保持する状態は持たない。完了は 1 サイクルの COMPLETE で、そこで install、応答、イベントを出して IDLE に戻る。

```veryl
module ptw::<CFG: core_cfg> #(param QN: u32) (   // QN bound from CFG::PTW_D_QN / PTW_I_QN; XlateReq depends on CFG
    i_kill : input  Kill,
    i_req_valid: input logic, i_req: input XlateReq,  o_req_ready: output logic, // registered: queue has room
    o_fill : output TlbFill,                          // to this side's tlb (V=0, and V=1 from M5)
    o_resp : output XlateResp,                        // owner response, registered
    o_evt  : output PtwEvent,                         // waiter wakeup, registered
    // D: MemReq/MemResp/MemEvent client on port 0: PTW_READ; as client AD, STORE_WT (M1-M3) or LOAD_EXCL/STORE_EXCL (M4)
    // I: islot_arb client for PTE reads; port-0 STORE_WT client AD for A-bit writes
    // CSR context (satp/vsatp/hgatp, privilege, SUM/MXR, menvcfg/henvcfg, pmpcfg/pmpaddr), latched at walk start
);
```

- 要求は valid/ready で受ける (ready は登録済みのキュー空き)。要求を出せるのは、LQ/SQ に割り当て済みで kill されていない op (D。LR を含む)、M5 からは VU の要素アクセス (D)、`ifu` (I) だけである (X4)。キューのエントリは `{tag: MemTag, va, acc, hlv, hlvx, nonspec}`。
- 【決定】合流: キー `{VPN, regime}` (regime は V=0、V=1、HLV のいずれか) がキュー内のエントリか実行中の walk と一致する要求は、キューに入れずに受理し、要求者を PtwEvent の waiter にする。理由: N 本のポートが同じ page で miss しても、walk は 1 回で済む。
- 【M3 で決定】キュー深さ `QN` (初期値 D=4、I=1): cfg_w4 の bench と boot で、キューが満杯で受理を待ったサイクル数を測って決める。
- kill: D のキューは、エントリの owner の RobTag (`MemTag.rob`) に `killed()` を適用して owner を落とす (§5.4、§5.9)。I のキューは、どの kill でも空にする (front end の規則, §5.4)。実行中の walk の owner が kill されたら owner の valid だけを落とし、walk は続ける。ただし `nonspec` の walk は、owner の valid が落ちていたら D ビットの PTE 書き込みを出さず、TLB への install だけで終える (§5.13.1 IR5。IR4 により起こらないはずなので、checker が flag を立てる)。
- epoch (X2): walk の開始時に、epoch と文脈 (satp/vsatp/hgatp のルートと mode、実効特権、SUM/MXR、ADUE、PBMTE) を latch する。install は、COMPLETE のサイクルの増分を反映した後の epoch と一致するときだけ行う。したがって kill と同じサイクルに完了した walk は install されない。合流は、同じ epoch の walk にだけ行う。

#### M.8.2 完了と応答

```veryl
o_resp: XlateResp                                              // to the owner tag, registered (section 5.10)
o_evt : PtwEvent  // {valid, key: PtwKey = {vpn, regime}, fault} (section 5.10); every walk completion, success or fault
```

- 【決定】walk の owner には、完全な XlateResp (pa、pma、exc。owner の acc で権限、PMP、PMA を検査済み) を返す。合流した waiter には PtwEvent を送り、waiter は TLB をもう一度 lookup する。fault のときも PtwEvent を送る。waiter は再 lookup で miss し、自分の walk の owner になって自分の fault を受け取る。理由: owner が install 直後の置換で再 lookup に負け続ける余地を消すため (owner は必ず前進する)。walker は結果を保持する状態を持たないので、TS_DONE が投機要求に握られて guest Linux を 2 か月 deadlock させた事故 (c358684) の類は構造的に起きない。
- そのため `ptw` は、最終 PA 用に `pmp_check` (D は R と W、I は X) と `pma_check` を持つ。
- 冗長な walk (lookup の miss の直後に、同じキーの walk が完了していた場合) は許す。正しさには影響しない。
- 不変条件 (所有者 `ptw`): walker は、要求者が VA を再提示することにも、ポートの live な状態にも依存しない。応答の帰属は tag だけで決める。

#### M.8.3 PTE 読みのメモリ client

- D-PTW は `mem_port_arb` の port 0 の client=PTW_D (`MemTag.rob` は無効、M.2.6) で、クラスは PTW_READ (fold 群) である。応答は tag で照合する。MISS なら `fill_id` に park して MemEvent で再 issue し、RETRY(FILL_BUSY) なら任意の DONE/ABORT を待ち、それ以外の RETRY は即座に再 issue する。旧コアの「ポートが返したものを PTE とみなす」構造 (replay が `i_addr` を上書きし、load のデータを PTE として install した, `heliodor_core.veryl:10601-10612`) は、tag の照合で構造的に消える。
- 各 level の PTE 読みの前に `pma_check(pte_pa)` の `pte_ok` と PMP の R を検査し、拒否なら読みを出さずにアクセス fault で終える。旧コアは PMP 拒否の PTE 読みを抑止したまま完了させず、特権が M に戻った後に誤ったエントリを install した (54c7d87)。PTE への PMP 検査の特権は S とする (暗黙のアクセス)。
- PTE 読みは常に cacheable で、PBMT を見ない (PM3)。PMA 表には「`pte_ok=1` の領域は `cacheable=1` かつ `coherent=1`」という制約を課し、PM6 の表検査で確かめる。
- I-PTW は I read slot を `islot_arb` 経由で使う (M.5)。

#### M.8.4 Svadu の A/D

- A ビットは投機的に立ててよい。ADUE=1 で A=0 の leaf に当たったら、PTE|A を書いてから install する。
- D ビットは正確でなければならない (非投機、プログラム順)。【決定】store/AMO の lookup が W=1・D=0 のエントリに当たったら、ADUE=0 なら page fault、ADUE=1 なら XlateResp に `need_d=1` を返し、PA は確定させない。`sq` (atomic も SQ エントリを持つので、atomic の分も `sq` が出す) は、§5.13.1 の開始点の規則に従って `nonspec=1` の `ptw` 要求を出す (受理 edge で token を照合し、`started_q` を立てる。§L.16)。walker は PTE を読み直し、valid で store を許すことを確かめてから PTE|A|D を書き、D=1 のエントリを install して owner に XlateResp を返す。理由: D を更新した時点の walk を、その store の翻訳とする (Sv39 の更新手順と同じ)。execute 時の PA を使わないので、途中で PTE が書き換わった場合の照合も replay も要らない。代わりに、D=0 の page への最初の store だけが head まで PA 不明になり、その間 LSQ はこれを「アドレス未知の store」として扱う (§L)。
- `nonspec` の要求が受理されてから store が retire するまで、head の op は取り消せない操作を開始した状態 (`head_started_q`、§5.13.1) とする。割込みで store が捨てられると、D だけが立って store が行われないことになるからである。
- 書き込みの経路は、M1-M3 では port 0 の client=AD、STORE_WT (PENDING の後、WT_DONE で完了)。【決定】A/D の書き込みは `sb.ordering_empty` の下でだけ出す。理由: PTE を読んでから書くまでの間に、自 hart の SB にある同じ PTE への store が drain されると、古い PTE|A で上書きしてしまう。M4 では、LOAD_EXCL で PTE を読み、walk で読んだ値と比較して、一致すれば STORE_EXCL で書く owned RMW にする。不一致か FAIL なら walk をやり直す (§5.9 の A/D の決定。SMP での原子性)。
- A/D の書き込みは PTE アドレスへの W であり、PMP で拒否されればアクセス fault とする (`mmu.veryl:453` の検査を移植)。

#### M.8.5 Svnapot と Svpbmt

- Svnapot: level 0 の N=1 leaf は PPN[3:0]=1000 のときだけ有効とし (それ以外と、level 1/2 の N=1 は fault)、PPN の下位 4 bit を VA[15:12] で埋めた 4 KiB のエントリとして install する (`mmu.veryl:856-880` の移植)。【決定】エントリに `napot` ビットを持ち、VA を指定した SFENCE.VMA は napot エントリを 64 KiB 単位 (VA[38:16]) で照合して消す。理由: 4 KiB 単位で照合すると、同じ NAPOT 範囲の別の 4 KiB エントリが残る。広めに消すのは常に安全である。
- Svpbmt: PBMTE=0 で PBMT≠0、または PBMTE=1 で PBMT=11 は予約として fault。エントリは PBMT (PMA/NC/IO) を持ち、`mem_pipe` が lookup の結果を PMA と合成する (PM3: 厳しくする方向にだけ)。M5 では、VS-stage の PBMT (henvcfg.PBMTE) と G-stage の PBMT (menvcfg.PBMTE) の両方を合成する。旧コアは V=1 で PBMT を無視していた (`mmu.veryl:1228-1235` の `o_uncached` は `vm_enabled` が偽なら 0 で、`vm_enabled` は `:209` で V=1 のとき偽になる)。

### M.9 sfence/hfence

- SFENCE.VMA と SINVAL.VMA は、SYS FU がオペランド (rs1 の VA、rs2 の ASID、それぞれの x0 フラグ) を PRF から読み、`commit` の `sys_pending` を経て retire 時に両方の TLB へ `TlbInv` を出す (OpClass は §5.5、retire 時の動作と epoch の扱いは §C.6 が正本)。同じ edge で full kill が起き、epoch が進み、younger の op は refetch されて新しい TLB で翻訳し直される。
- 無効化の述語: V=0 のエントリには旧コアの選択的な述語を使う (rs1=x0 か level を考慮した VPN 一致、かつ rs2=x0 か「ASID 一致かつ G=0」)。napot エントリは M.8.5 のとおり。
- SFENCE.W.INVAL と SFENCE.INVAL.IR は順序だけで、TLB は触らない (§5.5 の表)。
- M5: HFENCE.VVMA/GVMA と V=1 での SFENCE.VMA は、V=1 エントリを VMID の一致で消す。GPA を指定した GVMA は、合成エントリが GPA を持たないので、その VMID の全エントリを消す。V=0 のエントリは触らない。旧コアは V=1 のエントリを全部消し、guest のオペランドで host の V=0 エントリも消していた (どちらも消しすぎで、正しい)。

### M.10 PMP と PMA

- 【決定】`pmp_check` は変更せずに再利用し、用途ごとに instantiate する: 各メモリポートに R と W を 1 つずつ (load は R、store は W、AMO は R かつ W、cbo.clean/flush/inval は R または W)、fetch に X、各 walker に PTE の R と W、最終 PA 用 (M.8.2)。旧コアでは使う場所ごとに増え、1 hart に 16 個あった。
- 評価は op ごと・ポートごとに翻訳時に 1 回だけ行い、結果を LQ/SQ のエントリか fetch block に入れる (PM2)。複数の cause の優先順位は `exc_pkg::exc_prio` で決める。PMP と PMA は翻訳が成功したときだけ評価するので、page fault が PMP/PMA に勝つ。
- 【M2 で決定】PMP の端点検査: `pmp_check` は先頭 word のアドレスしか見ない (サイズを取らない)。NA4/TOR の境界をまたぐアクセスでは、最後のバイトのアドレスでも検査する必要がありうる。ACT4 の PMP テストに境界をまたぐ directed test を足し、必要なら `mem_pipe` 側で 2 つ目の検査を追加する (`pmp_check` 自体は変えない)。
- PMA は §5.11 の `pma_check` を 3 か所で評価する: `mem_pipe` (データ。PBMT と合成)、`ifu` (fetch。`executable=0` は命令アクセス fault)、`ptw` (PTE。PBMT を見ず `pte_ok`)。

### M.11 例外フィールド

翻訳で生じた例外は、`ExcRec` (§5.8) を次のように埋めて op と一緒に運ぶ。live な MMU 出力は読まない (旧コアは store の htval を commit 時に live な `dmem_mmu_gpa` から読んでいた、`heliodor_core.veryl:7272-7281`)。

| フィールド | 規則 |
|---|---|
| `cause` | page fault 12/13/15、アクセス fault 1/5/7、guest-page fault 20/21/23。どれも元のアクセス種別 (fetch、load、store/AMO) で選ぶ。cbo.* と AMO は store 側。旧コアは ROB 経由で届いた store/AMO の guest-page fault を 15 にしていた (推定)。 |
| `tval` | fault した部分の VA。分割アクセスの後半の page で fault したら、後半の先頭バイトの VA (特権仕様の「アクセスのうち fault した部分の仮想アドレス」)。canonical でない VA はそのまま入れる。 |
| `gpa` | guest-page fault のときだけ有効。最終アクセスなら data の GPA、VS-stage の暗黙の PTE アクセスならその PTE の GPA。`trap_unit` は htval/mtval2 に `gpa >> 2` を、それ以外の trap では 0 を書く。旧コアは cause 20/21/23 以外の trap で古い値を残していた。 |
| `gva` | tval が guest の仮想アドレスであるとき 1: V=1 のアクセス、HLV/HLVX/HSV、MPRV で MPV=1 のアクセス。 |
| tinst | `ExcRec` には持たず、`trap_unit` は 0 を書く (旧コアと同じ)。【M5 で決定】VS-stage の暗黙アクセスによる guest-page fault に擬似命令を書く必要があるかを、仕様と ACT4/Sail で確かめる。必要なら `ExcRec` に「暗黙アクセス」の 1 bit を足す。 |

### M.12 二段翻訳と V=1 (M5)

- `tlb` のエントリに `{virt, vmid, vs_mode}` を足し、V=1 の合成エントリ (GVA → HPA、権限は段ごとの AND、level は 2 段の小さい方) を入れる。vsatp が Bare の翻訳 (G-stage だけ) と HLVX も入れる (HLVX は合成エントリの x を見る)。これで「キャッシュされない翻訳」が無くなり、walker が結果を保持する理由も無くなる。
- 合成エントリで権限検査に落ちたら fault にせず miss として walk し、VS と G のどちらの fault かと GPA を owner への応答で返す (旧コアの規則を保つ)。
- 【M5 で決定】V=1 のエントリを V=0 と同じ `tlb` に同居させるか、別の instance (初期値 32) にするか: hvlinux の walk 回数を両方で測って決める。
- `i_no_walk` (投機要求の walk 抑止) は持たない。lookup には副作用が無く、walk を始めるのはキューへの要求だけである (X4)。c358684 の教訓「投機要求は共有 FSM の状態を保持しない」は、この 2 点と結果保持状態の廃止 (M.8.1) で構造的に満たされる。
- walk の間は、hgatp も walk の開始時に latch した値を使う。旧コアは G-stage を再開するたびに live な hgatp を読んでいた。
- 旧コアの二段 walk の欠落を M5 で直す。これらは golden と食い違うが、hvlinux は pass/fail だけで判定するので D4 の範囲内である: GST_*/VS_RD での PTE の PMP/PMA 検査、VS と G の PTE の予約 encoding の検査、Sv39x4 の GPA[63:41]=0 の検査、GVA の canonical 検査、二段 walk での cbo の権限 (R または W、D は不要)、MXR の意味 (vsstatus.MXR は VS-stage だけ、sstatus.MXR は両段)。
- 【M5 で決定】guest 側の Svadu (henvcfg.ADUE による VS-stage の A/D、menvcfg.ADUE による G-stage の A/D) を実装するか、旧コアどおり A/D=0 を fault にするか: hvlinux と ACT4 の H 系テストがどちらを要求するかで決める。
- 旧コアの `o_gstage_fault` は VA の一致で gate されていなかった (`mmu.veryl:1304`)。新設計では gstage と gpa は、tag 付きの fault 応答の中にだけ存在する。

### M.13 checker と発火イベント

- `chk_*` (観測専用、§5.15) に足す項目:
  - 受理していない tag への MemResp、1 つの要求への 2 つ目の応答。
  - 生きている MISS(g)/PENDING(g) に終端イベントが続かないまま、上限サイクルを越えた。
  - UNC_READ の保持中の `o_fill_start` (M.2.3)。同じ set に有効な MSHR エントリが 2 つ (M3)。
  - kill 済みの owner への XlateResp。epoch が一致しない walk の install。
  - 同じサイクルの TLB への install と無効化の両方が同じエントリに効いた。
- `o_perf` に出す機構: RETRY の理由別、HOLD、attach、critical-word 早期完了、back-to-back 受理、bank 衝突 (M3)、WAIT_LAUNCH のサイクル (M3)、TLB miss、walk の開始、合流、epoch による install の棄却、D 更新の要求、A/D 書き込み。どれも少なくとも 1 つのゲートで 0 より大きくなること (§5.15)。WAIT_LAUNCH は旧コアでは boot 全体で 14 サイクルしか入らなかったので、M4 で新コアの N=4 boot ができた時点から発火数を記録する。

---

## §S SoC とプラットフォーム

本章は統合 SoC `heliodor_soc_smp`、PMA 領域表の値、L2/mem_ctrl/bus から見たコアの外部契約、時刻と割込みと観測の配線を定める。L2、mem_ctrl、memory_bus、CLINT、PLIC、UART の内部ロジックは再利用し、本章が足すのは本章に書いた追加と変更だけである。dcache 側から見た L1↔L2 の義務は §M.4、検証が要求するパラメータとポートの一覧は検証計画 §2.1 が持ち、本章はそれを再掲しない。旧コアの行番号は `b0f4668` のもの。

### S.1 統合 SoC

- 【決定】`heliodor_soc` を削除し、`heliodor_soc_smp` を `N_HARTS>=1` で使う 1 つの SoC にする (D3)。M1a の作業である。パラメータは `CORE` (enum `V14`/`W2`/`W4`)、`N_HARTS`、`PMA_REGIONS` (S.2)、`MTIME_SRC`/`MTIME_DIV` (S.5)、`RESET_PC`。
- `CORE` は generate-if でコアを選ぶ (D6、§3.6)。V14 枝は現在の SoC の配線をそのまま保つ (PA[31] による DRAM デコード、`o_imem` の tb 供給、I slot の DRAM 固定)。V14 のゲート結果を動かさないためである。新コアの枝では、アドレスのデコードを `pma_pkg::pma_check(PMA_REGIONS)` の 1 か所で行う (§5.11 PM1)。
- コアとの接続は §4.5 の外部ポート群だけである。D read slot と I read slot は hart ごとに 1 本ずつ (S.3)、write channel と coherence 入力は再利用 dcache の既存仕様、割込みは CLINT と PLIC からの pin、時刻は `i_mtime` である。
- `N_HARTS=1` で幅 0 の信号が生じないように、hart 番号の幅は `idx_w` 相当の helper で作る (§5.1)。

### S.2 PMA 領域表とプラットフォームマップ

所有者: 表の値は §S、型と評価関数は `pma_pkg` (§5.11)。harness ごとの表 (`MAP_BOOT`、`MAP_ARCH`、`MAP_LITMUS`) の置き場所と違いは検証計画 §2.2 にある。下表は boot 系 (`MAP_BOOT`) のプラットフォームマップで、現在の SoC のデコード (`heliodor_soc_smp.veryl:138-146`) と DTS (`test/linux/dts/heliodor.dts`) から取った値である。

| 領域 | base | PMA の大きさ | DTS の reg | target | cacheable | coherent | executable | idempotent | io_ordered | amo | misaligned_ok | pte_ok | cbo_ok |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ROM | 0x0000_0000 | 16 KiB | (無し) | ROM | 0 | 0 | 1 | 1 | 0 | NONE | 0 | 0 | 0 |
| CLINT | 0x0200_0000 | 64 KiB | 0x10000 | IO | 0 | 0 | 0 | 0 | 1 | NONE | 0 | 0 | 0 |
| PLIC | 0x0C00_0000 | 4 MiB | 0x1000_0000 | IO | 0 | 0 | 0 | 0 | 1 | NONE | 0 | 0 | 0 |
| UART | 0x1000_0000 | 4 KiB | 0x100 | IO | 0 | 0 | 0 | 0 | 1 | NONE | 0 | 0 | 0 |
| DRAM | 0x8000_0000 | 32 MiB | 0x1FFF000 | DRAM | 1 | 1 | 1 | 1 | 0 | FULL | 1 | 1 | 1 |

それ以外の PA はすべて hole であり、アクセス fault になる (§5.11 PM4)。

- 表の不変条件 (所有者 `pma_pkg`。elaborate 時に const 関数で検査し、PM6 の照合スクリプトでも検査する): 各領域は 4 KiB 以上の 2 の冪の大きさで、その大きさに自然整列している。領域は重ならない。`executable=1` ならば `idempotent=1` (§F.6 IC5)。`pte_ok=1` ならば `cacheable=1 && coherent=1` (§M.8.3)。`amo != NONE` ならば `cacheable=1`。
- 旧コアとの差: 旧 SoC は UART を PA[31:28]==1 の 256 MiB の窓で、CLINT と PLIC を PA[31:24] の 16 MiB の窓でデコードし、PA[63:32] を見ない。新コアの枝では上表の大きさだけが backed で、残りは hole になる。旧コアは ROM を hole に置き、`PMA_FAULT=0` で hole 判定を切っていた (検証計画付録 B の B42)。
- PLIC の大きさは、hart あたり 2 context で 8 hart まで (`heliodor_soc_smp.veryl:660`) のレジスタを覆う 4 MiB とする。DTS の reg (0x1000_0000) はこれより大きく UART と重なっている。【M1a で決定】DTS を表に合わせて直すか、PM6 の照合を「DTS のノードの base が領域の base と一致し、デバイスが実装するレジスタがすべて領域に入る」に緩めるか: DTS を直すと boot イメージを作り直し、V14 の cy の基準値も取り直すことになる。推奨は照合を緩めて DTS は直さないことで、差は表の備考として残す。DRAM の DTS の reg が 4 KiB 短い件も同じ扱いにする。
- 【決定】領域の最小単位を 4 KiB にする。理由: `ifu` は fetch block ごとに `pma_check` を 1 回評価し (§F.5)、`mem_pipe` は line 跨ぎの hi 側を同じ page なら再翻訳しない (§L.15)。どちらも、page の中で PMA の属性が変わらないことを前提にしている。UART の 0x100 のように実際のデバイスが小さくても、領域は 4 KiB にする。

### S.3 mem_ctrl の slot プロトコル (コアの外部契約)

L1 から見た mem_ctrl の read channel の規約を、コアの外部契約としてここに固定する。出典は `mem_ctrl.veryl` の先頭のコメント (`:1-60`) である。L1 側が守る義務の一覧は §M.4 にある。

- slot: hart ごとに `SPH = 2` 本 (D 側 1 本、I 側 1 本)。番号は slot-major で、slot `h` が hart h の D、slot `N_HARTS + h` が hart h の I である (`heliodor_soc_smp.veryl:437-447`)。
- DRAM の line 読み (`i_hdram=1`): 要求 `{i_hreq, i_haddr, i_hrfo, i_iread}` を受理するとき、mem_ctrl は 1 サイクルの `o_hgrant` (ACCEPT) を出す。その後、L2 を lookup し、他 hart が所有していれば recall を待ち、L2 の hit なら `HIT_WAIT`、miss なら `DRAM_WAIT` と gather の後に、`o_hgrant` を 8 サイクル連続で立てる (STREAM)。STREAM の各サイクルの `o_hrdata` は、そのサイクルに要求者が `i_haddr[5:3]` で指した dword である (critical-word-first)。grant の状態 `o_hexcl` (E/M か S) は完了時に有効である。同じ line への accept は直列化される。
- 非 DRAM の読み (`i_hdram=0`): legacy の single-beat。要求は memory_bus の read channel にそのまま通り、grant のサイクルにデータが返る。デバイスの read enable は grant のサイクルに 1 回だけ立つ。
- `i_iread=1` の読み: coherent だが directory に sharer として数えない読み。owned な line は recall してから読み、L2 には install しない (S.6)。
- write channel: posted な 1 サイクルの line 書き込み (8 dword lane と lane ごとの strobe、WB フラグ)。他 hart が所有する line への WB 以外の書き込みは、SoC の write-grant veto で recall が済むまで待たされる。
- coherence: `probe` と `probe_ack` (pin による延期は 64 サイクル以内)、directory から来る precise な `inv`/`inv2`。
- 不変条件 (所有者 mem_ctrl と L1。§M.4 と同じ): accept の grant は必ず L1 の fill の開始と一致する。要求者は accept まで要求を保持し続ける (落とすと 64 サイクルの aging がリセットされる、3da1aa2)。STREAM の beat の受理を自分の要求で gate しない (9d9f013)。

### S.4 I read slot の非 DRAM ルーティング (M1a の前提作業)

- 現状: SoC は I slot の `mc_dram` を `1'b1` に固定している (`heliodor_soc_smp.veryl:447`)。I slot は常に DRAM の line 読みであり、ROM からの fetch は `o_imem` のパススルーで tb が直接返している (`tb/test_soc_smp_linux_boot.veryl:132-137`)。新コアは `o_imem` を持たない (§4.5) ので、このままでは ROM から 1 命令も fetch できない。reset PC が ROM にある boot 系 (GL-B、GB1) と smode_plic がすべて止まる。
- 【決定】新コアの枝では、I slot の `mc_dram` を要求者の属性から作る: icache の uncached fetch (§F.6 IC5) と `islot_arb` が出す single-beat 要求は `i_hdram=0`、line fill と PTE 読みは `i_hdram=1` とする (§5.11 PM7: line か single-beat かを決めるのは要求者の属性で、SoC のアドレスデコードではない)。`i_hdram=0` の I slot 要求は D 側の legacy 読みと同じく memory_bus の read channel を通し、ROM の読みデータは D 側の legacy 読みと同じ外部ポートから返す。V14 の枝は `1'b1` のまま保つ。理由: 外部メモリプロトコルを 1 つにする (D3) と、ROM fetch のためだけの別線 (`o_imem`) が不要になる。
- 時期とゲート: SoC 統合と同時に M1a で入れる。M1a の時点では新コアが無いので、SoC 単体の unit test (I slot に ROM 番地の single-beat 読みを出し、1 beat で値が返ること) で確かめる。M1b の rv64ui は ROM を使わない (`MAP_ARCH`) ので、端から端まで動くのは M2 の boot と smode_plic である。

### S.5 時刻、割込み、デバッグ入力、観測

- CLINT: 追加の入力 `i_tick_sel`/`i_tick` (§3.4)。`i_tick_sel=0` で従来の /10 prescaler、1 で `i_tick` のサイクルに mtime を 1 進める。SoC の `MTIME_SRC` は `CYCLE`、`INSTRET`、`EXTERNAL`、`OFF` の 4 値で、`MTIME_DIV` はその分周 (既定は `CYCLE` と 10)。値の意味と harness の対応は検証計画 §4.1 にある。
- 【決定】`MTIME_SRC=INSTRET` の tick は、hart 0 の retire record (サイクル r の retire はサイクル r+1 に登録済みで出る、§C.2.7) から組合せで作り、そのサイクルの edge で mtime に入れる。tick の経路にレジスタを足さない。理由: 時刻の読みが retire 順位だけで決まるという論証 (検証計画 §4.1) は余裕が 0 サイクルである。op X がサイクル r に retire すると、record は r+1、mtime の更新は r+1 の edge、次の op Y が token を得るのは r+1、Y の `fu_sys` の受理は早くて r+2 である。tick に 1 段でもレジスタが入ると、Y は X の分の tick を見ずに読む。SoC は `MTIME_SRC==INSTRET` のとき `N_HARTS==1` と `MTIME_DIV ≥ COMMIT_W` を elaborate 時に検査する。
- 割込み: CLINT から hart ごとの timer と software の pin、PLIC から hart ごとの M と S の外部割込みの pin (hart あたり 2 context)。`i_ext_irq_src` は PLIC に足す外部ソースで、tb が smode_plic のパルスを入れる (既定 0)。ゲスト外部割込みは M5。
- デバッグ入力: hart ごとの `i_dbg_retire_limit_en/limit`、`i_dbg_irq_mask/allow` をコアへそのまま配る (§5.13)。harness が駆動しない限り 0。
- 観測: hart ごとの `o_retire`、`o_irq_evt`、`o_perf`、`o_chk` をそのまま出す。`o_chk_io` は SoC 側の IO モニタ `chk_io_mon` の sticky flag で、照合規則は検証計画 §8 にある。V14 の枝では retire port が無いので無効である。

### S.6 coherent ifetch

- I 側の line fill と I-PTW の PTE 読みは `i_iread=1` で出す (§M.5)。owned な line は recall されてから読まれるので、自 hart と他 hart の L1D にある dirty な line も、要求の時点の最新値で I 側に届く。
- I 側の line は directory に載らないので、他 hart の書き込みでは invalidate されない。RISC-V の規約どおり、他 hart の store が自 hart の命令として見えるのは、自 hart が FENCE.I を実行した後である。
- FENCE.I に要るのは、自 hart の SB を drain すること (drain=1) と icache の invalidate だけである (§F.10)。旧 `COHERENT_IFETCH=0` の D$ flush sweep は持たない (D3)。
- 不変条件 (所有者 §S、L2 と mem_ctrl): `i_iread=1` の読みは、受理の時点で他の L1 が持つ dirty な値を返す。

### S.7 宣言された上限

| 上限 | 出所 | 値 |
|---|---|---|
| hart 数 ≤ 8 | mem_ctrl の `o_cadd_hart: logic<3>` と `o_inst_hart`、CLINT のデコード (`clint.veryl:33-34` の `logic<3>`) | N_HARTS ∈ {1, 2, 4, 8} |
| hart あたりの slot は 2 本 | `SPH=2` (D 1 本、I 1 本)。`SPH > 2` には `o_inst_hart = h as 3` (`mem_ctrl.veryl:1067`) の修正などが要る (§M.4) | `N_FILL=1` |
| PLIC のソース数 | DTS の `riscv,ndev = <31>` | 31 |

どれも §3.4 に載っている。

### S.8 マイルストーンごとの範囲

| M | §S が出荷するもの |
|---|---|
| M1a | SoC の統合 (`CORE=V14` の枝だけ)、S.1 のパラメータ、S.4 の I slot ルーティング、CLINT の tick 入力、`MAP_BOOT`/`MAP_ARCH`/`MAP_LITMUS` の表と PM6 の照合スクリプト、S.2 の DTS の扱いの決定 |
| M1b | `CORE=W2/W4` の枝 (新コアの instantiate と `pma_check` によるデコード) |
| M2 | 新コアでの boot と smode_plic (ROM fetch、割込みの pin、`i_ext_irq_src`)、`chk_io_mon` の有効化 |
| M4 | PLIC claim の競合の directed test (検証計画 §8) |
| M6 | V14 の枝の削除 |

---

## §V ベクトルユニットの統合

本章は M5 で行う VU (RVV 1.0, VLEN=128, ELEN=64) の統合を定める。旧コアの `vector_unit` (3,044 行) と `vrf` を内部ロジックごと再利用し、新コアとは明示した契約だけで接続する。旧コアの行番号は `b0f4668` のものである。

### V.1 範囲と M5 までの扱い

- VU は「oldest token を持つ op としてだけ動く in-order コプロセッサ」とする。VRF は rename しない。vector op は IQ にも LQ/SQ にも入らない。ROB エントリを 1 つ持ち、VU の dispatch FIFO に入る。
- 【決定】M1-M4 の新コアは VU を持たない。`decode` は OP-V と vector の load/store encoding をすべて `NONE` + illegal (cause 2) にする。理由: M4 までのゲート (rv64ui..., ACT4、5.15/SMP boot) は V を使わない。V を使うのは、旧コアの default suite に入っている 20 本の `test_arch_v*` (`tb/test_arch_common.veryl`) だけであり、新コア用のハーネス (D3) ではこれらを M5 まで外す。旧コアで不正な OP-V が head で wedge した経路 (§5.5) は、M1 の時点で構造的に存在しない。
- csr の misa.V は M5 まで旧コアと同じ値のままにする。V を検出して使うソフトウェア (7.1+V boot) は M5 まで回さない。

### V.2 構成と VU への変更

| モジュール | 由来 | 役割 |
|---|---|---|
| `vector_unit` | 再利用 (M5 で下記 4 点を変更) | dispatch FIFO (8 エントリ)、作業用 vtype/vl、要素直列の各 FSM、専用の `fpu_wrap` と `int_divider` |
| `vrf` | 再利用 (変更なし) | 32×128 bit。読出は組合せ、書込は登録。読み書きするのは VU だけ。`vector_unit` と並べて top で instantiate する |
| `vu_adapter` | 新規 | alloc、exec 許可、scalar オペランド、完了、側帯、kill、事前検査、観測 (V.3) |
| `vu_mem_adapter` | 新規 | VU の要素アクセスを memory pipe 0 と `sb` に載せる (V.4) |

【決定】M5 で `vector_unit` の契約 (ポートと年齢の扱い) に入れる変更は、次の 4 点だけとする。理由: §3.4 の VU 上限のうち、窓の大きさと年齢計算に関わるもの (ROB_IDX_W ≤ 8, ROB_N = 2^k) を消し、ROB head 番号を配らない (§5.2) ために必要な最小限である。これとは別に、VU 内部の適合性の修正 (V.9 の G5、G8、場合により G7) を同じ凍結の後に入れる。

| # | 変更 | 置き換える旧仕様 |
|---|---|---|
| VM1 | FIFO のタグを `RobTag` にし、`i_flush`/`i_squash_en`/`i_squash_idx` を `i_kill: Kill` 1 本に置き換える。エントリは `killed(i_kill, tag)` で落とす。 | `fifo_rob - i_rob_head_idx` による年齢計算 (`vector_unit.veryl:2589-2593`)。2 の冪の ROB と ROB head 番号を前提にしていた。 |
| VM2 | `i_rob_head_idx` を exec 許可 `i_exec: {valid, tag: RobTag}` に置き換える。`at_head = i_exec.valid && h_tag == i_exec.tag`。FIFO head の `o_head: {valid, tag, vtype_dep, is_fp}` を出力に足す。 | `at_head = h_rob == i_rob_head_idx` (`:2377`)。 |
| VM3 | 専用 `u_vfpu` の owner 幅を `ROB_IDX_W` から切り離し、8 bit に固定する。 | `fp_elem[ROB_IDX_W-1:0]` で `fp_elem: logic<8>` (`:925, :2272`)。ROB_IDX_W > 8 が elaborate できない。 |
| VM4 | `o_wb_req` (head op に完了待ちの結果がある) と `o_wb_rd` (その完了が scalar rd を書く) を出力に足す。どちらも `i_cdb_free` には依存しない。 | 完了の要求は外から見えず、`i_cdb_free` を組合せで受けて即座に発火していた (`:2373-2477`)。 |

- VM1-VM4 と V.9 の VU 内部の修正は、追加だけでは済まない変更である。§4.4 に従い、M5 で変更を入れる前に `src/v14/v14_vector_unit` へ凍結コピーを取り、旧コアはそちらを使う。受入条件は dhrystone/coremark のビット一致と、旧コアでの 20 本の V テスト。
- パラメータは `MEM_PIPE=0`、`VINT_PIPE=1`、`PRF_W=PREG_W` (§3.2 の共通幅) とする。`VFP_PIPE`、`VALU_PIPE`、`VFP_EX_PIPE` は出荷時の値のまま VU 内部に残す。VU は §2.1 P4 (knob 0 個) の対象外の再利用モジュールとして扱い、cold-reader gate も `vu_adapter`/`vu_mem_adapter` のヘッダだけに適用する。
- `vector_pkg` (VLEN=128) と `decoder` の vector 部は変更しない。vector の合法性検査は新しい `decode` に置く (V.6)。

### V.3 `vu_adapter` の契約

```veryl
struct VuAlloc {                     // dispatch -> vu_adapter, one per rename group
    valid: logic, tag: RobTag, op: vector_pkg::VecOp, insn: logic<32>,
    src1 : PReg, src2: PReg, fsrc1: PReg,  // renamed int rs1, int rs2, fp rs1 (unused ones ignored)
    dst  : PReg, has_rd: logic,            // vset*/vmv.x.s/vcpop/vfirst (INT), vfmv.f.s (FP)
}
struct VecSide {                     // rides the completion packet, held in commit.vec_pending
    vcfg_v: logic, vtype: logic<64>, vl: logic<64>,       // vset*, fault-only-first trim
    vstart: logic<64>,                                    // faulting element on trap, else 0
    fflags: logic<5>, vxsat: logic,
    vrf_wcnt: logic<8>, vrf_hash: logic<64>,              // section V.7
}
struct VuDone { valid: logic, tag: RobTag, exc: exc_pkg::ExcRec, side: VecSide } // to rob and commit
```

| # | 契約 (所有者) |
|---|---|
| VA1 | alloc (`dispatch`): rename group の中で最初の VEC lane だけを VU に割り当てる。2 つ目の VEC lane の手前で group を切る (§5.3 R4 の部分受理、予算 `VQ`、§3.2 の「群あたり 1」)。VU の credit は FIFO の登録済み空き (`o_alloc_rdy`) である。最初の VEC lane は prefix の one-hot で選び、lane 番号で特例を書かない (R4)。割り当ては ROB の割り当てと同じサイクルに行い、kill のサイクルには行わない (T2)。 |
| VA2 | exec 許可 (`vu_adapter`、許可の生成は `commit`、タグは `rob`): VU が FIFO head の作業を始めてよいのは、`i_exec.tag` が head のタグと等しいときだけ。M1-M5 では exec 境界 = oldest token とし、`i_exec.tag = rob.oldest.tag`、`i_exec.valid = nonspec_ok \|\| exec_q` とする (§5.12, I5)。この信号には「exec 境界」として名前を付け、将来の緩和 (V.8) を `vu_adapter` 内の局所変更にする。`exec_q` は §5.13.1 の started latch の VU 版である: `nonspec_ok` かつ `o_head.tag == rob.oldest.tag` のサイクルを開始点とし、その edge で `exec_q` を立てて `o_started` を出し、その op が retire するか自分の trap で full kill されるまで保持する。開始後の要素要求は token ではなく `exec_q` で出す (§5.13.1 IR1)。保持がないと、開始後に割込みが pending になった時点で token が止まり (I4)、VU が途中で止まったまま head が retire できずに固まる。 |
| VA3 | scalar オペランド (`vu_adapter`, `prf`): VU が読む scalar source はすべて `prf_done=1` でなければならない (§5.7)。`busy_table` の `prf_done` は、この最初の消費者と同時に M5 で作る (§5.7、§X.4)。M5 ではこの条件は VA2 から構造的に成り立つ。head より古い producer はすべて retire 済みであり、retire した op の値は PRF にあるからである。`vu_adapter` は exec 許可の条件に `prf_done` の項を入れ、その項が許可を止めた回数を `chk_vu` で数える (0 であるべき)。`prf` への要求: ROB に完了を記録したサイクルの次のサイクルからは、その値が PRF の読出ポートで見えること。VU の CDB snoop 入力は 0 に、`i_alloc_scalar_ready` は 1 に固定する (head でしか動かないので snoop は要らない、§3.4)。読出ポートは VU 専用に int 2 本と fp 1 本を足す (§3.2 の表に M5 からの追加として記載)。 |
| VA4 | 完了 (`vu_adapter`, `rob`, `wb_resv`): 完了は `rob` の VU 専用完了入力 `i_vu_done` (予約済み、調停なし) に `VuDone` を出して行う。これは §C.1.3 が認める 2 種類の完了入力の 1 つで、`rob` のヘッダに宣言する。scalar rd を書く op (VM4 の `o_wb_rd`、1 サイクル op だけ) は、wbm0 の HOLE_FILL 枠を登録済みの予約表から予約する。その枠のサイクルに `i_cdb_free=1` を返し、PRF への書込と完了を同時に行う。rd を書かない op は `o_wb_req` のサイクルにそのまま完了する。`i_cdb_free` は予約表と `o_wb_req/o_wb_rd` だけから作り、同じサイクルの issue へ組合せで戻る経路を作らない。 |
| VA5 | 側帯 (`commit`): `VecSide` は packet に載せて運び、`commit` の `vec_pending` レジスタ 1 本に置く。1 本で足りる理由: VEC は `nonspec=1, alone=1` なので、完了済みで未 retire の VEC op は常に高々 1 つしかない (F6 の `sys_pending` と同じ論法)。retire 時に適用し、full kill で捨てる。例外 (`ExcRec`) は `VuDone.exc` として `rob` に渡し、保持の方式は §C に従う。 |
| VA6 | kill (`vector_unit`): VM1 により dispatch FIFO は §5.4 の消費者になる。部分 kill が実行中の op を消すことは無い。実行中の op は最古であり、`keep` と等しいかそれより古いからである。full kill は、その op 自身の trap/flush でしか起きない (I3)。 |
| VA7 | 事前検査 (`vu_adapter`): `o_head.vtype_dep=1` で csr の `vtype.vill=1` の場合、または `o_head.is_fp=1` で SEW が 32/64 以外の場合は、VU に exec 許可を渡さない。代わりに illegal (cause 2) 付きで `VuDone` を出す。retire の TRAP による full kill で FIFO から消えるので、VM2 の `o_head` 以外に VU 側の変更は要らない。 |
| VA8 | 観測 (`vu_adapter`): VU の `o_vd_wen/o_vd_addr/o_vd_data` から、その op の VRF 書込回数と hash を作り、`VecSide` に入れる (V.7)。設計論理には戻さない。 |

### V.4 `vu_mem_adapter` と memory pipe 0

- 【決定】VU は `MEM_PIPE=0` で instantiate する。理由: `MEM_PIPE=1` の FETCH/ACCESS の 2 相は旧コアの M-stage のタイミング (無条件捕捉と、直前の要素の dcache 再読出が hit すること) に依存している (`vector_unit.veryl:35-43, 2752-2763`)。`MEM_PIPE=0` なら契約は「要素ごとに `i_mem_ready` か `i_mem_fault*` まで要求を保持する」だけになる。ただしこの arm は `a21c499` 以降に一度も動いておらず、`VINT_PIPE=1` と組み合わせた形 (`MEM_PIPE=0, VINT_PIPE=1`) は一度も動いたことがない。そこで M5 の最初の作業として再検証する (V.11)。
- 要素要求の受け方: `o_mem_active` は VU の状態と VRF の v0 読出から組合せで作られる。adapter は要素を要求レジスタに 1 回だけ取り込み、VRF からポートへの組合せ経路を切る。未完了の要素は常に高々 1 つで、MemTag は `{client: VU, id: 1 bit の世代, rob: その VEC op の RobTag}` とする (§5.9)。
- 【決定】VU は port 0 の生の client ではなく、memory pipe 0 の issue 段に入る client とする。理由: 要素アクセスには、AGU の pointer mask、DTLB lookup、`pmp_check`、`pma_check` が必要だからである。これらは memory pipe ごとに 1 つずつあり (§5.10)、VU 専用の lookup ポートを足すと MEM_W の軸の外に TLB ポートが増える。issue 枠は `mem_port_arb` が登録済み状態から 1 サイクル前に予約し、memory IQ はそのサイクルに pipe 0 を選ばない (MP3)。VU は port 0 の HEAD クラスの普通の要求者で、他のクラスと round-robin で並び、優先はしない (§L.14 の【決定】)。VU の待ちにも他の要求者の待ちにも MP4 の上限 B が適用される。
- VU client に対して `mem_pipe` が行う処理と行わない処理:
  - load は forward 判定と load 整形を行わず、生の 128 bit を返す。dword の選択は adapter が行う。応答の扱いは MP2 に従う: HIT ならその場で返し、MISS なら `fill_id` に park して FILL_CRIT/DONE/ABORT で再 issue し、RETRY なら再 issue する。
  - store は翻訳と PMP/PMA 検査だけを行い、dcache には要求を出さず、PA と属性を返す。
  - TLB miss のときは VEC op の RobTag を owner として `ptw` に要求を出し (§5.10 X4 が VU を要求者として認める)、walk の owner として XlateResp を受けるか、合流した waiter として `PtwEvent` を受けて lookup をやり直す (§5.10 X2)。
- 【決定】vector store の要素は `sb` に push する。push には VU 専用の入力 `sb.i_vu_push {pa, data<64>, strobe<8>}` を使い、`sb` に空きがあれば受理する。受理したサイクルを、その要素の `i_mem_ready` とする。理由: drain を `sb` の head だけが駆動するという「駆動者 = 持ち主」の構造 (MP7) を保てる。若い scalar load も、要素を `sb` から forward できる。要素を push してよいのは、op が exec 許可を得て取り消せなくなった (I3) 後なので、`sb` に「commit 済み」と同じ意味で入れてよい。`commit` は VEC op が head にある間は store を retire しないので、push 入力は排他になる。この排他は `chk_vu` で検査する。
- fault: 翻訳、PMP、PMA で生じた `ExcRec` (cause 5/7/13/15/21/23、tval、gpa、gva) を adapter が latch し、VU には `i_mem_fault`/`i_mem_fault_st` だけを渡す。VU は fault した要素で FSM を止め、`vstart` を出す。adapter は自分の `ExcRec` を `VuDone.exc` に入れる。これで旧コアの「PMP fault を落とす」「G-stage の cause と htval を live な MMU から拾う」の 2 つの穴 (`heliodor_core.veryl:5249, 6540-6547`) が構造的に消える。
- 【決定】EEW に自然整列していない要素は、adapter が要求を出さずに address-misaligned (load は cause 4、store は cause 6) とする。理由: RVV 1.0 は要素ごとに「転送するか、misaligned 例外か」を実装に任せている。旧コアは dword の中で黙って切り詰めていた (`vector_unit.veryl:1982-2001`)。
- NC/IO 領域への要素アクセスは §5.14 の【M5 で決定】に従う。fault 案を採った場合は、PMA の `cacheable=0` を検出した時点で access fault (cause 5/7) とする。
- 開始条件 (`sb` が所有): VU の `i_mem_idle` には `vu_mem_ok = sb.o_ordering_empty` を与える。MP7 により `ordering_empty` は `atomic_unit` の待ち行列を含む。これで旧 `vu_mem_idle` の欠けていた項のうち ASQ の項 (`heliodor_core.veryl:11324`) が入る。もう一方の LSR の項は不要になる。応答がタグで帰属し、ポートのアドレスを他者が上書きする経路が無いからである (MP2, MP3)。
- 【決定】VU は port 0 を占有しない。旧コアの `o_mem_port_req` による scalar load/AMO の issue 停止はやめ、この信号は `o_perf` の event にだけ使う。理由: 順序の正しさは V.5 の規則で保たれ、ポートの排他は不要である。占有をやめれば、待ちの間に `atomic_unit` が drain のために port 0 を必要としてデッドロックする形も生じない。

### V.5 メモリ順序の規則

| 関係 | 規則 | 所有者 |
|---|---|---|
| 古い scalar store → vector load | 古い store は retire 済みで `sb` にある。VU は最初の要素の前に `vu_mem_ok` を待つ。VU の load は forward しない。 | `sb`, `vu_mem_adapter` |
| 古い no-return AMO (待ち行列にある) → vector アクセス | `ordering_empty` は `atomic_unit` の待ち行列を含む (MP7)。旧コアの穴 (推定) を閉じる。 | `sb`, `atomic_unit` |
| 古い vector store → 若い scalar load | vector store の retire で RETIRE_FLUSH(NEXT_PC) をかけ、若い op をすべて再実行する。再実行した load は、`sb` からの forward か、drain 後の dcache から新しい値を得る。 | `commit` |
| 古い vector load → 若い scalar load (SMP の CoRR) | `lq` の CoRR line scan は、inv を受けた完了済み・未 retire の load を poison する。その条件を「同じ line のより古い load が LQ にいること」に依存させない。vector load は LQ にいないからである。 | `lq` |
| 古い vector op → 若い scalar store | 若い store は VEC op の retire まで SQ に留まる (commit 前)。 | `sq`, `commit` |
| vector → vector | VU の中で in-order に、1 op ずつ実行する。 | `vector_unit` |
| vector load の実行中の若い scalar load | pipe 0 で交互に実行してよい。cfg_w4 では pipe 1 も使える。旧コアの port 占有 (Rule A 違反) はやめる。 | `mem_port_arb` |

FENCE との関係は通常の規則で足りる: vector store の要素は `sb` に入るので、後続の FENCE の `drain` が待つ対象に含まれる。

### V.6 commit 規則と OpClass

§5.5 の VEC 行を次のように確定する。

| フィールド | 値 |
|---|---|
| `fu` / `nonspec` / `alone` | `VEC` / 1 / 1 |
| `drain` | 0。順序は V.4 の開始条件で取る (retire 時ではなく実行開始時に待つ)。 |
| `flush` | vector store (unit-stride、strided、indexed、segment、whole-register) は `NEXT_PC`、それ以外は `NONE`。vset は flush しない。decode が vtype に依存しないからである。 |
| `effect` | すべての VEC op: `VS_DIRTY`, `VSTART`。vset* と fault-only-first: `VCFG`。vector FP: `FFLAGS`, `FS_DIRTY`。vfmv.f.s: `FS_DIRTY`。固定小数点: `VXSAT`。 |
| `budget` | `VQ`。scalar rd を書く op はさらに `INT_RD` か `FP_RD`。 |

- retire (C1-C3): VEC op は lane 0 で単独で retire する。retire[0] だけを条件に次を行う: `vcfg_v` なら csr の vtype/vl を書く。vstart を書く (成功時は 0)。fflags と vxsat を OR する。VS を Dirty にし、`FS_DIRTY` を持つ op なら FS も Dirty にする。旧コアは vector の CSR 副作用を valid で gate していた (冪等なので安全だった) が、新コアは C3 に揃えて retire だけで gate する。
- TRAP: `VuDone.exc` があれば lane 0 で TRAP する。trap しても vstart を書き、それまでの VRF 書込は残る。これは §5.8 に書かれた唯一の例外である。
- full kill のときの VU の復元: VU は flush の時点で、作業用 vtype/vl を csr の commit 済みの値から読み直す。kill は retire の次のサイクルに登録済みで出るので (§5.4)、retire 済みの vset はその時点で必ず csr に反映されている。
- 合法性 (`decode`, §5.5): mstatus.VS=Off のとき、または V=1 で vsstatus.VS=Off のときは、vector op と vector CSR へのアクセスを `NONE` + illegal にする。vector FP op は、さらに FS=Off (V=1 では vsstatus.FS も) を検査する。reserved encoding (`vssubu.vi` など、`decoder.veryl:1186-1188`) も illegal にする。csr には追加だけの変更を入れる: `o_vsstatus_vs` の export と、`i_vs_dirty` 入力。
- 割込み: 【決定】実行を始めた VEC op には割り込まない (I3)。要素境界での割込み (vstart による再開) はしない。理由: VU は再開時に vstart を無視して要素 0 からやり直すので (V.9)、要素境界で割り込むと正しくない。その代わり、割込みの受付遅延の上限には最長の vector op が入る (V.10)。

### V.7 golden での可視性

- 【決定】`retire_pkg::RetireRec` に vector 用のフィールド `{vec_v, vrf_wcnt, vrf_hash, vtype, vl, vstart}` を足す。値は `VecSide` から取る。`vrf_hash` は、`(vd, data)` を書込順に畳み込む順序依存の 64 bit 関数で、`retire_pkg` に 1 つだけ置く。vector のメモリアクセスについては `mem_*` を 0 とし、比較の対象外 (MASK) にする。
- golden 側では、D1 の retire adapter が `b0f4668` の `u_vrf` の書込ポートを監視し、head の vector op の retire record にその hash を載せる。旧コアでも VU は head でしか書かないので、ある op の VRF 書込は、その op が head に来てから retire するまでの間に限られる。【決定】このフィールドは D1 パッチの最初の版に入れる。理由: パッチを変更すると golden の成果物をすべて作り直すことになる (D1)。
- 用途: lockstep の対象は 5.15 N=1 だけである (D4)。vector の trace diff は 20 本の V テストと 7.1+V boot のデバッグ道具であり、ゲートではない。新コアが直した既知の差異 (V.9) は、テストごとの allow-list で吸収する。

### V.8 ReOVE との比較

ReOVE (Kimura and Shioya, ISLPED '24) は OoO コアに vector を載せる方式で、vector 同士の並べ替えをやめ、vector と scalar の並べ替えだけを残す。完全な OoO 構成に比べて性能 -2.7 %、面積 -21.1 %、エネルギー -21.9 % と報告されている (Sniper、RiVec/FFT/SpMV、P670 相当の baseline)。

| 項目 | ReOVE | heliodor M5 |
|---|---|---|
| Constraint 1 (vector は古い命令を待つ) | 古い命令が「実行済み」になるまで待つ。wakeup matrix の列を立てて実現する。 | より強い: 古い命令が「retire 済み」になるまで待つ (exec 許可 = oldest token)。 |
| Constraint 2 (若い命令は vector を待つ) | 緩和する。若い scalar は vector を追い越せる。 | 同じく緩和する。若い scalar は issue・実行・memory pipe 0 を使える。ただし retire は追い越せないので、重なりは ROB_N で頭打ちになる。 |
| 規則 2: 古い scalar store → vector load | vector load が scalar LSQ を粗い粒度で検索し、hit したら store の書込後に再実行する。 | 古い store は retire 済み。`sb.ordering_empty` を待てば足り、LSQ の検索は要らない。 |
| 規則 3: vector → vector | FIFO と scoreboard で in-order。vector の rename はしない。 | 同じ (VU FIFO、VRF は rename しない)。 |
| 規則 4: 古い vector store → 若い scalar load | vector store が LSQ を line/page 単位で検索し、hit したときだけ flush する。 | 無条件に flush する (retire 時の RETIRE_FLUSH)。 |
| vector のメモリ経路 | cache と store buffer に直接アクセスする。vector LSQ は持たない。 | 同じ (load は pipe 0 経由、store は `sb`)。 |

Constraint 1 を強めたままにする理由【決定】:

1. 再利用する VU は head でしか動かない。
2. D5 は順序違反を commit 時の replay で回復する。このため、古い load は retire するまで「実行済み」とは言えない。「実行済み」を境界にすると、rename していない VRF への書込を巻き戻す手段が要る。

拡張の道筋 (どちらも Phase 15 の範囲外で、測ってから決める):

- (a) 規則 4 の精密化: vector store が line の範囲を `lq` の CoRR line scan に投入し、完了済みの若い load を poison する。無条件の flush は REPLAY に置き換わる。判断材料は、vector store による flush の回数と、それで再取得した op 数。
- (b) exec 境界の緩和: 「未解決の分岐、fault しうる op、replay しうる load」のうち最古のものを境界にする。VU は許可しか見ないので、変更は `vu_adapter` と境界の生成で閉じる。前提として VA3 の gate を論理に入れる。

### V.9 既知の RVV 適合性ギャップと M5 計画

| # | 旧コアの挙動 | M5 の計画 | 場所 |
|---|---|---|---|
| G1 | 不正・未実装の OP-V が head で wedge する (推定) | M1 から `NONE` + illegal。M5 でも未実装の encoding は illegal のまま。 | `decode` |
| G2 | VS=Off の op が実行されてから commit で trap する (VRF やメモリが書き換わる) | decode で合法性を検査する。 | `decode` |
| G3 | V=1 で vsstatus.VS を見ない。VS=Off でも vector CSR へのアクセスが trap しない | decode で合法性を検査する。csr に `o_vsstatus_vs` を追加する。 | `decode`, `csr` |
| G4 | VS が Dirty にならない。vfmv.f.s と vector FP が FS を Dirty にせず、FS=Off も検査しない | `effect` で VS/FS を Dirty にする (V.6)。decode で FS を検査する。 | `commit`, `decode` |
| G5 | vill が強制されない。reserved bit や SEW > LMUL×ELEN を vill と判定しない | 強制は VA7 で行う。判定の修正は VU の vset 論理を直す (VM 群と同時に入れ、v14 は凍結コピー)。 | `vu_adapter`, `vector_unit` |
| G6 | 算術 op が vstart を 0 に戻さない | VEC op の retire で必ず vstart を書く (V.6)。 | `commit` |
| G7 | 再開時に vstart を無視し、要素 0 からやり直す | 【M5 で決定】7.1+V boot と V テストで、vstart≠0 で再開した回数を数える。0 なら上限として宣言し、0 でなければ VU を修正する。 | `vector_unit` |
| G8 | mask された要素と tail の要素に、load が 0 を書く (どちらの policy でも違反) | VU を修正する。ALU op と同じく、古い vd と merge する。 | `vector_unit` |
| G9 | misaligned な要素を黙って切り詰める | address-misaligned 例外にする (V.4)。 | `vu_mem_adapter` |
| G10 | PMP fault を落とす。G-stage fault の cause/htval が誤る | port の `ExcRec` で報告する (V.4)。 | `vu_mem_adapter` |
| G11 | VU のアドレスに pointer mask (Supm/Ssnpm) をかけない | `mem_pipe` 0 が VU client にも同じ関数をかける。 | `mem_pipe` |
| G12 | reserved encoding (`vssubu.vi` など) を実行してしまう | decode で illegal にする。 | `decode` |
| G13 | 未実装: vmv.s.x、vmv<nr>r.v、vmacc 系、vadc/vsbc/vmadc/vmsbc、vzext/vsext、vwmacc 系、strided/indexed/fault-only-first の segment | M5 では illegal として trap させる。実装するかどうかは M5 の後に判断する (下記)。 | `decode` (`vector_unit`) |

G13 (基本 RVV の未実装 encoding) と RVA23 の未実装 V 拡張 (Zvbb, Zvfhmin, Zvkt) の扱い: §2.6 に従い、M5 の後に RVA23 の不足分とまとめてユーザが判断する (M0 時点の選択肢のうち (2) を採る)。M5 の範囲では実装せず、illegal として trap させる。理由: G13 が無くても、20 本の V テストと 7.1+V boot は通る (旧コアで実証済み)。M5 の目的は統合の構造であり、ISA の拡張ではない。ただし README の「complete RVA23」は M5 の時点で事実と食い違うので、記述の修正だけは M5 で行う。

- G13 の一覧はコード調査 (`decoder` と `vector_unit` の静的な読み) から作ったものであり、実行で確かめていない。M5 で、各 encoding を 1 つずつ実行する directed test によって「未実装 = illegal で trap する」ことを確かめ直し、一覧を確定させる。

### V.10 VU の上限 (§3.4 への登録)

| 上限 | 値 | 処置 |
|---|---|---|
| ROB_N ≤ 256、かつ 2 の冪 | VM1 と VM3 の後は消える | M5 で解消する。M5 より前は VU を instantiate しないので、この制約は掛からない。 |
| VLEN | 128 固定 (`vector_pkg`、VU 内のリテラル 45 か所) | 宣言された上限として残す。 |
| alloc | rename group あたり 1、1 サイクルに 1 | 宣言された上限として残す (§3.2)。 |
| 実行 | 1 op ずつ、oldest token を持つときだけ | 宣言された上限として残す。exec 境界の緩和は V.8 (b)。 |
| dispatch FIFO | 8 エントリ (2 の冪) | `VQ` の credit。 |
| メモリ | 未完了の要素は 1 つ。1 要素は 8 B 以下。pipe 0 だけを使う。hit が続く場合でも、1 要素あたり約 `RESP_LAT`+1 サイクル (推定) | 宣言された上限として残す。line 幅のアクセスや複数 pipe の利用は再設計を要する。 |
| PRF 読出ポート | VU 専用に int 2 本と fp 1 本 | `prf` の読出ポート数に加算する。 |
| hart ごとの専用 `fpu_wrap` と `int_divider` | 面積とシミュレーション速度を食う | 宣言する。シミュレーション上の割合は M5 で測る (リスク R1)。 |
| 割込みの受付遅延 | 最長の vector op 1 本分 (例: LMUL=8 の要素直列 vdiv、または要素ごとに miss する load) | 宣言する (V.6)。 |

### V.11 M5 の作業順とゲート

1. `MEM_PIPE=0` の arm を再検証する。
   - (a) 旧コアのブランチで core と VU の `MEM_PIPE` を 0 にし、20 本の V テストと `test_vmspre` を回す。
   - (b) 旧コアの側の `MEM_PIPE=0` の arm が腐っていて (a) が使えない場合は、新コアの上で直接統合する。V.7 の `vrf_hash` の trace diff で最初に食い違う vector op を見つけ、VU の arm の問題か adapter の問題かを切り分ける。
2. 旧コア上の directed test で、推定段階の旧コアのバグを確かめる (D4)。対象は、`amoadd x0` の直後に同じ line へ `vle` を出す ASQ の穴、LSR が残っている状態での VU 要素の読出、不正な OP-V の wedge。
3. `v14_vector_unit` を凍結し、旧コアのビット一致を確認する。その後に VM1-VM4 と G5/G8 を入れる。
4. `vu_adapter`、`vu_mem_adapter`、`sb.i_vu_push`、`mem_pipe` 0 の VU client、decode の合法性、commit の VEC 規則、csr への追加を入れる。
5. ゲート:
   - 20 本の `test_arch_v*` と `test_vmspre`
   - G2-G12 を 1 つずつ確かめる新しい directed test
   - 7.1+V の N=1 boot (pass/fail)
   - hvlinux
   - N=4 boot (memory pipe と `sb` を変えるので、§2.5 M4 の規則により必須)
   - `chk_vu` (VA3、VA4 の二重完了、`i_vu_push` と commit の push の排他) がすべてのテストで 0
   - `o_perf` の VU event (exec 許可の待ち、`vu_mem_ok` の待ち、vector store による flush) がどこかのゲートで 0 より大きいこと
6. 【M5 で決定】N=2 の vector ゲートを足すかどうか。旧コアには SMP の vector テストが無い。判断材料は、7.1+V の SMP カーネルで N=2 boot を作るコストと、V.5 の CoRR 規則を directed test で代替できるかどうか。

---

## リスクと未決事項

本章は 2 つの部分からなる。前半はリスク登録簿で、Phase 15 全体を通じて監視するリスクを、所有するマイルストーン、早期警報、緩和策とともに挙げる。後半は未決事項の一覧で、第 0 部が後のマイルストーンに送った判断と、M0 の調査で答えが出なかった問いのうちどの章にも属さないものを 1 つの表にまとめる。各章 (§F から §S) が自分の中で閉じている未決事項は、ここには再掲しない。

### リスク登録簿

各リスクには ID、所有マイルストーン、早期警報 (気付くための観測)、緩和策を記す。数値の出所は、旧コアの `.build/test_timings` (検証計画 §6.1) と、各項に引いたコードと commit である。

#### R1. シミュレーション速度と N=4 の崖

- 内容: 旧コアの 5.15 boot の速度は、N=1/2/4/8 でそれぞれ 84.0k/36.5k/6.64k/2.41k cy/s である。hart-cycle あたりに直すと 84.0k/73.1k/26.6k/19.2k になり、N=2 から N=4 で約 2.7 倍の段差がある。2026-06-11 の matched 測定ではほぼ線形 (251k/118k/50.6k cy/s) だったので、この段差はその後に現れた。原因は測られていない。今のゲートの梯子 (litmus4、N2、N4、hvlinux) は直列に回して約 5,008 秒かかり、そのうち 76 % を N4 boot が占める。2 構成で回すと約 167 分になる。cfg_w4 の 1 サイクルあたりのコストを k 倍とすると、k=2 で N4 boot が約 2 時間、梯子全体が約 4 時間になる (推定)。
- 所有: 測定は M1a (spike の対照測定)、判断は M3 (D7)。
- 早期警報:
  - 各マイルストーンで記録する cy/s (§5.15)。
  - `VERYL_AOT_C_DIAG=1` / `VERYL_AOT_C_EVENT_DIAG=1` で見た fallback の数。
  - skeleton と旧コアの N=1 での cy/s の比。
  - lane の uop struct の幅。128 bit を超えると wide 経路になり、旧コアの 512 bit 読出は 256 bit の約 6 倍遅かった。
- 緩和策:
  - (1) 対照を先に取る。旧コアの N=1 boot で DIAG を測り、whole-comb が成立しているかを確かめる。
  - (2) 同じ木・同じマシンで、`VERYL_AOT_C_ASYNC=0` と profile build を使い、N=1/2/4 を直列に matched 測定する (D7 注)。
  - (3) cc は lane×hart の数だけ C ソースと gcc の時間が増える。そのため lane の payload は所有モジュール側に寄せ、段境界を流れる struct を細く保つ。
  - (4) 2 構成は並行 worktree で回す (U3、採用済み)。N=4 の判定を Verilator で行うか (約 1.6 倍速い) は、D7 と合わせて M3 で決める (U2)。
  - (5) N=4 boot は節目と、メモリ系の変更時に限って回す (§2.5 M4)。

#### R2. Veryl の generics の成熟度と §3.7 の spike

- 内容: §3.6 の運び手は、analyzer と emitter のテストでしか確認されていない。対象は、generic module、proto package に束縛した generic package、`core_types::<CFG>` の import、struct 配列ポート。simulator にはこれらの単体テストが無い。toolchain の変化も速く、2026-07-01 以降に `fix(simulator)` が 92 件、`fix(analyzer)` が 61 件ある。過去には struct 配列について simulator のバグが 3 件あった。旧コアには回避コードが残っているが、それが今も必要かは確かめられていない。該当するのは、部分 squash の動的書込の消失、代入後の field 上書きの消失、後方参照する配列での settle hang で、どれも新しい ROB の walk と IQ の squash がそのまま使う形である。また AOT-C は `$assert` を emit しないので、RTL に置くとその event が Cranelift に落ちる。
- 所有: M1a (spike がゲート。SoC 統合より前に置く)。
- 早期警報:
  - spike の単体テストの失敗。
  - whole-comb の fallback が 0 でない。
  - native と Verilator の結果の食い違い。
  - veryl を更新した後の lint の警告種別の増加。
- 緩和策:
  - (1) §3.7 の各構文ごとに、veryl clone 側に simulator の単体テストを足す。旧コアの 3 つの回避コードについても、現行の veryl で単体テストを書いて再検証する (U5)。
  - (2) バグは clone 側で直し、heliodor 側では回避しない。
  - (3) spike が通らなければ、§3.7 の fallback (`#[ifdef]` で選ぶ素の config パッケージ) に切り替える。import 規則 (§3.6) を守っていれば、モジュール本体は変わらない。
  - (4) veryl の版はマイルストーンごとに固定し、更新するときは旧コアのビット一致 (dhrystone/coremark) と lint 差分を確認する (U4)。

#### R3. 第二システム症候群

- 内容: 作り直しの機会に、旧コアに無かった機能や過度に一般化した抽象を積み増してしまう危険がある。例: RVA23 の追加拡張、MLP、依存予測、早期の checkpoint、FU や予測器の過剰な proto 化、旧コアとの性能パリティの追求。旧コアは 1 つのモジュールが 13,315 行に膨らみ、bit knob を 62 個持っていた。また、天井が小さいと実測された機構 (MLP 1.26 %、依存予測 0.13 %) にも労力を費やしていた。
- 所有: 全マイルストーン。scope の判定はユーザが行う。
- 早期警報:
  - 600 行を超えるモジュール (§2.2 M4)。
  - `const/param X: bit` の出現 (P4)。
  - §2.6 の非目標や §3 の表に無い機構が設計に現れる。
  - 再利用モジュールに「ついでの」変更が入る (§4.4 の追加のみ規則に反する)。
  - skeleton の正しさより先に sweep や性能調整が始まる。
  - マイルストーンの遅延。
- 緩和策:
  - (1) M1 は最も単純な policy で最終構造だけを作る walking skeleton とし、M1a (基盤) と M1b (rv64ui に要るものだけ) に分ける (§2.5)。
  - (2) 新しい機構を入れるときは、測定した天井を根拠にする (§2.4)。
  - (3) 実験はブランチで行う。
  - (4) 各マイルストーンの終わりに、scope の変更点をユーザに候補として示し、判断を委ねる。

#### R4. golden モデルの網羅の穴

- 内容: lockstep の対象は 5.15 N=1 だけである (D4)。7.1+ADUE、SMP、H/V、vector は pass/fail でしか判定しない。golden 自身にも、確定したバグや推定段階のバグがある。例: minstret の数え漏れ、偽 ifault と satp 書込の欠落、FP div と s2 の WB 衝突、AMO のページ権限の穴、ASQ の aq/rl、VU のギャップ (§V.9)。さらに、パッチを当てた旧コアが mtime-by-instret モードで 5.15 を最後まで boot できるかは、一度も走らせていない。割込みの replay で allow が足りるか force が要るかの頻度も分かっていない。ACT4 には H、V、割込みのスイートが無い。
- 所有: M1a (パッチと retire adapter、D1 の受入)、M2 (lockstep と directed test)、M4/M5 (pass/fail だけで判定する領域)。
- 早期警報:
  - allow-list の項目が増える速さ。
  - 原因の分からない trace の食い違い。
  - tick モードの golden の boot の timeout。
  - replay で「golden の割込みが自コアで pending でない」と失敗した回数。
- 緩和策:
  - (1) D1 の受入条件 (ビット一致) を満たした後、tick モードの boot を M1a の時点で走らせる (U11)。
  - (2) 推定段階のバグは、M2 の前に golden 上の directed test で確かめ、allow-list のタグに結び付ける (U17)。
  - (3) lockstep が届かない領域は、§5.15 の発火カウンタ、`chk_*`、litmus、hvlinux で覆う。
  - (4) vector の trace diff には、D1 パッチの最初の版から `vrf_hash` を載せておく (§V.7)。

#### R5. 載せ替え後のテスト時間

- 内容: D3 は、bare の flat-memory ハーネスで動いていた約 936 テストを、L2 と mem_ctrl を持つ SoC に載せ替える。1 テストあたりのモデル構築とメモリの遅延が増えるので、今は数十秒から 1 分程度で終わる default suite が何倍になるかは分からない。旧コアと新コアが master に共存し (D6)、2 構成を回すので、ビルド対象も増える。
- 所有: M1a (約 20 テストで時間を測る、D3)、M2 (全体)。
- 早期警報:
  - テスト 1 本あたりの壁時間の中央値と、bare での値との比。
  - default suite の総時間。
  - モデルの構築時間。
- 緩和策:
  - (1) 遅すぎれば、D3 にあるとおり flat-memory slot adapter に切り替える。
  - (2) retire ポートで pass を検出し、早期終了する。
  - (3) DUT-reuse cache が効くように、テスト top の形を揃える。
  - (4) 構成ごとに worktree を分けて並行に回す (U3、採用済み)。

#### R6. 再利用モジュールの隠れた天井

- 内容: M0 の調査で見つけた再利用モジュールの天井は、§3.4 に「宣言された上限」として載っている。ただし、sweep が新しい天井を掘り当てる可能性は残る。既知のものは次のとおり。
  - dcache: data の読出が 1 サイクルに 1 本。fill 文脈が 1 本。
  - icache: CPU ポートが 64 bit。
  - TLB: 旧 mmu ではサイズがリテラル (新しい `tlb` は M2 から `ENTRIES` パラメータを持つので、新コアでは解消している)。
  - csr: instret の増分が 1 bit。
  - mem_ctrl: `o_inst_hart = h as 3`。
  - hart 数: 8 以下。
  - `fpu_wrap`: タグ幅の既定値がパッケージと偶然一致しているだけ。
  - VU: 各種の上限 (§V.10)。
- 所有: M1b (宣言と elaborate 時の拒否)、M3 (dcache、MMU、icache)、M5 (VU)。
- 早期警報:
  - sweep で、ある軸を増やしても IPC が平らなまま (§2.5 M3)。
  - 幅の不一致の lint 警告。
  - `o_perf` の RETRY の理由別の比率 (BANK_CONFLICT、FILL_BUSY)。
- 緩和策:
  - (1) 平らな軸は原因を特定して §3.4 に登録する。
  - (2) 支援外の値は `CFG_ERR` と `test_cfg_constraints` で拒否する (§3.5)。
  - (3) 天井を上げる変更 (N_FILL>1 など) は N=4 boot を入口のゲートにする。`95753c8` では、N=1 でビット一致のまま N=4 がライブロックした。

#### R7. cfg_w4 の腐敗

- 内容: M3 までのゲートは cfg_w2 で回す。そのため、lane 数が 2 を超える経路や MEM_W=2 の経路が使われないまま腐る危険がある (旧コアの ID_SPLIT=0 の arm と同じ類)。
- 所有: M1-M3。
- 早期警報:
  - cfg_w4 の rv64ui のサブセットの失敗や elaborate の警告。
  - `RETRY(BANK_CONFLICT)` の発火カウンタが 0。
- 緩和策: cfg_w4 を elaborate し、rv64ui のサブセットを回すことを、M1b から default suite に入れる (§3.2)。

#### R8. SMP でしか出ない退行

- 内容: N=1 で正しく見えた変更が N=4 で固まった例がある。MSHR ALLOC は 18 コミット、3 週間にわたって見逃された。ゲスト Linux も 2 か月壊れていた。litmus N=4 は N=4 boot の代わりにならない。
- 所有: M3 (dcache の 2 ポート化。新コアの SMP が無いので N=1 のゲートで検査し、`MSHR_N=1` に留める)、M4、M5。
- 早期警報: 書き上げる前に N=2 boot を回すこと。メモリ系の変更のたびに N=4 boot を回すこと。
- 緩和策:
  - (1) 新コアの SMP は M4 から存在するので、M3 では天井を上げるメモリ系の変更 (`MSHR_N`/`N_FILL` > 1) を出荷しない。それらは M4 で新コアの N=4 boot ができた後に限り、コミットごとに N=4 boot をゲートとする (§2.5)。M3 の 2 ポート化そのものは `MSHR_N=1` で N=1 のゲートを通す。旧コアの N=4 boot を使う N2.2a の原因調査 (§M.6.1) は M3 で行う。
  - (2) hvlinux を梯子に入れたままにする。

### 未決事項の一覧

出所の列: 「§n」は第 0 部の該当箇所にある【M<n> で決定】、「D7」は第 0 部 §1.4 のユーザ決定に付いた期限、「調査:」は M0 の調査で答えが出なかった問い (括弧内はその分野)。調査の問いのうち、第 0 部で解決済みのものと、ある章に明確に属するものは載せない。本書に残る【要判断】は無い。U3 は採用済み、U16 は M5 の後に送ってあり、それ以外は【M<n> で決定】である。

| # | 項目 | 出所 | 期限 | 何を測るか / 選択肢と推奨 |
|---|---|---|---|---|
| U1 | N=4 boot のゲートを両構成で回すか | D7 | M3 | matched な N=1/2/4 の測定で崖の原因を特定した後、cfg_w4 の cy/s から梯子全体の時間を見積もって決める。 |
| U2 | 【M3 で決定】N=4 の判定を Verilator で行うか (D7 と合わせて決める) | 調査 (シミュレーション速度)、D7 | M3 | U1 の matched 測定と同じ機会に、N=4 boot の壁時間を native と Verilator (`-O1`) の両方で測り、梯子全体の時間で比べる。候補: native だけ、N=4 だけ Verilator、併用。初期の見込みは「N=4 boot は Verilator を正とし、native は N=1/2 と節目の N=4」。Verilator は約 1.6 倍速く、NBA の基準でもある。ただし `-O1` が要り、veryl の cache は効かない。決めた方針は M4 から適用する。 |
| U3 | 2 構成を並行 worktree で回すか: 採用済み (第 0 部 §1.4 の運用) | 調査 (シミュレーション速度) | M1a から適用 | マシンは 16 CPU で、各シミュレーションは単一スレッドで動く。veryl は同時に 1 起動しか許さないので、`.build` を分けるには worktree を分ける必要がある。 |
| U4 | 新コアで使う veryl の版 | 調査 (Veryl) | M1a 開始時 | 【決定済み (§3.7.1)】新コアは `local/heliodor-fixes` の veryl を使う。旧コアはこの版でも dhrystone/coremark がビット一致する。 |
| U5 | 旧コアの simulator 回避コードは今も必要か | 調査 (Veryl) | M1a | 部分 squash の動的書込、代入後の field 上書き、後方参照する配列の settle の 3 つを、spike の単体テストとして現行の veryl で再現させてみる。 |
| U6 | 拒否の仕組み | §3.5 | M1a | 【決定済み (§3.7.1)】`#[test] test_cfg_constraints` で全構成の `core_types::CFG_ERR` を検査する (§3.5)。 |
| U7 | checker を synth から外す方法 | §5.15 | M1a | 【決定済み (§3.7.1)】`#[ifdef(HELIODOR_CHK)]` で囲み、`[test].defines` にだけ定義する。 |
| U8 | `RESP_LAT` の値 | §5.9 MP1 | M1b | adapter を実装し、Stage-A の提示から Stage-B の判定までの距離で決める (2 を見込む)。 |
| U9 | CP の基準値 | 調査 (過去の教訓) | M1a | 現行の synth で `b0f4668` を合成し直して基準を取る。2026-06-15 から 08-28 の CP の数値は無効である (synth がゲートの 52.5 % しか見ていなかった)。 |
| U10 | cranelift backend の到達範囲と `--backend-validate` の可否 | 調査 (Veryl) | M1a | spike は cranelift で通る (§3.7.1)。skeleton 規模での到達範囲は M1b で測る。 |
| U11 | パッチを当てた旧コアが tick モードで 5.15 N=1 を完走するか | 調査 (検証) | M1a | D1 の受入の後に 1 回走らせる。timeout や drain の問題がないかを確認する。 |
| U12 | 5.15 boot が cycle/instret/hpm の CSR や MMIO の mtime を読むか | 調査 (検証) | M1a | tracer で数える。読むなら、MASK にするか、csr に mcycle-by-instret を足すかを決める。 |
| U13 | 割込み replay で allow と force のどちらが要るか | 調査 (検証) | M2 | 5.15 lockstep で、「golden の割込みが自コアで pending でない」が起きる頻度を測る (D2)。 |
| U14 | golden 成果物の置き場所と commit の方針 | 調査 (検証) | M1a | schedule と hash の列 (小さい) は commit し、boot の trace (約 1 GB) は再生成する方式を推奨する。 |
| U15 | ACT4 の非既定スイートと H/V の directed test を、マイルストーンのタグ付きで commit するか | 調査 (ISA の網羅) | M2 | ACT4 の tb は gitignore されており、再生成には sandbox を外す必要がある。ゲートの再現性を優先して commit を推奨する。Sstc、Sscofpmf、Supm、Zawrs (ACT4 に無い) の directed test も同じ一覧に入れる。 |
| U16 | ISA の目標と README の「complete RVA23」: M5 の後に送る | 調査 (ISA の網羅、vector) | M5 の後 (README の記述修正は M5) | 第 0 部 §2.6 で M5 の後に送ってある。§V.9 の G13 (基本 RVV の未実装 encoding) と RVA23 の不足分とまとめて、M5 の後にユーザが判断する。M5 では実装せず illegal で trap させ、README の「complete RVA23」の記述だけを直す。G13 の一覧はコード調査から作ったものなので、M5 で directed test によって確かめ直す (§V.9)。 |
| U17 | 推定段階の旧コアのバグを確かめる directed test 群 | 調査 (複数) | M2 の前 (VU 関係は M5 の前) | 対象: minstret の数え漏れ、FP div と s2 の WB 衝突、AMO のページ権限の穴、ASQ の aq/rl、dword をまたぐ命令の fault の穴、`vu_mem_idle` の ASQ/LSR の穴、不正な OP-V の wedge。D4 に従い、結果を allow-list のタグに結び付ける。 |
| U18 | BRU ポート数 (cfg_w4) | §3.2 | M3 | 1 サイクルの resolve 数を sweep する。 |
| U19 | dcache の data bank 数 (cfg_w4) | §3.2 | M3 | 2 ポート化したときの bank conflict 率を sweep で測る。 |
| U20 | PRF の書込/読出ポート数と `PORT_FU` (cfg_w4) | §3.2, §5.7 | M3 | FU ごとの使用率を sweep で測る。 |
| U21 | 構造サイズの最終値 | §3.3 | M3 | 1 軸ずつ sweep し、IPC 曲線の膝で決める。 |
| U22 | `NUM_CKPT` | §3.3 | M3 | walk のサイクル数と、mispredict 1 回あたりの回復コストを測る。pool が枯渇して walk に落ちる経路が、少なくとも 1 構成で定常的に発火していること。 |
| U23 | walk の途中で、より古い kill を受け入れるか | §5.4 T9 | M3 | walk 中に捨てた resolve の数と回復コストの積を測る。 |
| U24 | amocas.q の形 | §5.5 | M2 | crack する案と `PAIR_RD` の案を、ACT4 の Zacas テストを通す実装で比べる。追加の RAT ポートが要らない方を採る。 |
| U25 | スカラ FMA で `STAGE3` を使うか | §5.6 | M3 | rm を s1a に載せる leaf の修正の後に、CP の分解でこの段が律速になっているかを見る。 |
| U26 | 投機的な load-hit wakeup | §5.7 | M3 | latency sweep で、load-use 鎖の密度に対する IPC の感度を測る。 |
| U27 | D-PTW を L2 直結にするか | §5.9 | M3 | W4 の sweep で port 0 の占有率をクラス別に測り、PTW が上位 2 位以内に入った場合に限って評価する。 |
| U28 | DRAM 内の Svpbmt NC/IO | §5.11 | M2 | 基本線の実装で、ACT4 の Svpbmt テストと `svpbmt_test` が通ることを確認する。 |
| U29 | NC load の投機的な発行 | §5.14 | M3 | boot と bench で NC load の発生数を数える。0 なら head 発行のまま確定する。 |
| U30 | VU の IO アクセス | §5.14 | M5 | IO 領域への vector アクセスの数を数える。0 なら fault にする (§V.4)。 |
| U31 | 本書の編集上の積み残し | M0 のレビュー | M1a (ヘッダ雛形は M1b) | 完了 (2026-10-14): 規則の正本を 1 か所に決め、他の箇所は参照と 1 行の要約にした (PC の保持者と読み手は §F.3、commit の PC 導出は §C.2.3、割込みの受付は §5.13、FENCE 系の OpClass は §5.5 で retire 時の動作は §C.6、adapter の規則は §M.2、kill の消費者表は §5.4、I read slot の調停は §M.5、`MSHR_N` を増やす条件は §2.5)。各章の「防ぐバグ類」と経緯だけの旧コアの参照は付録に移し、§1.6 の用語集と §5.1 の型の索引を補った。設計の変更は伴わない。続けて、章の間で食い違っていた規則 7 件を正本側に揃えた: adapter の MISS 判定 (E1 の latch 値、`o_miss_valid` は使わない) と保持 slot の駆動 (fold 群と nf 群) は §M.2 を正とし §5.9 は参照だけにした。commit の retire 式は §C.2.2 を正とし §5.12 C1 は要約と参照にした (`alone_eff` が足すのは IO だけなので、§5.5 の load の行を IO (alone=1) と NC (nonspec だが alone=0) に分けた)。store の retire 予算は §C.2.2 の `n_st <= MEM_W`、`n_line <= min(PUSH_W, sb_credit)` (credit は line 単位) に §L.9 を揃えた。dispatch snapshot に `bar_seq` を足した (§C.1.6)。`i_dbg_irq_allow` が `limit_en` を要すること (§C.2.6) を §5.13 の表に書いた。HFENCE.*/HINVAL.* の retire 条件を SFENCE.VMA と同じ (`ordering_empty` + `sys_pending`) にした (§C.6)。残り (M1b): cold-reader gate の対象モジュールすべてに §5.15 書式のヘッダ雛形を置く。 |

---

## マイルストーン計画

本章は本文の最後の章であり、M0-M6 の各マイルストーンについて、目標、作業の順序、実装する章とモジュール、出口条件 (ゲート)、そのマイルストーンの中で決める事項をまとめる。出口条件のゲート ID は検証計画 §1.1、構成ごとの投入時期は検証計画 §1.2、機能ゲートと構造ゲートの区分は第 0 部 §2.5 に従う。各章の出荷範囲の表 (§F.11、§R.7、§X.12、§C.0、§L.18、§M.1、§S.8、§V.11) は本章の要約の正本であり、ここではそれを順序と出口に並べ直すだけで、範囲を足しも削りもしない。決定事項の番号 U<n> は「リスクと未決事項」章の一覧のものである。

全マイルストーンに共通する規則:

- V14 (master 上の旧コア) は M6 まで既定コアであり、CLAUDE.md の回帰の梯子 1-5 (既定、litmus4、N=2 boot、N=4 boot、hvlinux) を通り続ける (D6)。共有モジュールに触れるコミットでは V14 の dhrystone/coremark の cycles と instret のビット一致を受入条件にする (第 0 部 §4.4、検証計画 §1.3)。
- 2 つの構成 (cfg_w2、cfg_w4) は別々の git worktree で並行に回す (第 0 部 §1.4 の運用、U3)。
- 各マイルストーンの末に、GS (cy/s と whole-comb fallback) と GF (発火行列) を記録し、scope の変更点をユーザに候補として示して判断を委ねる (リスク R3)。
- 新しく取り込むモジュールは、取り込んだマイルストーンで cold-reader gate を通す (第 0 部 §2.1 P5、§5.15)。

### M0: 設計文書と独立レビュー

- 目標: 本書 (第 0 部と §F-§V、リスクと未決事項、本章) と検証計画を確定させる。
- 作業: (1) 各章の起草と第 0 部への統合 (D1-D8 の反映)。(2) 独立レビュー: プロジェクトに関わっていないレビュア (人、または本書と検証計画だけを渡した新しいセッション) が、各契約を「所有者と検査方法を持つ不変条件」として読めるかを確かめる。旧コアや経緯を読まなければ答えられない質問が出たら、本書の欠陥として直す。
- 出口: レビューの指摘がすべて本文の修正か【M<n> で決定】への登録で閉じていること。本書に【要判断】が残っていないこと。

### M1a: 基盤

目標: 新コアの RTL を書き始める前に、旧コア側の前提作業、統合 SoC、golden、ツールチェーンを揃える。M1a の終わりに新コアのモジュールは 1 つも無くてよい。

作業 (この順に行う):

1. 死んだハーネスの削除: `test_arch_common_harness_dbg` (どこからも instantiate されていない)、`test_smoke`、`test_hello`、`test_linux_boot` (forensic `o_dbg_*` の唯一の消費者) を消す (検証計画 §2.4)。v14 改名の対象を減らすため、改名より前に行う。
2. `v14_` 改名: 旧コアの private モジュール 20 個 (第 0 部 §4.4 の一覧) を `src/v14/` に機械的に移す。受入条件は dhrystone/coremark の cycles と instret のビット一致。
3. §3.7 のツールチェーン spike: 2 構成の skeleton (rename + ROB + FU 1 個 + struct 配列ポートの `lane_queue`) で §3.7 の 6 項目を通す。SoC 統合が使う構文 (const struct 配列パラメータ、ポート集合の異なる 2 本の generate-if 枝) もここで simulator unit test として確かめるので、SoC 統合より前に置く。veryl clone 側に構文ごとの simulator unit test を足し、同一関数の入れ子呼び出しの recursion 誤判定を clone で直す。同じ機会に S1/S2 (検証計画 §6.4) の fallback の対照を取り、U5、U6、U7、U10 と、`#[ifdef]` による `CORE` 既定値の切替 (検証計画 §2.5) を決める。spike が通らなければ §3.7 の fallback に切り替える。
4. SoC の統合 (§S): `heliodor_soc` を削除して `heliodor_soc_smp` に統合し、`N_HARTS>=1`、`CORE` (この時点では `V14` だけ)、`PMA_REGIONS`、`MTIME_SRC`/`MTIME_DIV`、`i_mtime_tick`、`i_ext_irq_src`、hart ごとの `i_dbg_*`、`o_chk_io` を持たせる (第 0 部 §4.5、§S.1、検証計画 §2.1)。I read slot の非 DRAM single-beat ルーティング (§S.4) もここで入れる。同時に追加のみの共有モジュール変更を入れる: CLINT の `i_tick_sel`/`i_tick`、csr の `i_instret_cnt` の幅パラメータ (既定 1)、dcache の追加 export E1/E3/E5 (§M.2.2)。受入: V14 の N=1 boot (5.15/6.6/7.1/7.1v) と hvlinux が統合 SoC (`N_HARTS=1`) で通り、cy の新しい基準値を記録する。V14 の arch・ACT4・bench の arm は旧 bare ハーネス本体を逐語で保つ (D3 の補足)。
5. 観測の正本を master に置く: `retire_pkg` (vector フィールドを含む RetireRec、§5.12)、`tb/rvfi_tracer.veryl`、`tb/retire_mon.veryl`、`test_rvfi_tracer_selftest`。golden パッチはこれらを逐語コピーするので先に要る。
6. golden: ブランチ `golden/b0f4668-obs` と worktree `.golden/` を作り、veryl `fbd14729` を固定してビルドする (D1、検証計画 §3.1)。観測専用パッチ (検証計画 §3.2) を当て、受入条件 (検証計画 §3.4 の 5 項目。中心は dhrystone/coremark のビット一致) を通す。続けて最初の成果物 (検証計画 §3.5): `MTIME_SRC=INSTRET`、K=10 で 5.15 N=1 boot を x3==0xAA まで走らせ、checkpoint 列、schedule、`gtag` を `test/golden/` に置く。この run で U11 と U12 を閉じ、付録 B の「不明」の発火欄を埋める。
7. 20 テストの時間測定 (検証計画 §2.6): V14 の平坦ハーネスと統合 SoC 上の V14 を比べ、倍率 f が 1.5 を超えたら flat-memory slot adapter を作る。新コアの arch ハーネスの載せ先はこの結果で決まる。

出口条件:

| 区分 | 条件 |
|---|---|
| V14 | 改名と SoC 統合の後も梯子 1-5 が緑で、dhrystone/coremark がビット一致。 |
| 基盤 | spike を通過 (または fallback に切り替え済み)。golden の受入と最初の成果物がある。retire_pkg と tracer が master にある。20 テストの判定が済んでいる。 |

M1a で決める事項: U4 (新コアの veryl の版、M1a 開始時)、U5、U6 (§3.5 の拒否の仕組み)、U7 (checker の synth からの除外)、U9 (CP の基準値の取り直し)、U10 (cranelift の到達範囲)、U11、U12、U14 (golden 成果物の置き場所)、U31 (編集上の積み残し。ヘッダ雛形だけは M1b)。加えて、検証計画 §2.5 の `CORE` の切替方法と §2.6 の載せ先。U3 は M1a から適用する。

#### M1a の完了 (2026-10-14)

出口条件はすべて満たした。V14 は統合 SoC と新しい veryl (origin/master `6a671a6b` + 修正) の上で梯子 1-5 が緑: 既定 254 passed、litmus N=4 pass (3.87M)、N=2 boot 16.42M、N=4 boot 25.18M、hvlinux 22.32M、5.15 N=1 12.23M。dhrystone/coremark はビット一致。基盤側は spike (§3.7.1)、retire_pkg と tracer (`0675176`)、golden の受入と最初の成果物 (`0bc2467`)、rv64ui 54 本の golden checkpoint (`3cd76ae`)、20 テストの判定 (検証計画 §2.6.1、統合 SoC に載せる) が揃った。手順 4 で予定していた SoC への追加 (CORE、PMA_REGIONS、MTIME_SRC、デバッグ入力、I slot の ROM 経路、dcache の export) は、使う側と同時に入れる (DEAD scaffolding を作らないため)。

### M1b: 歩く骨格 (最終構造 + 最も単純な policy)

目標: rv64ui に要るモジュールだけを最終形の構造で立ち上げ、最も単純な policy で rv64ui を golden と trace 一致させる。cfg_w4 は elaborate でき、rv64ui のサブセットが通る状態を M1b から保つ。FP の FU、`tlb`/`ptw`、`atomic_unit`、`io_unit`、rv64ui が要らない CSR と割込みの経路は M2 で入れる。

組み立て順 (各段で、そのモジュールの `chk_*` と `o_perf` の event を同時に入れる):

| 段 | モジュール | この段で動かすもの |
|---|---|---|
| a | `core_cfg`/`cfg_w2`/`cfg_w4`、`core_types`、`tag_pkg`、`tree_pkg`、`opclass_pkg`、`exc_pkg`、`fu_pkg`、`pma_pkg`、`xlate_pkg`、`lane_queue`、`stage_reg` | 型とタグ helper の unit test、§3.5 の拒否 |
| b | `rob`、`commit`、`trap_unit` (rv64ui の環境が使う同期例外と xRET)、`flush_ctrl` (`BRU_N` 本の resolve から最古を選ぶ木)、csr の接続 | 合成した dispatch 列で retire record、部分 kill と walk、full kill、T8 backstop (§C.0 の M1b 列) |
| c | `icache` (`v14_icache` を凍結してから CPU 側を作り直す。P5a)、`islot_arb`、`ftq`、`bpu` (`bp_btb` と `bp_ras`)、`ifu` (Bare の翻訳)、`extract` | fetch から DQ まで。`chk_fetch_stream` (§F.11 の M1b 列) |
| d | `decode`、`rename`、`free_list`、`dispatch` | rq、`rn_` 段、walk による回復 (`NUM_CKPT=0`、§R.7) |
| e | `iq`、`busy_table` (`prf_ready` のみ)、`wb_resv`、`prf`、`exec_port`、`fu_alu`、`fu_bru`、`fu_sys` (`fu_mul`、`fu_div` は入れてもよい) | 最初の端から端までの rv64ui (ALU、分岐、CSR)。ここで golden との trace diff を回し始める |
| f | `mem_pipe` (Bare の翻訳)、`lq`、`sq`、`sb`、`mem_port_arb`、`dcache_port_adapter`、`pmp_check` の各 instance | load/store、PA キーの forward、FENCE/FENCE.I と `ld_barrier`、line 内と line 跨ぎの misaligned (§L.18、§M.1 の M1b 列) |
| g | `heliodor_core::<CFG>`、`heliodor_core_w2`/`_w4`、SoC の `CORE=W2/W4` 枝、`gen_core_tests.py` と `test/gates/m1.list` | W2 の rv64ui 54 本の lockstep、W4 の elaborate と rv64ui のサブセット |

段 b を front end より先に置くのは、retire record と kill の消費経路 (再利用 index のバグ類の主戦場) を、他のモジュールが揃う前から checker 付きで動かすためである。各段は前の段の上に積み、段 e 以降は毎コミット G0 を回す。

出口条件:

| 区分 | 条件 |
|---|---|
| 機能 (W2) | G0 + GL-A: rv64ui 54 本が golden の trace と一致する。 |
| 機能 (W4) | G0: elaborate でき、rv64ui のサブセット (最低でも ALU・分岐・load/store 群、目標は 54 本全部) が pass する。 |
| 構造 | M1b で取り込んだ新規モジュールが cold-reader gate を通過。knob 0 個。`VERYL_AOT_C_DIAG=1` で whole-comb fallback 0 (GS)。kill と WB の invariant checker がすべてのテストで 0。GF を記録。 |
| V14 | 梯子 1-5 が緑で、dhrystone/coremark がビット一致。 |

M1b で決める事項: U8 (`RESP_LAT`)。加えて、§M.2 の行 7 (過渡的な RETRY) の再 issue が有界であることの確認。

### M2: スカラ ISA 全体

目標: スカラの ISA 全体 (検証計画 §7.1 の機能表) を W2 で揃え、arch suite、ACT4、5.15 N=1 boot を golden と lockstep させる。

作業の順序:

1. 推定段階の旧コアのバグを golden 上の directed test で確かめ、allow-list のタグに結び付ける (U17、D4)。M2 の lockstep より前に行う。対象は付録 B の probe 列と、§C.9・§F.12・§L の推定行。
2. 割込み経路の実装と発火: `commit` の `irq_q`、`irq_take`、token の抑止 (§5.13)、csr の割込み cause と委譲、Sstc、LCOFI、debug 入力による schedule replay (§C.0 の M2 列、検証計画 §4.2)。
3. メモリ系 (§L.18、§M.1 の M2 列): `tlb`/`ptw` (I と D、`tb/test_mmu.veryl` を載せ替えた unit test)、`atomic_unit` (AMO/LR/SC/amocas/Zabha、D8 の方式 B、watch、reservation、§5.13.1 の started latch)、`io_unit` (IO/NC、DRAM 上の Svpbmt と CMO clean)、Sv39 の TLB miss の park (PARK(XLATE)) と D-PTW、Svadu (AD クラスは STORE_WT)、cbo.*、PMA/PMP の fault、misaligned の fault、CoRR scan。ACT4 の misaligned granule を 64 に下げる (MP5)。
4. decode の合法性の M2 行 (§C.8: counteren、FS=Off、TVM/TSR、WFI、CBO、Sstc、予約符号化、動的丸めの予約値、不正な OP-V)。
5. csr の仕様修正 (§C.9 の「csr 修正」行)。最初の非追加の修正の前に `v14_csr` を凍結する (第 0 部 §4.4)。
6. FP の FU (`fu_fma`、`fp_misc` + `fu_fmisc`、`fu_fdiv`。M1b で入れていなければ `fu_mul`、`fu_blocking_shell` + `fu_div` も) を最終構造で入れ、正しさを確定させる (rv64um/uf/ud、ACT4 M/F/D/Zfa/Zfhmin。FMA は `STAGE3=0`)。amocas.q の形を決める (U24)。
7. 新規 directed test (検証計画 §7.4) をゲートに入れる。

実装する範囲: §C.0、§L.18、§M.1 の各 M2 列と、M1b から移した FP の FU (§X.12)。§F と §R は M1b の構造のまま、正しさを arch suite で確定させる。

出口条件:

| 区分 | 条件 |
|---|---|
| 機能 (W2) | G0 + GL-A: スカラ arch 全部 (lockstep 対象は検証計画 §4.6) + smode_plic + 新規 directed。GA と GL-C: ACT4 全スカラ suite。GL-B: 5.15 N=1 boot の lockstep (checkpoint 一致、割込み assert 0)。GB1: 6.6、7.1 (FP、ADUE)。GV: N=1 boot。 |
| 機能 (W4) | G0: rv64ui 全部。 |
| 構造 | 推定段階の旧コアバグが directed test で確認済み (D4)。発火行列 (GF) で M2 までの機構がすべて 0 より大きい。GS を記録。 |

M2 で決める事項: U13 (割込み replay で allow で足りるか)、U15 (ACT4 の非既定スイートと H/V directed の commit)、U17 (M2 の前)、U24 (amocas.q の形)、U28 (DRAM 内の Svpbmt NC/IO の基本線)。加えて、検証計画 §4.7 の EXCLUDE 窓と `MTIME_SRC=EXTERNAL` の要否、§L.12 と付録 B の B06 の lockstep での SC の扱い、§C.9 の WARL 正規化の範囲。

### M3: 幅とポート

目標: cfg_w4 を支援構成として完成させ、各軸の sweep で構造的な伸びしろを確かめる。dcache の CPU 側を 2 ポートに再構築する。新コアの SMP は M4 から存在するので、M3 のゲートはすべて N=1 である (第 0 部 §2.5)。

作業の順序:

1. D7 の調査を最初に行う (検証計画 §6.3): V14 で、同じ木・同じマシン・`VERYL_AOT_C_ASYNC=0` で N=1/2/4 を直列に matched 測定し、段差の所在を切り分け、veryl に原因があれば clone 側で直す。結果から N=4 boot ゲートの回し方 (U1) と Verilator を N=4 の判定に使うか (U2) を決め、M4 から適用する。新コアの N=4 boot はまだ無いので、W2/W4 の値は V14 の N=4 boot と N=1 boot の cy/s の比から見積もる。
2. cfg_w4 を adapter の上のまま、両構成の N=1 の梯子に通す (§M.6.1 の手順 1)。
3. 旧コアのブランチで N2.2a の livelock の原因を確かめる (§M.6.1 の手順 2。旧コアの N=4 boot で判定し、master には残さない)。
4. dcache CPU 側の再構築 (§M.6): `v14_dcache` を凍結し、data の bank 化、ポートごとの tag lookup、`fill_id = {index, 世代}` の MSHR file の構造、hit-under-fill、beat 単位の drain 調停を入れる。支援する `MSHR_N`/`N_FILL` は 1 のまま、N=1 のゲートで検査する。DTLB の 2 lookup ポートを実働させる。
5. MEM_W=2 の実働 (§L.18 の M3 列): port ごとの forward と scan、複数 lane の store retire。
6. 回復と発行の拡張: checkpoint pool (§R.7)、BRU 2 本の resolve 木と kill の段数 (§C.0)、cfg_w4 の FU トポロジ表 (§X.12)。
7. sweep: 1 軸ずつ増やし、他を固定する (第 0 部 §2.5 の判定)。構造サイズ (§3.3、§F.2、§L.17)、`NB`、IQ と PRF ポート、`ENTRIES` と ptw キュー深さ。IPC が期待方向に動かない軸は原因を特定して §3.4 に登録する。

実装する範囲: §F.11、§R.7、§X.12、§L.18、§M.1 の各 M3 列と §C.0 の M3 列。

出口条件:

| 区分 | 条件 |
|---|---|
| 機能 (W2, W4) | 両構成で N=1 の梯子を通る: G0 (W2 と W4 で同一リスト)、GA/GL-C、GL-B、GB1、GX (決定的なテスト全部)、GV (N=1)。 |
| 構造 | 各軸の sweep で IPC が期待方向に動くか、動かない原因が §3.4 に登録されている。dcache の CPU 側は 2 ポート (bank、ポートごとの tag、MSHR file の構造)、DTLB は lookup 2 ポート。cy/s を記録 (GS)。N=4 boot ゲートの方針 (D7) が決まっている。 |

M3 で決める事項: U1 と U2 (N=4 boot の回し方、M4 から適用)、U18 (cfg_w4 の BRU ポート数)、U19 (dcache の bank 数)、U20 (PRF ポート数と `PORT_FU`)、U21 (構造サイズの最終値)、U22 (`NUM_CKPT`)、U23 (walk 中に古い kill を受け入れるか)、U25 (FMA の `STAGE3`)、U26 (投機的な load-hit wakeup)、U27 (D-PTW の L2 直結)、U29 (NC load の投機発行)。各章が M3 に送った事項 (STA/STD 分離、`LD_LAT` の圧縮、line 跨ぎ load の投機、予測器の構成と L0 段、2 block からの取り出し、IQ のポート割り当て方針、trap 段の要否、HPM の event 8 など) も、この sweep と CP 分解の中で閉じる。

### M4: SMP

目標: 新コアで SMP を通す。メモリ系のコミットはすべて N=4 boot をゲートとする運用に入る。

作業の順序:

1. 新コアの N=2 boot と litmus N=2/N=4 を通す。続けて N=4 boot を通す。M3 で決めた N=4 boot の方針 (D7、U1、U2) をここから適用する。
2. コヒーレンス下の検証 (§L.18 の M4 列): CoRR、reservation、watch、drain の飢餓の確認、`wt_fires` の directed test、PLIC claim の競合 (検証計画 §7.2、§8)。
3. AD クラスを owned RMW (LOAD_EXCL + STORE_EXCL) に変える (§5.9、§M.8.4)。7.1 の ADUE=1 で必要になる。
4. 新コアの N=4 boot ができた後に限り、`MSHR_N` (必要なら `N_FILL`) を 1 より大きくする (§M.6.1 の手順 5)。そのコミットはすべて GB4 をゲートとする (第 0 部 §2.5)。`SPH > 2` に要る mem_ctrl の修正 (§M.4) もこの順序に従う。
5. ASQ と victim 除外のブランチ実験 (§L.11、§L.12) と、N=4 での SB の占有の測定 (§L.17)。

実装する範囲: §L.18 と §M.1 の各 M4 列。

出口条件:

| 区分 | 条件 |
|---|---|
| 機能 (W2, W4) | G0 に litmus N=2 を追加。GT4、GB2 (5.15、マイルストーン末は 6.6/7.1 の SMP も)。GB4 は M3 の決定に従う。GV: litmus4、N=2、N=4。 |
| 構造 | メモリ系を変えたコミットはすべて GB4 を通っている。`MSHR_N > 1` を出荷する場合は、各コミットが GB4 を通っている。 |

M4 で決める事項: 未決事項の一覧には M4 期限の項目は無い。各章が M4 に送った事項: ASQ クラスを入れるか (§L.11)、fill の victim 選択から pin 中の line を除外するか (§L.12)、`MSHR_N` の値 (§M.6.4)。

### M5: H と V

目標: H 拡張 (二段翻訳) と VU を新コアに統合し、hvlinux と vector テスト群を通す。

作業の順序:

1. VU の作業 (§V.11 の順): `MEM_PIPE=0` の arm の再検証、VU 関係の推定バグの golden 上の directed test (U17 の VU 分)、`v14_vector_unit` の凍結と VM1-VM4、`vu_adapter`/`vu_mem_adapter`/`sb.i_vu_push`/mem_pipe 0 の VU client、`busy_table` の `prf_done` (VU の scalar オペランドが最初の消費者、§5.7)、VU 専用の PRF 読出ポート (int 2、fp 1)、commit の VEC 規則と csr への追加。
2. H 拡張: `tlb`/`ptw` の V=1 と二段 walk (§M.12)、`trap_unit` の VS への委譲・htval/mtval2・GVA・tinst (§C.0 の M5 列)、decode の M5 行 (§C.8)、guest 外部割込み。
3. G13 の一覧を directed test で確かめ直し、README の「complete RVA23」の記述を直す (§V.9、U16)。

実装する範囲: §C.0、§M.1、§V.11 の各 M5 列と §L.18 の M5 列 (VU の接続、HLV/HSV)。

出口条件:

| 区分 | 条件 |
|---|---|
| 機能 (W2, W4) | G0 に H 17 本、V 20 本、test_vmspre を追加。GH (hvlinux)。GB1 に 7.1v。GB4 (memory pipe と `sb` を変えるので必須、§V.11)。GX に H/V。GV に hvlinux。`chk_vu` がすべてのテストで 0。 |
| 構造 | VU の上限を修正するか宣言する。§3.4 の VU 由来の行を消し、残す上限は §V.10 に移す。 |

M5 で決める事項: U30 (VU の IO アクセス)。各章が M5 に送った事項: tinst のための `ExcRec.implicit` (§5.8、§C.3)、`fpu_wrap` の二重を解消するか (§X.8)、vset/vstart の csr への渡し方 (§C.5)、N=2 の vector ゲートを足すか (§V.11)。U16 (ISA の目標) は M5 の後にユーザが判断する。

### M6: 既定コアの切替

- 目標: 既定コアを新コアに切り替え、旧コアを削除する。
- 作業: SoC と harness の `CORE` の既定値を変更し、V14 枝、`src/v14/` (凍結コピーを含む)、V14 専用の印字と `o_dbg_*` を削除する。README の数値と構成を新コアで更新する。
- 出口条件: 新コアが既定で、検証計画 §1.2 の M6 列のゲート (G0、GA/GL-C、GL-B、GB1、GT4、GB2、GB4、GH、GX、GV をすべて) を両構成で通る。M6 のコミットの変更は、削除と既定値の変更だけである (第 0 部 §2.5)。
- M6 の後: §2.6 で送った RVA23 の不足分と G13 の判断 (U16)、misa の F/D/C の扱い (§C.9) をユーザが判断する。

---

## 付録: 旧コアの経緯と防ぐバグ類

本付録は、本文の規則が防ぐ旧コアのバグ類と、規則を選んだ経緯を、本文の章ごとにまとめる。本文は設計だけを書き、旧コアの事例 (commit の hash と行番号) はここに置く。規則の正本は本文の節であり、本付録は規則を定めない。行番号は凍結コミット `b0f4668` のもので、無印の `:N` は `src/core/heliodor_core.veryl` を指す。「推定」の項目は、M2 の前に golden 上の directed test で確かめる (D4、U17)。

### 付録 §5 横断契約

| 節 | 防ぐバグ類 (旧コアの事例と根拠) |
|---|---|
| §5.1 | 旧コアの `rob_size <= 8'd30`、`walk_rob_q: logic<5>`、`is_full == 6'd32`、`{3'b000, age}` など、2-wide かつ 32 エントリ前提のリテラル。CLINT の `N_HARTS as 3` が N=8 のときにだけ 0 へ切り捨てられた事例 (42da658)。 |
| §5.2 | `(idx - head)` を ROB_IDX_W 幅で再計算する箇所が 47 行・6 ファイルにあったこと、SV の文脈幅による誤評価 (`rob.veryl:1739-1744`)、手で展開された pick 木が 3 種類あったこと、op が stage を進むたびに live sideband が別の op を指した 5 件 (c82f24b, bb93235, dbae223, a5e29de, be117a7)。 |
| §5.3 | タイミングの bubble に依存した正しさ。旧コアでは、Block T (LSR の back-to-back 受理) と L1 (L1 store queue) という 2 つの性能改善が、同じ窓を別々の扉から開けてしまった。また、段を挿入するたびに live sideband が 1 サイクルずれた。 |
| §5.4 | VU の FIFO が部分 squash を無視して deadlock した件 (a1b992f)、wrong-path の結果が再利用された rob_idx に書き込まれた件 (f89f0c6)、wrong-path の PTW fault が再利用 index に帰属した件、反復 FU の owner latch が commit flush でしか消えず ABA を起こしうること (推定)、ROB の完了が index だけで無条件に書かれること (`rob.veryl:1474-1480`)。 |
| §5.5 | commit_redirect が redirect の FF の arm を写しそこね、`commit_csrw_frm` が欠けていた件 (`heliodor_core.veryl:8451`。head+1 の op が二重実行されうる、推定)、rename と commit で lane 1 の可否リストが逆だったこと、c_serial が dead だった件 (21a6dd2)、不正な OP-V が wedge する件 (`heliodor_core.veryl:5971,6075`)、CSR の読み出しでも書き込み経路が動いていた件 (`heliodor_core.veryl:7000`、P9.1 の N=4 livelock の起点)。 |
| §5.6 | EX-pipe の sideband 5 件、owner 一致の判定を誤った件 (19fa9db)、FP div/sqrt と s2 が同時に WB して結果が失われうる件 (推定)、`iq_fp` の select/解放規則と blocking FU が噛み合わなかった件 (be117a7)。 |
| §5.7 | lane 0 の 6-way 固定優先 mux と、それをなぞる sideband (FP-SMP の wedge 1f17551)、ホールドバッファが開けた窓 (eh_wrongpath)、WB の調停結果を同じサイクルの issue に戻したことで生じた comb loop。 |
| §5.8 | 割込みの epc を投機的な fetch ポインタから取った件 (cc50446)、lane 1 の load が持つ G-stage/gpa の sideband が lane 0 の別の勝者に付きうる件 (`heliodor_core.veryl:6546-6547`、推定)、trap する AMO が rd を commit しうる件 (推定)。 |
| §5.9 | 「駆動者 ≠ 持ち主」の 5 件、共有バスを無条件に捕捉していたこと (`m_pa_q`)、要求者を区別しない gate による wedge、投機要求が共有の FSM を占有し続けた件 (c358684)。MSHR file のイベントをエントリの latch 値だけから作る規則は、旧コアの MSHR ALLOC 実験 (N2.2a、95753c8 で撤回) で起きた livelock の推定原因 (`o_miss_offset` が live なポートの値を拾うこと、`dcache.veryl:2907`) を構造的に排除する。 |
| §5.10 | walker が live な文脈を読んでいた件、投機 b2b 要求が TS_DONE を握り続けてゲスト Linux を 2 か月 deadlock させた件 (c358684)、satp_shadow が古い satp を latch していた件 (`heliodor_core.veryl:7181`)。 |
| §5.11 | MMIO load が cache された件 (73e4ac4)、DRAM PA への uncached 読み出しが accept サイクルのゴミを返した件 (3d5130e)、窓の中に置いた litmus のデータが cacheable な atomic を一度も通らなかった件 (72e08ff)。 |
| §5.12 | 旧コアには「retire した」の定義が少なくとも 7 種類あったこと (`o_dbg_retire_v_a` は lane 0 だけで、`:7887`)、minstret が保持中のサイクルを数え slot 1 を数えなかった件 (`:7420`)、ack=0 のまま trap しうる件、poison された SC が二重に retire する件 (`:6402`)、副作用の gate が valid と ack で混在していた件。 |
| §5.13 | 旧コアは ROB が空になってから受け付けていたため、受付の retire 順位が「pending の立ち上がり + 実行中の op 数」というタイミング依存の値になっていた (`heliodor_core.veryl:7144`)。commit と割込みが同じサイクルに起きて再実行を招いた件 (03c9f6d)。 |
| §5.13.1 | 防ぐ欠陥の類: 開始後の再試行が live の token に依存したことによる割込みとのデッドロック、token の照合と要求の到着の間の割込みによる二重実行、kill された owner の D ビット書き込み。 |
| §5.14 | 旧コアの MMIO load が wrong path で発行されていた件、poison による replay で再読み出しされていた件、blocked になった M-stage が読み捨ての読み出しを繰り返していた件、IO の store データが IO の load に forward されていた件 (UART の THR/RBR は同じ offset 0)、IO store の後に IO load が追い越していた件 (いずれも推定。根拠は `heliodor_core.veryl:9450, 10705-10714, 11124-11127, 11940` と検証計画付録 B の B41)。 |
| §5.15 | 陳腐化したコメントを事実と取り違えた件 (「single-cycle なので live で正しい」「bare-only today」)、DEAD の D-cone が synth の最長経路になった件 (d0c2be9)、reset edge でだけ起こる挙動 (addb749)、census が 0 を読むことを根拠に仮説を立てかけた件、port 1 だけ規則が欠けていた件 (b3266ab)。 |

### 付録 §F フロントエンド

| 節 | 防ぐバグ類 (旧コアの事例と根拠): 本文で防ぐ仕組み |
|---|---|
| §F.4、§F.7 | mid-dword re-entry と decode-alignment aliasing (48b8a7c、PRED_BLK_REENT): `start_pc` による index と V1-V6 で防ぐ。 |
| §F.7 | FIFO の幾何 (head+1/head+2) を identity の代わりに使ったこと (42c7868 の SMP hang、7523761): carry の identity 検査と X2 で防ぐ。 |
| §F.7 | 命令の飛ばし (10ca81f、a_eff_next、slot-1 の take の gate): X1 と X2 で防ぐ。 |
| §F.3 | 段の挿入で予測と bundle がずれたこと (a49626b の hold drift、FTB の学習が 1 bundle ずれた件): 予測と meta を FTQ のエントリで運ぶことで防ぐ。 |
| §F.4 | 投機 history の構成が committed twin と食い違っていたこと: ckpt で戻し、ckpt で学習することで防ぐ。 |
| §F.5 | WORD FIFO の溢れ (78355eb): credit に in-flight を数えることで防ぐ。 |
| §F.5 | redirect のサイクルの偽の walk: owner を落とすことと tag への帰属で防ぐ。 |
| §F.10 | FENCE.I が redirect しなかったこと (9538dbb): §5.5 の NEXT_PC flush で防ぐ。旧コアは invalidate だけで redirect しなかったため、rv64ui の fence_i test 2 に失敗した。 |
| §F.1、§F.9 | 割込みの epc を front end から取ったこと (cc50446): F-P4 で防ぐ。 |
| §F.2、§F.6 | 1 つの const を 2 つのファイルに重複させたこと (`ICACHE_SYNC_READ`、`*_SYNC_READ` と Stage-B の整列): 公表レイテンシと elaborate 時の検査で防ぐ。 |
| §F.6、§M.5 | I read slot の旧調停で、途中の redirect が beat を別の dword に向けた件と、途中で要求が落ちた fill が beat を失った件: `islot_arb` が受理時に owner と PTE 読みのアドレスを latch し、beat の受け取りを要求信号で gate しないことで防ぐ。 |

### 付録 §R decode・rename・dispatch

| 節 | 防ぐバグ類 (旧コアの事例と根拠): 本文で防ぐ仕組み |
|---|---|
| §R.5.2 | rename、ROB、commit で lane の可否リストが食い違った件。rename は control を通して load を拒み、ROB の c2_simple はその逆だった (`heliodor_core.veryl:4800-4810` と `rob.veryl:593-601`)。可否は OpClass と credit だけで決まる。 |
| §R.3.3 | 割り当てが優先順位で黙って捨てられる形 (`rat.veryl` の restore > recovery > rename)。kill と walk のサイクルは take=0 にして構造的に防ぐ。 |
| §R.4 | free list の n_inflight の更新漏れ (同じサイクルの push の引き忘れ、二重 NBA)。 |
| §R.5.3 | 同じ group の前の lane が割り当てた pdst について、前の持ち主の ready を読んでしまう件 (`iq_int.veryl:677-688`)。 |
| §R.3.1 | x0 の pdst 0 への書き込みと ready のクリア (98f2c45, c6ef53f)。 |
| §R.5.3、§5.1 | 幅を前提としたリテラル (`rob_size <= 8'd30`、`head[4:0]`) と、満杯を検査しない LQ。 |

### 付録 §X スケジューラと実行

| 節 | 防ぐバグ類 (旧コアの事例と根拠): 本文で防ぐ仕組み |
|---|---|
| §X.7、§5.6 | live な sideband が、段を挿入するたびに別の op を指した 5 件 (c82f24b, bb93235, dbae223, a5e29de, be117a7)。FU が書けるのは packet だけで、タグは受理時の入力のコピーである。 |
| §X.8.1 | 最小 index の select と「提示中のエントリを ack する」規則のせいで、blocking FU が別のエントリを retire させた件 (be117a7) と、owner の照合を誤った件 (19fa9db)。エントリは受理で解放し、完了は shell が latch したタグに帰属させる。 |
| §X.8.1 | 早期 squash が反復 FU の owner latch に届かず、再利用された ROB index に古い商が書き込まれうる件 (推定、`heliodor_core.veryl:5475-5520`、`fpu_wrap.veryl:572-808`)。shell は kill を消費する。 |
| §X.5 | FP の div/sqrt と s2 が同じサイクルに WB して結果が失われうる件 (推定、`fpu_wrap.veryl:601-613`)。WB は予約で一意になる。 |
| §X.7 | DIV が slot 0 の front register を約 35 サイクル塞ぎ、その間 slot 0 にしか行けない仕事がすべて止まった件。blocking FU は自分の o_ready だけを落とし、issue ポートは塞がない。 |
| §X.6 | `cdb_dest_is_fp` のミラー mux が優先順位からずれた件 (1f17551)。宛先クラスは packet が運ぶ。 |
| §X.5 | WB 調停の結果を同じサイクルの issue に戻して生じた comb loop。予約と HOLE_FILL の grant は登録済み状態から計算する。 |
| §X.8.1 | 保持バッファが、元の設計に無かった窓を開けた件 (eh_wrongpath)。保持しているのは shell だけで、shell は kill を消費する。 |

### 付録 §C ROB・commit・トラップ・CSR

| 節 | 経緯 |
|---|---|
| §C.2.3 | 旧コアの `arch_next_pc_q` (`:7550-7581`) は slot 1 が control op を持たない前提で 2 候補から選んでいた。lane ごとの resolve record によりこの前提は不要になる。 |
| §C.4 | full kill の `Redirect.pc` に fetch 側のポインタを使わない規則は、割込みの epc を投機的な fetch ポインタから取った件 (cc50446) の類を防ぐ。 |

commit・trap・CSR の範囲の旧コアの仕様逸脱は、本文 §C.9 と検証計画付録 B の許容差異表にある。

### 付録 §L LSU・LSQ・アトミック・I/O

| 節 | 防ぐバグ類と経緯 |
|---|---|
| §L.3 | 旧 LQ は kill の後の生存数を popcount で数えていた (`load_queue.veryl:271-286`)。 |
| §L.11 | 旧方式の形 (AMO は head で読み retire 時に書く、FAIL や watch の poison は REPLAY) は、commit と replay の境界のバグ (poison された SC が retire してから再実行される、`heliodor_core.veryl:6402`) を抱えやすいので採らなかった (D8)。 |
| §L 全体 | 「駆動者 ≠ 持ち主」の 5 件 (fill を slot と `fill_id` に帰属させることで解消)。drain の skew による N=2 の oops と wedge (`726b5a3`、`dff8b91`)。port 1 にだけ免除が欠けていた件 (`b3266ab`。scan も forward も 1 つの generate 本体で書くので起こらない)。CoRR が Sv39 で健全でなかった件。満杯検査の無い LQ。IO の読み出しが wrong path、replay、forward、再駆動によって重複しうる件 (§5.14 の根拠と同じ)。aq を無視した queued atomic と、VU が queued atomic を見なかった件 (H1-H3)。poison された SC が 2 回 retire した件。AMO の W/D 権限の検査漏れ。page を跨ぐ misaligned を 1 回しか翻訳しなかった件。misaligned の hi 側の strobe が共有の書込チャネルに漏れた件 (`5f60630`。1 つの packet に 1 line だけを入れることで解消)。 |

アルゴリズムの移植元 (旧コアの位置) は、移植に要るので本文 §L.19 に置く。

### 付録 §M dcache/MMU の CPU 側・TLB・PTW・PMP/PMA

| 節 | 防ぐバグ類 (旧コアの事例と根拠): 本文で防ぐ仕組み |
|---|---|
| §M.2、§M.6.4 | driver ≠ owner (`DCACHE_SYNC_READ` 以後の 5 件、f004101, 0c0ef65): fill の帰属は E1 またはエントリの latch 値だけで、応答の帰属は tag だけで決める。 |
| §M.6.1、§M.6.4 | grant 前確保による livelock (N2.2a, 95753c8): M.6.1 の順序とゲート、M.6.4 の構造上の除去。 |
| §M.8.1、§M.8.2 | walker が live な文脈や VA に依存した事故 (TLB poisoning 9d7bad3、DONE 状態の古い leaf PPN 7e92bb7、孤児 walk の fault 65be7fd/2177c89): 文脈の latch、tag 付きの応答、kill によるキューの掃除。 |
| §M.8.1 | 結果保持状態による deadlock (c358684): 完了は COMPLETE の 1 サイクルだけ。 |
| §M.8.3 | PMP 拒否の PTE 読みが完了しない (54c7d87): 読みを出す前に検査する。 |
| §M.2.3、§M.6.7 | uncached 読みのデバイス副作用の重複: adapter と再構築版が、grant の翌サイクルに要求を落とす。 |
| §M.7、§5.9 | 「ポートに空きサイクルがある」前提の相乗り (SQ_RETRY): メモリポートの要求者は `mem_port_arb` を通る valid/ready の client だけであり、lookup は副作用を持たない。 |
| §M.10 | AMO の書き込み権限が commit で落ちうる件 (推定): AMO は execute で store の権限 (W と、Svade なら D) を検査し、結果を op と一緒に運ぶ。 |
| §M.9 | 旧コアは SFENCE で front end を redirect しなかった (`heliodor_core.veryl:8451`)。 |
