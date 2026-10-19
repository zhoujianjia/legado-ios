/* A bounded, short-lived macOS CLI experiment. Unlike dispatch-signal-mask.c,
 * this owns a SIGIO handler and temporarily changes its own threads' masks.
 * It does not initialize a JVM or change an application's signal handling. */
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

enum { CASE_COUNT = 2, PROCESS_DEADLINE_SECONDS = 15, DELIVERY_WINDOW_MS = 750 };

typedef struct {
    const char *role;
    pthread_t thread;
    uint64_t thread_id;
    sigset_t original_mask;
    dispatch_semaphore_t ready;
    dispatch_semaphore_t start;
    dispatch_semaphore_t armed;
    dispatch_semaphore_t release;
    dispatch_semaphore_t done;
    int thread_id_result;
    int save_result;
    int block_result;
    int unblock_result;
    int inspect_result;
    int restore_result;
    int initial_sigio_blocked;
    int armed_sigio_blocked;
    bool restore_verified;
    bool start_timed_out;
    bool release_timed_out;
    bool routine_reached_return;
    bool kill_attempted;
    int probe_zero_result;
    int kill_result;
    int delivery_window_ms;
    int handler_byte_count;
    int handler_signal;
    int handler_code;
    int handler_sender_pid;
    bool handler_has_siginfo;
    bool handler_write_failed;
} Target;

static dispatch_time_t process_deadline;
static volatile sig_atomic_t handler_write_fd = -1;
static volatile sig_atomic_t handler_signal_number = -1;
static volatile sig_atomic_t handler_signal_code = -1;
static volatile sig_atomic_t handler_sender_pid = -1;
static volatile sig_atomic_t handler_has_siginfo = 0;
static volatile sig_atomic_t handler_write_failed = 0;

/* Only scalar sig_atomic_t assignments and the async-signal-safe write are used.
 * The nonblocking pipe gets one fixed byte, never formatted text or a pointer.
 * Thread identity is deliberately NOT queried from a signal handler. */
static void receive_sigio(int signal_number, siginfo_t *information, void *context) {
    (void)context;
    int saved_errno = errno;
    const unsigned char marker = 0x49;
    handler_signal_number = signal_number;
    handler_has_siginfo = information != NULL;
    if (information != NULL) {
        handler_signal_code = information->si_code;
        handler_sender_pid = (sig_atomic_t)information->si_pid;
    }
    if (write((int)handler_write_fd, &marker, sizeof(marker)) != (ssize_t)sizeof(marker)) {
        handler_write_failed = 1;
    }
    errno = saved_errno;
}

static int64_t monotonic_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        perror("clock_gettime");
        exit(1);
    }
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static bool masks_equal(const sigset_t *left, const sigset_t *right) {
    for (int number = 1; number < NSIG; number++) {
        if (sigismember(left, number) != sigismember(right, number)) return false;
    }
    return true;
}

static void target_main(Target *target) {
    sigset_t sigio;
    sigemptyset(&sigio);
    sigaddset(&sigio, SIGIO);
    target->thread = pthread_self();
    target->thread_id_result = pthread_threadid_np(NULL, &target->thread_id);
    target->save_result = pthread_sigmask(SIG_BLOCK, NULL, &target->original_mask);
    if (target->save_result == 0) {
        target->initial_sigio_blocked = sigismember(&target->original_mask, SIGIO);
        /* Both targets remain blocked until main explicitly arms one case. */
        target->block_result = pthread_sigmask(SIG_BLOCK, &sigio, NULL);
    }
    dispatch_semaphore_signal(target->ready);
    if (target->thread_id_result != 0 || target->save_result != 0 || target->block_result != 0) {
        fprintf(stderr, "%s setup failed: thread=%d save=%d block=%d\n", target->role,
                target->thread_id_result, target->save_result, target->block_result);
    } else if (dispatch_semaphore_wait(target->start, process_deadline) != 0) {
        target->start_timed_out = true;
        fprintf(stderr, "%s did not receive its start command before the process deadline\n", target->role);
    } else {
        sigset_t armed_mask;
        target->unblock_result = pthread_sigmask(SIG_UNBLOCK, &sigio, NULL);
        target->inspect_result = pthread_sigmask(SIG_BLOCK, NULL, &armed_mask);
        if (target->inspect_result == 0) target->armed_sigio_blocked = sigismember(&armed_mask, SIGIO);
        dispatch_semaphore_signal(target->armed);
        if (dispatch_semaphore_wait(target->release, process_deadline) != 0) {
            target->release_timed_out = true;
            fprintf(stderr, "%s did not receive its release command before the process deadline\n", target->role);
        }
    }
    if (target->save_result == 0) {
        sigset_t restored_mask;
        target->restore_result = pthread_sigmask(SIG_SETMASK, &target->original_mask, NULL);
        if (target->restore_result == 0 && pthread_sigmask(SIG_BLOCK, NULL, &restored_mask) == 0) {
            target->restore_verified = masks_equal(&restored_mask, &target->original_mask);
        }
    }
    target->routine_reached_return = true;
    /* Last use of shared objects. The detached pthread needs no unbounded join. */
    dispatch_semaphore_signal(target->done);
}

