/* Read-only Darwin dispatch-thread diagnostics. Does not initialize a JVM,
 * install a signal handler, or change any thread's signal mask. */
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>

static int observe(const char *role, int expected_main) {
    sigset_t mask;
    uint64_t thread_id = 0;
    int status = pthread_sigmask(SIG_BLOCK, NULL, &mask);
    if (status != 0 || pthread_threadid_np(NULL, &thread_id) != 0) {
        fprintf(stderr, "Cannot inspect the current thread: %d\n", status);
        return 1;
    }
    int is_main = pthread_main_np() != 0;
    if (is_main != expected_main) {
        fprintf(stderr, "Diagnostic did not execute on the expected thread\n");
        return 1;
    }
    printf("{\"role\":\"%s\",\"threadID\":%llu,\"isMainThread\":%s,"
           "\"sigio\":%d,\"sigioBlocked\":%s,\"blockedSignals\":[",
           role, (unsigned long long)thread_id, is_main ? "true" : "false",
           SIGIO, sigismember(&mask, SIGIO) == 1 ? "true" : "false");
    int first = 1;
    for (int signal_number = 1; signal_number < NSIG; signal_number++) {
        if (sigismember(&mask, signal_number) == 1) {
            printf("%s%d", first ? "" : ",", signal_number);
            first = 0;
        }
    }
    printf("]}");
    fflush(stdout);
    return 0;
}

int main(void) {
    printf("{\"schemaVersion\":1,\"executionPlatform\":\"macos-command-line\","
           "\"changesSignalMask\":false,\"runtimeExecuted\":false,"
           "\"iosValidationPassed\":false,\"observations\":[");
    if (observe("main", 1) != 0) return 1;
    printf(",");
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
    dispatch_queue_t queue = dispatch_queue_create("io.yuedu.legado.signal-diagnostic", attributes);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block int status = 1;
    dispatch_async(queue, ^{
        status = observe("concurrent-dispatch-worker", 0);
        dispatch_semaphore_signal(finished);
    });
    /* This is a short-lived command-line diagnostic, not an application UI. */
    long waited = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (waited != 0) {
        fprintf(stderr, "Dispatch observation did not complete before its deadline\n");
        return 1;
    }
    printf("]}\n");
    dispatch_release(finished);
    dispatch_release(queue);
    return status;
}
