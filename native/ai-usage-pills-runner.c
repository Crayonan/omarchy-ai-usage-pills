#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef REQUIRED_UID
#define REQUIRED_UID 0
#endif

#ifndef KILL_GRACE_MS
#define KILL_GRACE_MS 2000U
#endif

#define MIN_TIMEOUT_MS 100U
#define MAX_TIMEOUT_MS 3600000U
#define MIN_OUTPUT_BYTES 1024U
#define MAX_OUTPUT_BYTES 1048576U
#define FINAL_DRAIN_MS 500U
#define READ_CHUNK_BYTES 8192U

#define EXIT_BACKEND_FAILED 1
#define EXIT_INTERNAL_ERROR 2
#define EXIT_TIMED_OUT 124
#define EXIT_OUTPUT_OVERFLOW 125
#define EXIT_NO_BACKEND 126

extern char **environ;

struct output_buffer {
  unsigned char *data;
  size_t length;
  size_t capacity;
};

static volatile sig_atomic_t received_signal = 0;

static void remember_signal(int signal_number) {
  received_signal = signal_number;
}

static uint64_t monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return 0;
  return (uint64_t)now.tv_sec * 1000U + (uint64_t)now.tv_nsec / 1000000U;
}

static bool parse_bounded_number(const char *text, uint64_t minimum,
                                 uint64_t maximum, uint64_t *value) {
  char *end = NULL;
  errno = 0;
  unsigned long long parsed = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || parsed < minimum ||
      parsed > maximum) {
    return false;
  }
  *value = (uint64_t)parsed;
  return true;
}

static int make_pipe(int descriptors[2]) {
  return pipe2(descriptors, O_CLOEXEC);
}

static void close_if_open(int *descriptor) {
  if (*descriptor < 0)
    return;
  close(*descriptor);
  *descriptor = -1;
}
static void close_pipe(int descriptors[2]) {
  close_if_open(&descriptors[0]);
  close_if_open(&descriptors[1]);
}

static void reap_child(pid_t child) {
  while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {
  }
}

static bool set_nonblocking(int descriptor) {
  int flags = fcntl(descriptor, F_GETFL);
  return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0;
}

static void report_child_status(int descriptor, unsigned char marker) {
  ssize_t ignored;
  do {
    ignored = write(descriptor, &marker, sizeof(marker));
  } while (ignored < 0 && errno == EINTR);
}

static void record_candidate_failure(char *diagnostics, size_t capacity,
                                     const char *path, const char *reason) {
  size_t used = strlen(diagnostics);
  if (used >= capacity - 1)
    return;
  snprintf(diagnostics + used, capacity - used, "%s%s: %s",
           used == 0 ? "" : "; ", path, reason);
}