static void *pthread_entry(void *argument) {
    target_main(argument);
    return NULL;
}

static bool wait_for(dispatch_semaphore_t event, const char *phase, const char *role) {
    if (dispatch_semaphore_wait(event, process_deadline) == 0) return true;
    fprintf(stderr, "%s did not reach %s before the process deadline\n", role, phase);
    return false;
}

static bool configure_pipe_end(int descriptor) {
    int flags = fcntl(descriptor, F_GETFL);
    if (flags == -1 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == -1 ||
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1) {
        perror("fcntl nonblocking pipe");
        return false;
    }
    return true;
}

static bool observe_delivery(int descriptor, Target *target) {
    int64_t until = monotonic_ms() + target->delivery_window_ms;
    if (target->delivery_window_ms > 0) {
        for (;;) {
            int64_t remaining = until - monotonic_ms();
            if (remaining <= 0) break;
            struct pollfd event = { .fd = descriptor, .events = POLLIN, .revents = 0 };
            int polled = poll(&event, 1, remaining > INT_MAX ? INT_MAX : (int)remaining);
            if (polled < 0 && errno == EINTR) continue;
            if (polled < 0) {
                perror("poll handler pipe");
                return false;
            }
            if (polled == 0) break;
            if ((event.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                fprintf(stderr, "Handler pipe returned unexpected poll events: %d\n", event.revents);
                return false;
            }
            if ((event.revents & POLLIN) != 0) break;
        }
    }
    unsigned char markers[16];
    ssize_t count;
    int64_t read_deadline = monotonic_ms() + 100;
    do {
        count = read(descriptor, markers, sizeof(markers));
    } while (count < 0 && errno == EINTR && monotonic_ms() < read_deadline);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) count = 0;
    if (count < 0) {
        perror("read handler pipe");
        return false;
    }
    for (ssize_t index = 0; index < count; index++) {
        if (markers[index] != 0x49) {
            fprintf(stderr, "Handler pipe contained an unexpected marker\n");
            return false;
        }
    }
    target->handler_byte_count = (int)count;
    target->handler_signal = handler_signal_number;
    target->handler_code = handler_signal_code;
    target->handler_sender_pid = handler_sender_pid;
    target->handler_has_siginfo = handler_has_siginfo != 0;
    target->handler_write_failed = handler_write_failed != 0;
    return true;
}

static void print_target(const Target *target) {
    printf("{\"role\":\"%s\",\"threadID\":%llu,\"saveMaskReturnCode\":%d,"
           "\"initialSigioBlocked\":%d,\"blockReturnCode\":%d,\"unblockReturnCode\":%d,"
           "\"armedMaskReadReturnCode\":%d,\"armedSigioBlocked\":%d,\"killAttempted\":%s,"
           "\"probeZeroResult\":%d,\"pthreadKillReturnCode\":%d,\"handlerObservationWindowMilliseconds\":%d,"
           "\"handlerByteCount\":%d,\"handlerHasSiginfo\":%s,\"handlerSignalNumber\":%d,"
           "\"handlerSignalCode\":%d,\"handlerSenderPID\":%d,\"handlerWriteFailed\":%s,"
           "\"startTimedOut\":%s,\"releaseTimedOut\":%s,\"restoreMaskReturnCode\":%d,"
           "\"fullOriginalMaskRestored\":%s,\"routineReachedReturn\":%s}",
           target->role, (unsigned long long)target->thread_id, target->save_result,
           target->initial_sigio_blocked, target->block_result, target->unblock_result,
           target->inspect_result, target->armed_sigio_blocked, target->kill_attempted ? "true" : "false",
           target->probe_zero_result, target->kill_result, target->delivery_window_ms, target->handler_byte_count,
           target->handler_has_siginfo ? "true" : "false", target->handler_signal,
           target->handler_code, target->handler_sender_pid, target->handler_write_failed ? "true" : "false",
           target->start_timed_out ? "true" : "false", target->release_timed_out ? "true" : "false",
           target->restore_result, target->restore_verified ? "true" : "false",
           target->routine_reached_return ? "true" : "false");
}

