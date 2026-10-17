// Double-precision blocked matrix multiply (upstream riscv-tests mm kernel)
// driven without the multi-thread runtime: R passes of c += a*b, then a
// check against a naive product. Returns 0 on success.

#include "common.h"

#define R 4
#define CBM_N 48
#define CBN_N 50
#define CBK_N 48

static uint64_t lfsr(uint64_t x)
{
  uint64_t bit = (x ^ (x >> 1)) & 1;
  return (x >> 1) | (bit << 62);
}

static t a[CBM_N * CBK_N];
static t b[CBK_N * CBN_N];
static t c[CBM_N * CBN_N];

int main(void)
{
  const size_t m = CBM_N, n = CBN_N, p = CBK_N;
  uint64_t s = 0xdeadbeefU;

  for (size_t i = 0; i < m * p; i++)
    a[i] = (t)(s = lfsr(s));
  for (size_t i = 0; i < p * n; i++)
    b[i] = (t)(s = lfsr(s));

  for (int r = 0; r < R; r++)
    mm(m, n, p, a, p, b, n, c, n);

  for (size_t i = 0; i < m; i++)
    for (size_t j = 0; j < n; j++) {
      t ref = 0;
      for (size_t k = 0; k < p; k++)
        ref += a[i * p + k] * b[k * n + j];
      ref *= R;
      t d = c[i * n + j] - ref;
      if (d < 0) d = -d;
      t lim = ref < 0 ? -ref : ref;
      if (d > lim * 1e-6)
        return 1;
    }
  return 0;
}
