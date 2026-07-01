// Minimal C client for libcontain — also the smoke test for the embedding path.
//
// Build (Apple Silicon):
//   zig build lib
//   cc -I zig-out/include examples/smoke.c zig-out/lib/libcontain.a \
//      -framework Hypervisor -o /tmp/contain_smoke
//   codesign --entitlements hv.entitlements --force -s - /tmp/contain_smoke
//   /tmp/contain_smoke <kernel> <initramfs.cpio> <share_dir>
//
// It boots the demo initramfs (which drops to a shell under contain.interactive),
// sends a shell command over the console, checks the reply arrives via the output
// callback, then stops + frees — exercising start/write/stop/free and the clean
// in-process teardown (no process.exit).

#include "contain.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdatomic.h>

static char out_buf[1 << 16];
static atomic_size_t out_len = 0;

static void on_output(void *ctx, const uint8_t *data, size_t len) {
    (void)ctx;
    size_t off = atomic_fetch_add(&out_len, len);
    if (off + len < sizeof(out_buf)) memcpy(out_buf + off, data, len);
    fwrite(data, 1, len, stdout); // mirror to our stdout so progress is visible
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <kernel> <initramfs.cpio> <share_dir>\n", argv[0]);
        return 2;
    }

    contain_config cfg = {0};
    cfg.kernel_path = argv[1];
    cfg.initramfs_path = argv[2];
    cfg.share_path = argv[3];
    cfg.out_fn = on_output;

    printf("[smoke] starting VM...\n");
    contain_vm *vm = contain_start(&cfg);
    if (!vm) {
        fprintf(stderr, "[smoke] contain_start failed\n");
        return 1;
    }

    sleep(4); // let it boot to the interactive shell

    const char *cmd = "echo SMOKE_OK_$((6*7))\n";
    printf("\n[smoke] writing command: %s", cmd);
    contain_write(vm, (const uint8_t *)cmd, strlen(cmd));

    sleep(2); // let the shell run it and echo the result

    int ok = strstr(out_buf, "SMOKE_OK_42") != NULL;
    printf("\n[smoke] reply seen: %s\n", ok ? "YES" : "NO");

    printf("[smoke] stopping (mid-run) ...\n");
    contain_stop(vm); // kicks the vCPU out of its run loop
    printf("[smoke] finished=%d\n", contain_is_finished(vm));

    printf("[smoke] freeing (NAT/threads teardown) ...\n");
    contain_free(vm); // must return without hanging
    printf("[smoke] freed cleanly\n");

    printf("[smoke] RESULT: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