static bool validate_candidate(int descriptor, char *reason,
                               size_t reason_capacity) {
  struct stat metadata;
  if (fstat(descriptor, &metadata) != 0) {
    snprintf(reason, reason_capacity, "cannot inspect: %s", strerror(errno));
    return false;
  }
  if (!S_ISREG(metadata.st_mode)) {
    snprintf(reason, reason_capacity, "rejected non-regular candidate");
    return false;
  }
  if (metadata.st_uid != (uid_t)REQUIRED_UID) {
    snprintf(reason, reason_capacity, "owner uid %lu, expected %u",
             (unsigned long)metadata.st_uid, (unsigned int)REQUIRED_UID);
    return false;
  }
  if ((metadata.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
    snprintf(reason, reason_capacity, "rejected writable candidate");
    return false;
  }
  if ((metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0) {
    snprintf(reason, reason_capacity, "rejected non-executable candidate");
    return false;
  }
  return true;
}

static _Noreturn void exec_backend(const char *const *candidates,
                                   size_t candidate_count,
                                   int status_descriptor) {
  char diagnostics[1024] = "";

  for (size_t index = 0; index < candidate_count; ++index) {
    const char *path = candidates[index];
    char reason[256];
    int descriptor = open(path, O_PATH | O_NOFOLLOW);
    if (descriptor < 0) {
      snprintf(reason, sizeof(reason), "cannot open: %s", strerror(errno));
      record_candidate_failure(diagnostics, sizeof(diagnostics), path, reason);
      continue;
    }

    if (!validate_candidate(descriptor, reason, sizeof(reason))) {
      close(descriptor);
      record_candidate_failure(diagnostics, sizeof(diagnostics), path, reason);
      continue;
    }

    char *const arguments[] = {(char *)path, (char *)"usage", (char *)"--json",
                               NULL};
    execveat(descriptor, "", arguments, environ, AT_EMPTY_PATH);

    int exec_error = errno;
    close(descriptor);
    snprintf(reason, sizeof(reason), "cannot execute: %s",
             strerror(exec_error));
    record_candidate_failure(diagnostics, sizeof(diagnostics), path, reason);
  }

  dprintf(STDERR_FILENO,
          "ai-usage-pills launcher: no trusted backend could be invoked (%s)\n",
          diagnostics);
  report_child_status(status_descriptor, EXIT_NO_BACKEND);
  _exit(EXIT_NO_BACKEND);
}

static _Noreturn void child_main(int stdout_pipe[2], int stderr_pipe[2],
                                 int status_pipe[2],
                                 const char *const *candidates,
                                 size_t candidate_count,
                                 const sigset_t *original_signal_mask) {
  signal(SIGTERM, SIG_DFL);
  signal(SIGINT, SIG_DFL);
  signal(SIGHUP, SIG_DFL);
  signal(SIGPIPE, SIG_DFL);
  if (sigprocmask(SIG_SETMASK, original_signal_mask, NULL) != 0) {
    report_child_status(status_pipe[1], EXIT_INTERNAL_ERROR);
    _exit(EXIT_INTERNAL_ERROR);
  }

#ifdef RUNNER_TESTING
  if (getenv("RUNNER_TEST_FAIL_SETUP") != NULL) {
    report_child_status(status_pipe[1], EXIT_INTERNAL_ERROR);
    _exit(EXIT_INTERNAL_ERROR);
  }
#endif

  pid_t original_parent = getppid();
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != original_parent ||
      setpgid(0, 0) != 0) {
    report_child_status(status_pipe[1], EXIT_INTERNAL_ERROR);
    _exit(EXIT_INTERNAL_ERROR);
  }

  if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0 ||
      dup2(stderr_pipe[1], STDERR_FILENO) < 0) {
    report_child_status(status_pipe[1], EXIT_INTERNAL_ERROR);
    _exit(EXIT_INTERNAL_ERROR);
  }

  close(stdout_pipe[0]);
  close(stdout_pipe[1]);
  close(stderr_pipe[0]);
  close(stderr_pipe[1]);
  close(status_pipe[0]);

  exec_backend(candidates, candidate_count, status_pipe[1]);
}

static void collect_available(int *descriptor, struct output_buffer *buffer,
                              bool *overflow) {
  unsigned char chunk[READ_CHUNK_BYTES];

  while (*descriptor >= 0) {
    ssize_t count = read(*descriptor, chunk, sizeof(chunk));
    if (count > 0) {
      size_t byte_count = (size_t)count;
      size_t room = buffer->capacity - buffer->length;
      size_t copy_count = byte_count < room ? byte_count : room;
      if (copy_count > 0) {
        memcpy(buffer->data + buffer->length, chunk, copy_count);
        buffer->length += copy_count;
      }
      if (byte_count > room) {
        *overflow = true;
        close_if_open(descriptor);
        return;
      }
      continue;
    }
    if (count == 0) {
      close_if_open(descriptor);
      return;
    }
    if (errno == EINTR)
      continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK)
      return;
    close_if_open(descriptor);
    return;
  }
}

static void collect_child_status(int *descriptor, int *child_report) {
  unsigned char marker;

  while (*descriptor >= 0) {
    ssize_t count = read(*descriptor, &marker, sizeof(marker));
    if (count > 0) {
      *child_report =
          marker == EXIT_NO_BACKEND ? EXIT_NO_BACKEND : EXIT_INTERNAL_ERROR;
      continue;
    }
    if (count == 0) {
      close_if_open(descriptor);
      return;
    }
    if (errno == EINTR)
      continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK)
      return;
    close_if_open(descriptor);
    return;
  }
}

static void signal_group(pid_t child, int signal_number) {
  if (kill(-child, signal_number) != 0 && errno != ESRCH) {
    dprintf(STDERR_FILENO,
            "ai-usage-pills launcher: cannot signal backend group: %s\n",
            strerror(errno));
  }
}
static bool process_group_exists(pid_t child) {
  if (kill(-child, 0) == 0)
    return true;
  return errno == EPERM;
}

