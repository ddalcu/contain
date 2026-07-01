/*
 * contain — host-safe Linux/OCI sandbox, embeddable as a library.
 *
 * Runs an untrusted Linux guest on the host's hardware virtualization (HVF on
 * Apple Silicon) with from-scratch device models + userspace NAT. Designed to be
 * linked into a sandboxed app (e.g. a Swift host driving an AI coding agent):
 * pure-userspace networking means no privileged entitlement, and the hypervisor
 * entitlement is App Sandbox compatible on macOS.
 *
 * Threading: contain_start launches the guest on its own thread and returns
 * immediately. contain_write / contain_is_finished / contain_stop / contain_free
 * are safe to call from another thread. The output callback fires on an internal
 * thread; the exit callback fires on the run thread (do not call contain_stop or
 * contain_free from inside it).
 *
 * Link: libcontain.a (+ -framework Hypervisor on Apple Silicon). The embedding
 * app bundle must carry the `com.apple.security.hypervisor` entitlement (plus
 * network client/server if the guest uses the network, and the app sandbox).
 */
#ifndef CONTAIN_H
#define CONTAIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a running guest, returned by contain_start. */
typedef struct contain_vm contain_vm;

/* Guest console output (host receives guest stdout/stderr bytes). May be called
 * from an internal thread; copy out what you need and return promptly. */
typedef void (*contain_output_fn)(void *ctx, const uint8_t *data, size_t len);

/* One-shot notification that the guest run loop returned (powered off/stopped).
 * Fires on the run thread; must not call contain_stop/contain_free. */
typedef void (*contain_exit_fn)(void *ctx, int code);

/*
 * Boot configuration. Unset optional fields are NULL/0. Strings are borrowed for
 * the duration of contain_start (disk_path and share_path are copied internally
 * and kept for the VM's lifetime / disk writeback).
 */
typedef struct {
    const char *kernel_path;       /* REQUIRED: arm64 Image or x86 vmlinux ELF */
    const char *rootfs_dir;        /* unpacked OCI rootfs -> in-memory initramfs */
    const char *initramfs_path;    /* OR a prebuilt .cpio initramfs */
    const char *disk_path;         /* virtio-blk backing file (writeback on stop) */
    const char *share_path;        /* host dir shared into the guest via 9p */
    const char *share_guest_path;  /* guest mount point (default "/workspace") */
    const char *ports;             /* host->guest TCP fwd: "8080" or "8080:3000" */
    const char *const *env;        /* NULL-terminated array of "KEY=VALUE" */
    const char *workdir;           /* guest working directory */
    uint64_t    ram_bytes;         /* guest RAM; 0 = default (2 GiB) */
    const char *accel;             /* "hvf"/"kvm"/"whp"; NULL = host default */
    contain_output_fn out_fn;      /* guest console sink; NULL = host stdout */
    void       *out_ctx;
    contain_exit_fn  exit_fn;      /* optional run-loop-exit notification */
    void       *exit_ctx;
} contain_config;

/* Boot a guest. Returns a handle, or NULL on failure. */
contain_vm *contain_start(const contain_config *cfg);

/* Feed bytes to the guest console (as if typed). Thread-safe. */
void contain_write(contain_vm *vm, const uint8_t *data, size_t len);

/* Non-zero once the guest has powered off / been stopped. */
int contain_is_finished(contain_vm *vm);

/* Stop a running guest and join its thread (idempotent). Handle stays valid. */
void contain_stop(contain_vm *vm);

/* Stop if needed, tear down, and free the handle. Do not use it afterward. */
void contain_free(contain_vm *vm);

/* Download the host-arch guest kernel to dest_path if missing (a sandbox path).
 * Returns 0 on success (present or fetched), -1 on error. Blocking. */
int contain_fetch_kernel(const char *dest_path);

/* Pull a public OCI/Docker image and unpack its rootfs into dest_dir.
 * arch is "amd64"/"arm64" or NULL for the host arch. 0 on success, -1 on error.
 * Blocking — call off your UI thread. */
int contain_pull_image(const char *image_ref, const char *dest_dir, const char *arch);

#ifdef __cplusplus
}
#endif

#endif /* CONTAIN_H */
