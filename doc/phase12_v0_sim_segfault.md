# Phase 12 V0 — Veryl native-sim segfault (compiled backends) — RESOLVED

## Summary

With the Phase 12 V0 vector tree in place, the Veryl **native simulator's
compiled backends segfaulted at simulation run time** — both `--backend cc`
(emit-C → `.so`, which bails the wide comb statement to per-chunk Cranelift) and
`--backend cranelift` (in-process JIT), even on a *non-vector* test. The
tree-walking **`interpret` backend was unaffected**.

**Root cause: a Cranelift codegen bug in the wide (>128-bit) ternary lowering**,
not alignment and not a heliodor RTL problem. **Fixed in the `veryl/` clone**
(`crates/simulator/src/backend/cranelift/expression.rs`,
`build_binary_wide_ternary`). With the fix the full V=0 regression is
byte-identical to the Phase 11 baseline and the V0 directed test passes on every
backend.

## Root cause (the real one)

`build_binary_wide_ternary` materializes each branch as a wide *pointer* for
`emit_wide_select`, which copies the selected value word-by-word from that
pointer. It decided "is this branch already a pointer?" with
`is_wide_ptr(branch.width())` — i.e. the branch's **`width` FIELD**.

But a node whose `width` field exceeds its *evaluation* width builds a **scalar
register**, not a pointer. The canonical case (see `returns_wide_pointer`'s doc
comment) is a non-comparison `Binary` whose own evaluation width is ≤128 even
though an operand lives in wide-pointer storage (a narrowing `as`/slice keeps
the operand in its >128-bit source domain). For such a branch the width field is
>128 but `build_binary` hands back a scalar.

The old gate therefore treated that **scalar value as a pointer** and
`emit_wide_select` dereferenced it. The faulting instruction was a plain
`mov (%rdi),%rax` with `%rdi = r12 | rax = 1` — i.e. loading a 128-bit operand
word-by-word from address `1` (the scalar masquerading as a pointer) → SIGSEGV
every cycle.

The wide-**binary** path already guards against exactly this (it decides
pointer-vs-register with `returns_wide_pointer()` and force-stores a scalar into
a fresh slot — see the `x_ptr`/`y_ptr` comment in
`build_binary_wide_binary`). The wide-**ternary** path was simply missing the
same guard. The fix mirrors the binary path.

### The fix (veryl clone)

```rust
// build_binary_wide_ternary: decide each branch's representation by the
// ACTUAL value (returns_wide_pointer), not is_wide_ptr(branch.width()); a
// scalar (inflated-width node) is force-stored into a fresh zeroed slot.
let to_wide_ptr = |builder, expr, val| {
    if returns_wide_pointer(expr) { val }
    else { let slot = alloc_wide_zero(builder, nb);
           builder.ins().store(MemFlags::trusted(), val, slot, 0); slot }
};
let true_ptr  = to_wide_ptr(builder, true_expr,  true_payload);
let false_ptr = to_wide_ptr(builder, false_expr, false_payload);
```

It is correctness-neutral for the genuine cases (a real wide-ptr branch still
returns its pointer; a genuinely narrow branch was already force-stored by
`ensure_wide_ptr_val`), and fixes only the inflated-width-scalar branch.

## Why the earlier "alignment" hypothesis was wrong

An initial guess blamed the `I128` value-buffer loads/stores using
`MemFlags::trusted()` (which asserts `aligned`) against only-8-byte-aligned
storage. A `gdb` backtrace disproved it: the faulting instruction is a **GPR**
`mov (%rdi),%rax`, not an alignment-sensitive SSE move. (For the record, recent
x86 runs `movdqu` at `movdqa` speed on aligned addresses, so dropping the
`aligned` hint there would cost nothing — but it was not the bug, so no such
change was made.)

## Reproduction

The bug requires a **large** design — the inflated-`width` ternary branch arises
from the analyzer's width propagation at heliodor scale; small standalone
modules do not reproduce it. The reproduction is heliodor itself:

```bash
# Before the fix: SEGFAULT (exit 139) on both compiled backends, even non-vector
veryl test --test test_arch_rv64ui_add --backend cranelift
# After the fix: PASS on every backend, including dual-run divergence check
veryl test --test test_arch_vadd --backend cc
veryl test --test test_arch_vadd --backend cranelift
veryl test --test test_arch_vadd --backend interpret
veryl test --test test_arch_vadd --backend-validate
```

## Status of the V0 work

Functionally complete and verified on **all** backends (`test/vadd/vadd_test.S`,
`#[test(test_arch_vadd)]`). Full V=0 regression is byte-identical to the
Phase 11 baseline (default `231/0` incl. vadd; litmus `0x4fa6a0`; boots 5.15
`0x9ae070` / 6.6 `0x11b8220` / 7.1 `0x100f540`; hvlinux `0x014662b0`; SMP N2
`0xd3cac0`, N4 `0x124d0f0`). The compiled-backend block is cleared.
