// SPDX-License-Identifier: MIT

#define _GNU_SOURCE

#include <lean/lean.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

static lean_object *lk_uds_error(const char *prefix) {
  char buf[512];
  snprintf(buf, sizeof(buf), "%s: %s", prefix, strerror(errno));
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(buf)));
}

static lean_object *lk_uds_string_error(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

lean_object *lk_uds_bind(lean_object *path_obj) {
  const char *path = lean_string_cstr(path_obj);
  if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
    return lk_uds_string_error("UDS path is too long");
  }

  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return lk_uds_error("socket");

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

  (void)unlink(path);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return lk_uds_error("bind");
  }
  if (chmod(path, S_IRUSR | S_IWUSR) != 0) {
    int saved = errno;
    close(fd);
    unlink(path);
    errno = saved;
    return lk_uds_error("chmod");
  }
  if (listen(fd, 64) != 0) {
    int saved = errno;
    close(fd);
    unlink(path);
    errno = saved;
    return lk_uds_error("listen");
  }

  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}

lean_object *lk_uds_accept(uint32_t listener_fd) {
  int fd = accept4((int)listener_fd, NULL, NULL, SOCK_CLOEXEC);
  if (fd < 0) return lk_uds_error("accept4");
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}

lean_object *lk_uds_connect(lean_object *path_obj) {
  const char *path = lean_string_cstr(path_obj);
  if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
    return lk_uds_string_error("UDS path is too long");
  }

  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return lk_uds_error("socket");

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return lk_uds_error("connect");
  }

  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}

lean_object *lk_uds_read(uint32_t fd, uint32_t max_bytes) {
  lean_object *out = lean_alloc_sarray(1, max_bytes, max_bytes);
  ssize_t n = read((int)fd, lean_sarray_cptr(out), max_bytes);
  if (n < 0) {
    lean_dec_ref(out);
    return lk_uds_error("read");
  }
  lean_sarray_set_size(out, (size_t)n);
  return lean_io_result_mk_ok(out);
}

lean_object *lk_uds_write(uint32_t fd, lean_object *bytes) {
  size_t len = lean_sarray_size(bytes);
  uint8_t *ptr = lean_sarray_cptr(bytes);
  size_t written = 0;
  while (written < len) {
    ssize_t n = write((int)fd, ptr + written, len - written);
    if (n < 0) {
      if (errno == EINTR) continue;
      return lk_uds_error("write");
    }
    if (n == 0) return lk_uds_string_error("write returned zero");
    written += (size_t)n;
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)written));
}

lean_object *lk_uds_close(uint32_t fd) {
  if (close((int)fd) != 0) return lk_uds_error("close");
  return lean_io_result_mk_ok(lean_box(0));
}

lean_object *lk_uds_shutdown(uint32_t fd) {
  if (shutdown((int)fd, SHUT_RDWR) != 0 && errno != ENOTCONN) return lk_uds_error("shutdown");
  return lean_io_result_mk_ok(lean_box(0));
}

lean_object *lk_uds_peer_uid(uint32_t fd) {
  struct ucred cred;
  socklen_t len = sizeof(cred);
  if (getsockopt((int)fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) {
    return lk_uds_error("getsockopt(SO_PEERCRED)");
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)cred.uid));
}

lean_object *lk_uds_current_uid(void) {
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)getuid()));
}

// setenv(name, value, overwrite=0): only sets if not already in the
// environment. Real process env always wins over .env, so a `.env` line
// can never silently override an explicit `LEANKOHAKU_*=...` already in the
// shell. Returns 0 on any non-fatal outcome (already set, success); only
// signals an error when setenv itself fails (ENOMEM / EINVAL on bad name).
lean_object *lk_setenv_if_absent(lean_object *name_obj, lean_object *value_obj) {
  const char *name = lean_string_cstr(name_obj);
  const char *value = lean_string_cstr(value_obj);
  if (name[0] == '\0' || strchr(name, '=') != NULL) {
    return lk_uds_string_error("invalid env var name");
  }
  if (setenv(name, value, /*overwrite=*/0) != 0) {
    return lk_uds_error("setenv");
  }
  return lean_io_result_mk_ok(lean_box(0));
}
