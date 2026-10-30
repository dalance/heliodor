// OpenOCD remote_bitbang server for the Verilator debug wrapper (tb only).
//
// rbb_init(port) listens on localhost (port 0 picks a free one) and prints
// "Listening for remote bitbang connection on port N." as spike does, which
// is what the gdbserver.py target waits for. rbb_tick() returns the next pin
// change: it consumes buffered commands until one writes the pins or the
// buffer is empty, answering 'R' with the TDO it was given (jtag_dtm.sv calls
// it once per TCK edge with the TDO of the edge before). Returns 0 (no pin
// change), 1 (pins written) or 2 (the client sent 'Q' or closed the
// connection), with the current pin levels in its outputs. Replies to 'R'
// are sent when the input runs dry, so a batch costs one write. Commands:
// '0'-'7' tck/tms/tdi, 'R' read, 'r'-'u' trst/srst (srst is ignored: reset
// is ndmreset), 'Q' quit; the rest ('B'/'b' blink, 'Z'/'z' sleep) are
// ignored.
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

static int listen_fd = -1;
static int client_fd = -1;
static unsigned char rbuf[65536];
static int rpos, rend;
static char wbuf[65536];
static int wlen;
static int p_tck, p_tms, p_tdi, p_trst;

static void flush_out(void) {
    int off = 0;
    while (off < wlen) {
        ssize_t n = write(client_fd, wbuf + off, wlen - off);
        if (n < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            fprintf(stderr, "rbb: write failed: %s\n", strerror(errno));
            exit(1);
        }
        off += (int)n;
    }
    wlen = 0;
}

int rbb_init(int port) {
    struct sockaddr_in a;
    socklen_t len = sizeof(a);
    int one = 1;
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("rbb: socket");
        exit(1);
    }
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((unsigned short)port);
    if (bind(listen_fd, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(listen_fd, 1) < 0) {
        perror("rbb: bind/listen");
        exit(1);
    }
    fcntl(listen_fd, F_SETFL, O_NONBLOCK);
    getsockname(listen_fd, (struct sockaddr *)&a, &len);
    printf("Listening for remote bitbang connection on port %d.\n", ntohs(a.sin_port));
    fflush(stdout);
    return ntohs(a.sin_port);
}

int rbb_tick(int tdo, int *tck, int *tms, int *tdi, int *trst) {
    int rc = 0;
    if (client_fd < 0) {
        int one = 1;
        client_fd = accept(listen_fd, NULL, NULL);
        if (client_fd >= 0) {
            fcntl(client_fd, F_SETFL, O_NONBLOCK);
            setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        }
    }
    while (client_fd >= 0 && rc == 0) {
        if (rpos == rend) {
            ssize_t n;
            if (wlen) flush_out();
            n = read(client_fd, rbuf, sizeof(rbuf));
            if (n < 0 && (errno == EAGAIN || errno == EINTR)) break;
            if (n <= 0) {
                rc = 2;
                break;
            }
            rpos = 0;
            rend = (int)n;
        }
        unsigned char c = rbuf[rpos++];
        if (c >= '0' && c <= '7') {
            p_tck = (c - '0') >> 2 & 1;
            p_tms = (c - '0') >> 1 & 1;
            p_tdi = (c - '0') & 1;
            rc = 1;
        } else if (c >= 'r' && c <= 'u') {
            p_trst = (c - 'r') >> 1 & 1;
            rc = 1;
        } else if (c == 'R') {
            wbuf[wlen++] = tdo ? '1' : '0';
            if (wlen == (int)sizeof(wbuf)) flush_out();
        } else if (c == 'Q') {
            if (wlen) flush_out();
            rc = 2;
        }
    }
    *tck = p_tck;
    *tms = p_tms;
    *tdi = p_tdi;
    *trst = p_trst;
    return rc;
}

#ifdef __cplusplus
}
#endif