int main(void) {
    int pipe_descriptors[2];
    if (pipe(pipe_descriptors) != 0) { perror("pipe"); return 1; }
    if (!configure_pipe_end(pipe_descriptors[0]) || !configure_pipe_end(pipe_descriptors[1])) return 1;
    handler_write_fd = pipe_descriptors[1];
    sigset_t original_main_mask, sigio;
    sigemptyset(&sigio);
    sigaddset(&sigio, SIGIO);
    int mask_result = pthread_sigmask(SIG_BLOCK, &sigio, &original_main_mask);
    if (mask_result != 0) { fprintf(stderr, "Main SIGIO block failed: %d\n", mask_result); return 1; }
    struct sigaction original_action;
    struct sigaction action = {0};
    action.sa_sigaction = receive_sigio;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGIO, &action, &original_action) != 0) { perror("sigaction install"); return 1; }
    uint64_t sender_thread_id = 0;
    if (pthread_threadid_np(NULL, &sender_thread_id) != 0) { fprintf(stderr, "Cannot inspect main thread ID\n"); return 1; }
    process_deadline = dispatch_time(DISPATCH_TIME_NOW, PROCESS_DEADLINE_SECONDS * NSEC_PER_SEC);
    int64_t began = monotonic_ms();
    Target targets[CASE_COUNT] = {0};
    targets[0].role = "concurrent-user-initiated-dispatch-worker";
    targets[1].role = "ordinary-pthread-create";
    for (int index = 0; index < CASE_COUNT; index++) {
        targets[index].ready = dispatch_semaphore_create(0);
        targets[index].start = dispatch_semaphore_create(0);
        targets[index].armed = dispatch_semaphore_create(0);
        targets[index].release = dispatch_semaphore_create(0);
        targets[index].done = dispatch_semaphore_create(0);
        targets[index].save_result = targets[index].block_result = targets[index].unblock_result = -1;
        targets[index].inspect_result = targets[index].restore_result = targets[index].kill_result = -1;
        targets[index].probe_zero_result = -1;
        targets[index].initial_sigio_blocked = targets[index].armed_sigio_blocked = -1;
        targets[index].handler_signal = targets[index].handler_code = targets[index].handler_sender_pid = -1;
        if (targets[index].ready == NULL || targets[index].start == NULL || targets[index].armed == NULL ||
            targets[index].release == NULL || targets[index].done == NULL) {
            fprintf(stderr, "Cannot allocate target synchronization objects\n");
            return 1;
        }
    }
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
    dispatch_queue_t queue = dispatch_queue_create("io.yuedu.legado.signal-delivery", attributes);
    if (queue == NULL) { fprintf(stderr, "Cannot allocate dispatch queue\n"); return 1; }
    Target *dispatch_target = &targets[0];
    dispatch_async(queue, ^{ target_main(dispatch_target); });
    pthread_attr_t thread_attributes;
    int create_result = pthread_attr_init(&thread_attributes);
    if (create_result != 0) { fprintf(stderr, "pthread_attr_init failed: %d\n", create_result); return 1; }
    create_result = pthread_attr_setdetachstate(&thread_attributes, PTHREAD_CREATE_DETACHED);
    if (create_result == 0) {
        pthread_t created_thread;
        create_result = pthread_create(&created_thread, &thread_attributes, pthread_entry, &targets[1]);
    }
    int destroy_result = pthread_attr_destroy(&thread_attributes);
    if (create_result != 0 || destroy_result != 0) {
        fprintf(stderr, "Detached pthread setup failed: create=%d attributesDestroy=%d\n", create_result, destroy_result);
        return 1;
    }
    for (int index = 0; index < CASE_COUNT; index++) {
        Target *target = &targets[index];
        if (!wait_for(target->ready, "ready", target->role)) return 1;
        if (target->thread_id_result != 0 || target->save_result != 0 || target->block_result != 0) return 1;
    }
    bool distinct_threads = targets[0].thread_id != targets[1].thread_id &&
        targets[0].thread_id != sender_thread_id && targets[1].thread_id != sender_thread_id;
    if (!distinct_threads) { fprintf(stderr, "Targets and sender did not have three distinct thread IDs\n"); return 1; }
    bool delivery_consistent = true;
    for (int index = 0; index < CASE_COUNT; index++) {
        Target *target = &targets[index];
        handler_signal_number = handler_signal_code = handler_sender_pid = -1;
        handler_has_siginfo = handler_write_failed = 0;
        dispatch_semaphore_signal(target->start);
        if (!wait_for(target->armed, "armed", target->role)) return 1;
        if (target->unblock_result != 0 || target->inspect_result != 0 || target->armed_sigio_blocked != 0) {
            fprintf(stderr, "%s could not verifiably unblock SIGIO: unblock=%d inspect=%d blocked=%d\n",
                    target->role, target->unblock_result, target->inspect_result, target->armed_sigio_blocked);
            return 1;
        }
        target->kill_attempted = true;
        target->probe_zero_result = pthread_kill(target->thread, 0);
        target->kill_result = pthread_kill(target->thread, SIGIO);
        /* A rejected send is a valid observation, with no wait for an event it
         * did not request. No particular Darwin return value is assumed. */
        target->delivery_window_ms = target->kill_result == 0 ? DELIVERY_WINDOW_MS : 0;
        if (!observe_delivery(pipe_descriptors[0], target)) return 1;
        bool received_one = target->handler_byte_count == 1 && target->handler_signal == SIGIO &&
            target->handler_has_siginfo && !target->handler_write_failed;
        bool consistent = target->kill_result == 0 ? received_one : target->handler_byte_count == 0;
        if (!consistent) {
            fprintf(stderr, "%s send/delivery mismatch: kill=%d handlerBytes=%d signal=%d writeFailed=%d\n",
                    target->role, target->kill_result, target->handler_byte_count,
                    target->handler_signal, target->handler_write_failed);
            delivery_consistent = false;
        }
        dispatch_semaphore_signal(target->release);
        if (!wait_for(target->done, "done", target->role)) return 1;
        if (target->restore_result != 0 || !target->restore_verified || target->start_timed_out || target->release_timed_out) {
            fprintf(stderr, "%s did not cleanly restore its original signal mask\n", target->role);
            return 1;
        }
    }
    if (sigaction(SIGIO, &original_action, NULL) != 0) { perror("sigaction restore"); return 1; }
    /* On a failed delivery observation keep SIGIO blocked until process exit:
     * an unobserved pending signal must not run the restored default handler. */
    bool main_mask_restored = false;
    if (delivery_consistent) {
        mask_result = pthread_sigmask(SIG_SETMASK, &original_main_mask, NULL);
        if (mask_result != 0) { fprintf(stderr, "Main signal-mask restore failed: %d\n", mask_result); return 1; }
        main_mask_restored = true;
    }
    close(pipe_descriptors[0]);
    close(pipe_descriptors[1]);
    printf("{\"schemaVersion\":1,\"executionPlatform\":\"macos-command-line\","
           "\"changesSignalMask\":true,\"installsHandler\":true,\"runtimeExecuted\":false,"
           "\"iosValidationPassed\":false,\"processDeadlineMilliseconds\":%d,\"elapsedMilliseconds\":%lld,"
           "\"signalNumber\":%d,\"senderPID\":%d,\"senderThreadID\":%llu,\"distinctTargetAndSenderThreads\":%s,"
           "\"handlerTransport\":\"SA_SIGINFO; nonblocking pipe; one fixed byte\","
           "\"handlerThreadIdentityQueried\":false,\"onlyProbeSendMechanism\":\"pthread_kill from main\","
           "\"originalHandlerRestored\":true,\"originalMainMaskRestored\":%s,"
           "\"sendAndObservedDeliveryConsistent\":%s,\"observations\":[",
           PROCESS_DEADLINE_SECONDS * 1000, (long long)(monotonic_ms() - began), SIGIO, (int)getpid(),
           (unsigned long long)sender_thread_id, distinct_threads ? "true" : "false",
           main_mask_restored ? "true" : "false", delivery_consistent ? "true" : "false");
    for (int index = 0; index < CASE_COUNT; index++) {
        if (index > 0) printf(",");
        print_target(&targets[index]);
    }
    printf("]}\n");
    for (int index = 0; index < CASE_COUNT; index++) {
        dispatch_release(targets[index].ready);
        dispatch_release(targets[index].start);
        dispatch_release(targets[index].armed);
        dispatch_release(targets[index].release);
        dispatch_release(targets[index].done);
    }
    dispatch_release(queue);
    return delivery_consistent ? 0 : 2;
}