static int write_all(int descriptor, const unsigned char *data, size_t length) {
  size_t written = 0;
  while (written < length) {
    ssize_t count = write(descriptor, data + written, length - written);
    if (count > 0) {
      written += (size_t)count;
      continue;
    }
    if (count < 0 && errno == EINTR)
      continue;
    return -1;
  }
  return 0;
}

static int supervise(const char *const *candidates, size_t candidate_count,
                     uint64_t timeout_ms, size_t output_limit) {
  int stdout_pipe[2] = {-1, -1};
  int stderr_pipe[2] = {-1, -1};
  int status_pipe[2] = {-1, -1};

  if (make_pipe(stdout_pipe) != 0 || make_pipe(stderr_pipe) != 0 ||
      make_pipe(status_pipe) != 0) {
    int pipe_error = errno;
    close_pipe(stdout_pipe);
    close_pipe(stderr_pipe);
    close_pipe(status_pipe);
    dprintf(STDERR_FILENO, "ai-usage-pills launcher: cannot create pipes: %s\n",
            strerror(pipe_error));
    return EXIT_INTERNAL_ERROR;
  }

  struct output_buffer stdout_buffer = {
      .data = malloc(output_limit), .length = 0, .capacity = output_limit};
  struct output_buffer stderr_buffer = {
      .data = malloc(output_limit), .length = 0, .capacity = output_limit};
  if (stdout_buffer.data == NULL || stderr_buffer.data == NULL) {
    dprintf(
        STDERR_FILENO,
        "ai-usage-pills launcher: cannot allocate bounded output buffers\n");
    free(stdout_buffer.data);
    free(stderr_buffer.data);
    close_pipe(stdout_pipe);
    close_pipe(stderr_pipe);
    close_pipe(status_pipe);
    return EXIT_INTERNAL_ERROR;
  }

  sigset_t termination_signals;
  sigset_t original_signal_mask;
  sigemptyset(&termination_signals);
  sigaddset(&termination_signals, SIGTERM);
  sigaddset(&termination_signals, SIGINT);
  sigaddset(&termination_signals, SIGHUP);
  if (sigprocmask(SIG_BLOCK, &termination_signals, &original_signal_mask) !=
      0) {
    dprintf(STDERR_FILENO,
            "ai-usage-pills launcher: cannot block termination signals: %s\n",
            strerror(errno));
    free(stdout_buffer.data);
    free(stderr_buffer.data);
    close_pipe(stdout_pipe);
    close_pipe(stderr_pipe);
    close_pipe(status_pipe);
    return EXIT_INTERNAL_ERROR;
  }

  pid_t child = fork();
  if (child < 0) {
    int fork_error = errno;
    sigprocmask(SIG_SETMASK, &original_signal_mask, NULL);
    dprintf(STDERR_FILENO, "ai-usage-pills launcher: cannot fork: %s\n",
            strerror(fork_error));
    free(stdout_buffer.data);
    free(stderr_buffer.data);
    close_pipe(stdout_pipe);
    close_pipe(stderr_pipe);
    close_pipe(status_pipe);
    return EXIT_INTERNAL_ERROR;
  }
  if (child == 0) {
    child_main(stdout_pipe, stderr_pipe, status_pipe, candidates,
               candidate_count, &original_signal_mask);
  }

  if (setpgid(child, child) != 0 && errno != EACCES && errno != ESRCH) {
    dprintf(
        STDERR_FILENO,
        "ai-usage-pills launcher: cannot create backend process group: %s\n",
        strerror(errno));
  }

  struct sigaction action = {.sa_handler = remember_signal};
  struct sigaction ignore_pipe = {.sa_handler = SIG_IGN};
  sigemptyset(&action.sa_mask);
  sigemptyset(&ignore_pipe.sa_mask);
  if (sigaction(SIGTERM, &action, NULL) != 0 ||
      sigaction(SIGINT, &action, NULL) != 0 ||
      sigaction(SIGHUP, &action, NULL) != 0 ||
      sigaction(SIGPIPE, &ignore_pipe, NULL) != 0) {
    int action_error = errno;
    signal_group(child, SIGKILL);
    kill(child, SIGKILL);
    close_pipe(stdout_pipe);
    close_pipe(stderr_pipe);
    close_pipe(status_pipe);
    reap_child(child);
    free(stdout_buffer.data);
    free(stderr_buffer.data);
    sigprocmask(SIG_SETMASK, &original_signal_mask, NULL);
    dprintf(STDERR_FILENO,
            "ai-usage-pills launcher: cannot install signal handlers: %s\n",
            strerror(action_error));
    return EXIT_INTERNAL_ERROR;
  }
  if (sigprocmask(SIG_SETMASK, &original_signal_mask, NULL) != 0) {
    int mask_error = errno;
    signal_group(child, SIGKILL);
    kill(child, SIGKILL);
    close_pipe(stdout_pipe);
    close_pipe(stderr_pipe);
    close_pipe(status_pipe);
    reap_child(child);
    free(stdout_buffer.data);
    free(stderr_buffer.data);
    dprintf(STDERR_FILENO,
            "ai-usage-pills launcher: cannot restore signal mask: %s\n",
            strerror(mask_error));
    return EXIT_INTERNAL_ERROR;
  }

  close(stdout_pipe[1]);
  close(stderr_pipe[1]);
  close(status_pipe[1]);
  int stdout_descriptor = stdout_pipe[0];
  int stderr_descriptor = stderr_pipe[0];
  int status_descriptor = status_pipe[0];

  if (!set_nonblocking(stdout_descriptor) ||
      !set_nonblocking(stderr_descriptor) ||
      !set_nonblocking(status_descriptor)) {
    signal_group(child, SIGKILL);
    dprintf(STDERR_FILENO,
            "ai-usage-pills launcher: cannot configure nonblocking pipes\n");
    close_if_open(&stdout_descriptor);
    close_if_open(&stderr_descriptor);
    close_if_open(&status_descriptor);
    reap_child(child);
    free(stdout_buffer.data);
    free(stderr_buffer.data);
    return EXIT_INTERNAL_ERROR;
  }

  uint64_t deadline = monotonic_ms() + timeout_ms;
  uint64_t kill_deadline = 0;
  uint64_t drain_deadline = 0;
  bool child_reaped = false;
  bool output_overflow = false;
  bool termination_started = false;
  bool kill_sent = false;
  int child_status = 0;
  int child_report = 0;
  int external_signal = 0;
  enum {
    TERMINATION_NONE,
    TERMINATION_CLEANUP,
    TERMINATION_OVERFLOW,
    TERMINATION_TIMEOUT,
    TERMINATION_EXTERNAL
  } termination_reason = TERMINATION_NONE;

  while (true) {
    uint64_t now = monotonic_ms();

    if (received_signal != 0 && !termination_started) {
      external_signal = received_signal;
      termination_reason = TERMINATION_EXTERNAL;
      termination_started = true;
      kill_deadline = now + KILL_GRACE_MS;
      signal_group(child, external_signal);
    }

    if (!termination_started && now >= deadline &&
        (!child_reaped || stdout_descriptor >= 0 || stderr_descriptor >= 0)) {
      termination_reason = TERMINATION_TIMEOUT;
      termination_started = true;
      kill_deadline = now + KILL_GRACE_MS;
      signal_group(child, SIGTERM);
    }

    if (termination_started && !kill_sent && now >= kill_deadline) {
      signal_group(child, SIGKILL);
      kill_sent = true;
      drain_deadline = now + FINAL_DRAIN_MS;
    }

    if (kill_sent && now >= drain_deadline) {
      close_if_open(&stdout_descriptor);
      close_if_open(&stderr_descriptor);
      close_if_open(&status_descriptor);
    }

    if (child_reaped && stdout_descriptor < 0 && stderr_descriptor < 0 &&
        status_descriptor < 0 && !process_group_exists(child)) {
      break;
    }
    if (kill_sent && now >= drain_deadline)
      break;

    struct pollfd descriptors[3] = {
        {.fd = stdout_descriptor, .events = POLLIN},
        {.fd = stderr_descriptor, .events = POLLIN},
        {.fd = status_descriptor, .events = POLLIN},
    };

    uint64_t next_event = deadline;
    if (termination_started && !kill_sent)
      next_event = kill_deadline;
    if (kill_sent)
      next_event = drain_deadline;
    int poll_timeout = 100;
    if (next_event <= now) {
      poll_timeout = 0;
    } else if (next_event - now < (uint64_t)poll_timeout) {
      poll_timeout = (int)(next_event - now);
    }

    int poll_result;
    do {
      poll_result = poll(descriptors, 3, poll_timeout);
    } while (poll_result < 0 && errno == EINTR && received_signal == 0);

    if (poll_result > 0) {
      if ((descriptors[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
        collect_available(&stdout_descriptor, &stdout_buffer, &output_overflow);
      }
      if ((descriptors[1].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
        collect_available(&stderr_descriptor, &stderr_buffer, &output_overflow);
      }
      if ((descriptors[2].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
        collect_child_status(&status_descriptor, &child_report);
      }
    }

    if (output_overflow && (termination_reason == TERMINATION_NONE ||
                            termination_reason == TERMINATION_CLEANUP)) {
      termination_reason = TERMINATION_OVERFLOW;
      if (!termination_started) {
        termination_started = true;
        kill_deadline = monotonic_ms() + KILL_GRACE_MS;
        signal_group(child, SIGTERM);
      }
    }

    if (!child_reaped) {
      pid_t waited = waitpid(child, &child_status, WNOHANG);
      if (waited == child) {
        child_reaped = true;
        if (!termination_started && process_group_exists(child)) {
          termination_reason = TERMINATION_CLEANUP;
          termination_started = true;
          kill_deadline = monotonic_ms() + KILL_GRACE_MS;
          signal_group(child, SIGTERM);
        }
      }
    }
  }

  collect_available(&stdout_descriptor, &stdout_buffer, &output_overflow);
  collect_available(&stderr_descriptor, &stderr_buffer, &output_overflow);
  collect_child_status(&status_descriptor, &child_report);
  close_if_open(&stdout_descriptor);
  close_if_open(&stderr_descriptor);
  close_if_open(&status_descriptor);

  write_all(STDOUT_FILENO, stdout_buffer.data, stdout_buffer.length);
  write_all(STDERR_FILENO, stderr_buffer.data, stderr_buffer.length);
  free(stdout_buffer.data);
  free(stderr_buffer.data);

  if (termination_reason == TERMINATION_OVERFLOW ||
      ((termination_reason == TERMINATION_NONE ||
        termination_reason == TERMINATION_CLEANUP) &&
       output_overflow))
    return EXIT_OUTPUT_OVERFLOW;
  if (termination_reason == TERMINATION_TIMEOUT)
    return EXIT_TIMED_OUT;
  if (termination_reason == TERMINATION_EXTERNAL)
    return 128 + external_signal;
  if (child_report != 0)
    return child_report;
  if (!child_reaped)
    return EXIT_INTERNAL_ERROR;
  if (WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0)
    return 0;
  return EXIT_BACKEND_FAILED;
}

int main(int argc, char **argv) {
#ifdef RUNNER_TESTING
  if (argc != 5) {
    dprintf(STDERR_FILENO,
            "usage: %s TIMEOUT_MS OUTPUT_LIMIT CANDIDATE_ONE CANDIDATE_TWO\n",
            argv[0]);
    return EXIT_INTERNAL_ERROR;
  }
  const char *candidates[] = {argv[3], argv[4]};
#else
  if (argc != 3) {
    dprintf(STDERR_FILENO, "usage: %s TIMEOUT_MS OUTPUT_LIMIT\n", argv[0]);
    return EXIT_INTERNAL_ERROR;
  }
  const char *candidates[] = {"/usr/bin/ai-usagebar",
                              "/usr/local/bin/ai-usagebar"};
#endif

  uint64_t timeout_ms;
  uint64_t output_limit;
  if (!parse_bounded_number(argv[1], MIN_TIMEOUT_MS, MAX_TIMEOUT_MS,
                            &timeout_ms) ||
      !parse_bounded_number(argv[2], MIN_OUTPUT_BYTES, MAX_OUTPUT_BYTES,
                            &output_limit)) {
    dprintf(STDERR_FILENO,
            "ai-usage-pills launcher: invalid timeout or output limit\n");
    return EXIT_INTERNAL_ERROR;
  }

  return supervise(candidates, sizeof(candidates) / sizeof(candidates[0]),
                   timeout_ms, (size_t)output_limit);
}
