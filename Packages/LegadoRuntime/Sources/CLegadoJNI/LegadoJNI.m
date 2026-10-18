#import <Foundation/Foundation.h>
#import "LegadoJNI.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/time.h>
#include <stdarg.h>
#include <stdio.h>
#if __has_feature(objc_arc)
#define LGR_AUTORELEASE(value) (value)
#else
#define LGR_AUTORELEASE(value) [(value) autorelease]
#endif

LGRResult LGRMakeResult(const uint8_t *bytes, size_t count, int32_t code) {
    LGRResult result = { NULL, 0, code };
    if (count && bytes) {
        result.bytes = malloc(count);
        if (!result.bytes) { result.code = 9; return result; }
        memcpy(result.bytes, bytes, count);
        result.count = count;
    }
    return result;
}
void LGRFreeResult(LGRResult result) { free(result.bytes); }
static LGRResult resultText(NSString *text, int32_t code) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return LGRMakeResult(data.bytes, data.length, code);
}

static pthread_mutex_t diagnosticsLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *diagnosticsRoot;
static NSString *diagnosticsCurrent;
static NSString *diagnosticsFailure;
static BOOL diagnosticsStarted;
static int diagnosticsFD = -1;
static FILE *diagnosticsVMOutput;
static int diagnosticsVMOutputError;

// JNI's documented vfprintf hook. Keep the original destination and copy the
// va_list before each consumer. This uses C I/O only, including on a fatal path.
static int diagnosticsVfprintf(FILE *stream, const char *format, va_list arguments) {
    va_list original;
    va_copy(original, arguments);
    int result = vfprintf(stream, format, original);
    va_end(original);
    pthread_mutex_lock(&diagnosticsLock);
    if (diagnosticsVMOutput) {
        va_list saved;
        va_copy(saved, arguments);
        int written = vfprintf(diagnosticsVMOutput, format, saved);
        va_end(saved);
        if (written < 0 || fflush(diagnosticsVMOutput) != 0 || fsync(fileno(diagnosticsVMOutput)) != 0) {
            diagnosticsVMOutputError = errno ? errno : EIO;
        }
    }
    pthread_mutex_unlock(&diagnosticsLock);
    return result;
}

LGRResult LGRSetDiagnosticsDirectory(LGRString directory) {
    @autoreleasepool {
        NSString *path = LGR_AUTORELEASE([[NSString alloc] initWithBytes:directory.bytes length:directory.count encoding:NSUTF8StringEncoding]);
        if (!path.isAbsolutePath || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            return resultText(@"Diagnostics directory must be an absolute UTF-8 path", 2);
        }
        path = path.stringByStandardizingPath;
        pthread_mutex_lock(&diagnosticsLock);
        BOOL same = [diagnosticsRoot isEqualToString:path];
        if ((!diagnosticsRoot && !diagnosticsStarted) || same) {
            if (!diagnosticsRoot) diagnosticsRoot = [path copy];
            pthread_mutex_unlock(&diagnosticsLock);
            return resultText(@"{}", 0);
        }
        pthread_mutex_unlock(&diagnosticsLock);
        return resultText(@"Process-scoped diagnostics cannot be reconfigured after startup", 10);
    }
}

// Called once while the JVM startup mutex is held. Inspecting saved diagnostics
// never reaches this rotation, so reopening the app preserves the last failure.
static NSString *beginDiagnostics(void) {
    pthread_mutex_lock(&diagnosticsLock);
    diagnosticsStarted = YES;
    if (!diagnosticsRoot) { pthread_mutex_unlock(&diagnosticsLock); return nil; }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *current = [diagnosticsRoot stringByAppendingPathComponent:@"current"];
    NSString *previous = [diagnosticsRoot stringByAppendingPathComponent:@"previous"];
    NSString *stagePath = nil;
    NSString *outputPath = nil;
    int outputFD = -1;
    NSError *error = nil;
    if (![manager createDirectoryAtPath:diagnosticsRoot withIntermediateDirectories:YES attributes:nil error:&error]) goto failed;
    for (NSString *path in @[current, previous]) {
        if ([manager fileExistsAtPath:path]) {
            NSDictionary *attributes = [manager attributesOfItemAtPath:path error:&error];
            if (!attributes) goto failed;
            if (![attributes[NSFileType] isEqual:NSFileTypeDirectory]) {
                diagnosticsFailure = [@"Diagnostics current/previous must be directories, not files or symlinks" copy];
                pthread_mutex_unlock(&diagnosticsLock);
                return diagnosticsFailure;
            }
        }
    }
    if ([manager fileExistsAtPath:current]) {
        if ([manager fileExistsAtPath:previous] && ![manager removeItemAtPath:previous error:&error]) goto failed;
        if (![manager moveItemAtPath:current toPath:previous error:&error]) goto failed;
    }
    if (![manager createDirectoryAtPath:current withIntermediateDirectories:NO attributes:nil error:&error]) goto failed;
    diagnosticsCurrent = [current copy];
    stagePath = [current stringByAppendingPathComponent:@"stages.log"];
    diagnosticsFD = open(stagePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (diagnosticsFD < 0) {
        diagnosticsFailure = [[NSString stringWithFormat:@"Cannot open diagnostics stage log (errno=%d)", errno] copy];
        pthread_mutex_unlock(&diagnosticsLock);
        return diagnosticsFailure;
    }
    outputPath = [current stringByAppendingPathComponent:@"vm-output.log"];
    outputFD = open(outputPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (outputFD >= 0) diagnosticsVMOutput = fdopen(outputFD, "a");
    if (!diagnosticsVMOutput) {
        int savedError = errno;
        if (outputFD >= 0) close(outputFD);
        close(diagnosticsFD); diagnosticsFD = -1;
        diagnosticsFailure = [[NSString stringWithFormat:@"Cannot open JVM output log (errno=%d)", savedError] copy];
        pthread_mutex_unlock(&diagnosticsLock);
        return diagnosticsFailure;
    }
    pthread_mutex_unlock(&diagnosticsLock);
    return nil;
failed:
    diagnosticsFailure = [[NSString stringWithFormat:@"Cannot prepare JVM startup diagnostics: %@", error.localizedDescription] copy];
    pthread_mutex_unlock(&diagnosticsLock);
    return diagnosticsFailure;
}

// Only fixed stage names and numeric metadata are written: never source JSON,
// script text, classpath options, request bodies, URLs or Java exception messages.
static BOOL recordStage(const char *stage, int32_t code) {
    pthread_mutex_lock(&diagnosticsLock);
    if (diagnosticsVMOutputError && !diagnosticsFailure) {
        diagnosticsFailure = [[NSString stringWithFormat:@"Cannot persist JVM output (errno=%d)", diagnosticsVMOutputError] copy];
    }
    if (diagnosticsFailure) { pthread_mutex_unlock(&diagnosticsLock); return NO; }
    if (diagnosticsFD < 0) { pthread_mutex_unlock(&diagnosticsLock); return YES; }
    struct timeval now = {0};
    gettimeofday(&now, NULL);
    uint64_t threadID = 0;
    pthread_threadid_np(NULL, &threadID);
    size_t stackSize = pthread_get_stacksize_np(pthread_self());
    char line[256];
    int count = snprintf(line, sizeof(line), "%lld.%06d stage=%s thread=%llu stackBytes=%zu code=%d\n",
                         (long long)now.tv_sec, (int)now.tv_usec, stage,
                         (unsigned long long)threadID, stackSize, code);
    size_t offset = 0;
    int savedError = count <= 0 || (size_t)count >= sizeof(line) ? EOVERFLOW : 0;
    while (!savedError && offset < (size_t)count) {
        ssize_t written = write(diagnosticsFD, line + offset, (size_t)count - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { savedError = written < 0 ? errno : EIO; break; }
        offset += (size_t)written;
    }
    if (!savedError && fsync(diagnosticsFD) != 0) savedError = errno;
    if (savedError) diagnosticsFailure = [[NSString stringWithFormat:@"Cannot persist JVM diagnostic stage (errno=%d)", savedError] copy];
    pthread_mutex_unlock(&diagnosticsLock);
    return savedError == 0;
}

static LGRResult diagnosticFailureResult(void) {
    return resultText(diagnosticsFailure ?: @"Cannot persist JVM diagnostics", 10);
}

#if defined(LGR_WITH_OPENJDK)
#if __has_include(<OpenJDK/jni.h>)
#include <OpenJDK/jni.h>
#else
#include <jni.h>
#endif
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
// Required by upstream static OpenJDK: registers statically linked native entrypoints.
extern void loadfunctions(void);
#endif
static JavaVM *vm;
static jclass facade;
static jmethodID createMethod, executeMethod, cancelMethod, closeMethod;
static pthread_mutex_t startupLock = PTHREAD_MUTEX_INITIALIZER;
static LGRHostCallback hostCallback;
static void *hostContext;
static NSString *configuredClassPath, *configuredJavaHome;
static int32_t configuredHeap;
static BOOL startupAttempted;
static BOOL runtimeReady;

static NSString *decode(LGRString value) {
    return LGR_AUTORELEASE([[NSString alloc] initWithBytes:value.bytes length:value.count encoding:NSUTF8StringEncoding]);
}
static jstring toJava(JNIEnv *env, NSString *value) {
    if (!value || value.length > INT32_MAX) return NULL;
    NSUInteger length = value.length;
    unichar *characters = malloc(MAX((NSUInteger)1, length) * sizeof(unichar));
    if (!characters) return NULL;
    [value getCharacters:characters range:NSMakeRange(0, length)];
    jstring result = (*env)->NewString(env, (const jchar *)characters, (jsize)length);
    free(characters);
    return result;
}
static NSString *fromJava(JNIEnv *env, jstring value) {
    if (!value) return nil;
    jsize length = (*env)->GetStringLength(env, value);
    const jchar *characters = (*env)->GetStringChars(env, value, NULL);
    if (!characters) return nil;
    NSString *result = LGR_AUTORELEASE([[NSString alloc] initWithCharacters:(const unichar *)characters length:(NSUInteger)length]);
    (*env)->ReleaseStringChars(env, value, characters);
    return result;
}
static NSString *exceptionText(JNIEnv *env) {
    jthrowable error = (*env)->ExceptionOccurred(env);
    if (!error) return nil;
    (*env)->ExceptionClear(env);
    jclass type = (*env)->GetObjectClass(env, error);
    jmethodID method = type ? (*env)->GetMethodID(env, type, "toString", "()Ljava/lang/String;") : NULL;
    jstring message = method ? (jstring)(*env)->CallObjectMethod(env, error, method) : NULL;
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); message = NULL; }
    NSString *result = message ? fromJava(env, message) : @"Java exception (message unavailable)";
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (message) (*env)->DeleteLocalRef(env, message);
    if (type) (*env)->DeleteLocalRef(env, type);
    (*env)->DeleteLocalRef(env, error);
    return result;
}
static jstring JNICALL dispatchHost(JNIEnv *env, jclass type, jstring task, jstring operation, jstring request) {
    (void)type;
    @autoreleasepool {
        NSString *taskText = fromJava(env, task), *operationText = fromJava(env, operation), *requestText = fromJava(env, request);
        if ((*env)->ExceptionCheck(env)) return NULL;
        if (!hostCallback) return toJava(env, @"{\"ok\":false,\"error\":{\"code\":\"unsupported_host\",\"message\":\"No iOS host adapter is configured\"}}");
        NSData *taskData = [taskText dataUsingEncoding:NSUTF8StringEncoding];
        NSData *opData = [operationText dataUsingEncoding:NSUTF8StringEncoding];
        NSData *requestData = [requestText dataUsingEncoding:NSUTF8StringEncoding];
        LGRResult response = hostCallback(hostContext, (LGRString){taskData.bytes, taskData.length},
                                          (LGRString){opData.bytes, opData.length},
                                          (LGRString){requestData.bytes, requestData.length});
        NSString *text = decode((LGRString){response.bytes, response.count});
        LGRFreeResult(response);
        return toJava(env, text ?: @"{\"ok\":false,\"error\":{\"code\":\"host_encoding\",\"message\":\"Invalid host UTF-8 response\"}}");
    }
}
int32_t LGRBridgeAvailable(void) { return 1; }
LGRResult LGRStart(LGRString classPath, LGRString javaHome, int32_t maximumHeapMB, LGRHostCallback callback, void *context) {
    @autoreleasepool {
        NSString *cp = decode(classPath), *home = decode(javaHome);
        if (!cp || !home || maximumHeapMB < 32) return resultText(@"Invalid JVM configuration", 2);
        pthread_mutex_lock(&startupLock);
        if (startupAttempted) {
            BOOL same = runtimeReady && facade && [configuredClassPath isEqual:cp] && [configuredJavaHome isEqual:home]
                && configuredHeap == maximumHeapMB && hostContext == context;
            pthread_mutex_unlock(&startupLock);
            return same ? resultText(@"{}", 0) : resultText(@"JVM is process scoped and cannot be restarted or reconfigured", 3);
        }
        startupAttempted = YES;
        NSString *diagnosticError = beginDiagnostics();
        if (diagnosticError || !recordStage("startup.pre", 0)) {
            pthread_mutex_unlock(&startupLock);
            return diagnosticFailureResult();
        }
        configuredClassPath = [cp copy]; configuredJavaHome = [home copy]; configuredHeap = maximumHeapMB;
        hostCallback = callback; hostContext = context;
        NSString *cpOption = [@"-Djava.class.path=" stringByAppendingString:cp];
        NSString *homeOption = [@"-Djava.home=" stringByAppendingString:home];
        NSString *heapOption = [NSString stringWithFormat:@"-Xmx%dm", maximumHeapMB];
        NSString *errorOption = diagnosticsCurrent ? [@"-XX:ErrorFile=" stringByAppendingString:[diagnosticsCurrent stringByAppendingPathComponent:@"hs_err_pid%p.log"]] : nil;
        JavaVMOption options[7] = {0};
        options[0].optionString = (char *)cpOption.UTF8String;
        options[1].optionString = (char *)homeOption.UTF8String;
        options[2].optionString = (char *)heapOption.UTF8String;
        options[3].optionString = "-Xint";
        options[4].optionString = "-Xshare:off";
        if (errorOption) {
            options[5].optionString = (char *)errorOption.UTF8String;
            options[6].optionString = "vfprintf";
            options[6].extraInfo = (void *)diagnosticsVfprintf;
        }
        JavaVMInitArgs args = {0};
        args.version = JNI_VERSION_1_8; args.nOptions = errorOption ? 7 : 5; args.options = options; args.ignoreUnrecognized = JNI_FALSE;
        JNIEnv *env = NULL;
#if TARGET_OS_IPHONE
        if (!recordStage("loadfunctions.before", 0)) { pthread_mutex_unlock(&startupLock); return diagnosticFailureResult(); }
        loadfunctions();
        if (!recordStage("loadfunctions.after", 0)) { pthread_mutex_unlock(&startupLock); return diagnosticFailureResult(); }
#endif
        if (!recordStage("JNI_CreateJavaVM.before", 0)) { pthread_mutex_unlock(&startupLock); return diagnosticFailureResult(); }
        jint status = JNI_CreateJavaVM(&vm, (void **)&env, &args);
        NSString *failure = nil;
        BOOL diagnosticOK = recordStage("JNI_CreateJavaVM.after", status);
        if (status != JNI_OK || !env) failure = [NSString stringWithFormat:@"JNI_CreateJavaVM failed: %d", status];
        BOOL vmAttached = status == JNI_OK && env != NULL;
        if (!failure && diagnosticOK) {
            diagnosticOK = recordStage("startup.attached", 0) && recordStage("facade.before", 0);
            jclass local = diagnosticOK ? (*env)->FindClass(env, "io/yuedu/legado/LegadoRuntime") : NULL;
            if (diagnosticOK) failure = exceptionText(env);
            diagnosticOK = diagnosticOK && recordStage("facade.after", failure || !local ? 7 : 0);
            if (!failure && local) {
                facade = (*env)->NewGlobalRef(env, local);
                (*env)->DeleteLocalRef(env, local);
                failure = exceptionText(env);
                if (!facade && !failure) failure = @"Cannot allocate JVM facade global reference";
                diagnosticOK = diagnosticOK && recordStage("methods.before", 0);
                if (!failure && diagnosticOK) {
                    createMethod = (*env)->GetStaticMethodID(env, facade, "createSession", "(Ljava/lang/String;)Ljava/lang/String;");
                    failure = exceptionText(env);
                }
                if (!failure && diagnosticOK) {
                    executeMethod = (*env)->GetStaticMethodID(env, facade, "execute", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
                    failure = exceptionText(env);
                }
                if (!failure && diagnosticOK) cancelMethod = (*env)->GetStaticMethodID(env, facade, "cancel", "(Ljava/lang/String;)Ljava/lang/String;");
                if (!failure && diagnosticOK) failure = exceptionText(env);
                if (!failure && diagnosticOK) closeMethod = (*env)->GetStaticMethodID(env, facade, "closeSession", "(Ljava/lang/String;)Ljava/lang/String;");
                if (!failure && diagnosticOK) failure = exceptionText(env);
                diagnosticOK = diagnosticOK && recordStage("methods.after", failure ? 7 : 0);
            } else if (!failure) failure = @"LegadoRuntime facade not found";
            if (!failure && diagnosticOK) {
                diagnosticOK = recordStage("RegisterNatives.before", 0);
            }
            if (!failure && diagnosticOK) {
                jclass nativeHost = (*env)->FindClass(env, "io/yuedu/legado/NativeHost");
                failure = exceptionText(env);
                if (!failure && nativeHost) {
                    JNINativeMethod method = { "dispatch", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", (void *)dispatchHost };
                    jint registered = (*env)->RegisterNatives(env, nativeHost, &method, 1);
                    failure = exceptionText(env);
                    if (!failure && registered != JNI_OK) failure = @"NativeHost registration failed";
                    (*env)->DeleteLocalRef(env, nativeHost);
                } else if (!failure) failure = @"NativeHost class not found";
                diagnosticOK = recordStage("RegisterNatives.after", failure ? 7 : 0);
            }
        }
        if ((failure || !diagnosticOK) && facade && vmAttached) { (*env)->DeleteGlobalRef(env, facade); facade = NULL; }
        if (vmAttached) {
            jint detached = (*vm)->DetachCurrentThread(vm);
            diagnosticOK = recordStage("startup.detached", detached) && diagnosticOK;
            if (detached != JNI_OK && !failure) failure = @"Cannot detach JVM startup thread";
        }
        if (diagnosticOK) diagnosticOK = recordStage("startup.complete", failure ? 4 : 0);
        runtimeReady = diagnosticOK && !failure;
        pthread_mutex_unlock(&startupLock);
        if (!diagnosticOK) return diagnosticFailureResult();
        return resultText(failure ?: @"{}", failure ? 4 : 0);
    }
}
// Each invocation gets its own JNIEnv and local frame. No JNIEnv crosses a Swift queue.
static LGRResult invoke(int method, LGRString *arguments, int count) {
    @autoreleasepool {
        if (method < 0 || method > 4 || count < 0 || count > 4) return resultText(@"Invalid JNI invocation", 7);
        pthread_mutex_lock(&startupLock);
        BOOL ready = runtimeReady && facade != NULL;
        pthread_mutex_unlock(&startupLock);
        if (!ready) return resultText(@"JVM has not started successfully", 5);
        if (!recordStage("thread.getEnv.before", method)) return diagnosticFailureResult();
        JNIEnv *env = NULL;
        jint status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8);
        if (!recordStage("thread.getEnv.after", status)) return diagnosticFailureResult();
        BOOL attached = status == JNI_EDETACHED;
        if (attached) {
            if (!recordStage("thread.attach.before", 0)) return diagnosticFailureResult();
            status = (*vm)->AttachCurrentThread(vm, (void **)&env, NULL);
            if (!recordStage("thread.attach.after", status)) {
                if (status == JNI_OK && env) (*vm)->DetachCurrentThread(vm);
                return diagnosticFailureResult();
            }
        }
        if (status != JNI_OK || !env) return resultText(@"Cannot attach worker thread to JVM", 6);
        if (!recordStage("thread.attached", 0)) {
            if (attached) (*vm)->DetachCurrentThread(vm);
            return diagnosticFailureResult();
        }
        if ((*env)->PushLocalFrame(env, 32) < 0) {
            exceptionText(env);
            recordStage("invoke.localFrame.failed", 9);
            if (attached) (*vm)->DetachCurrentThread(vm);
            return resultText(@"Cannot allocate JNI local frame", 9);
        }
        jvalue values[4] = {0};
        NSString *failure = nil;
        for (int i = 0; i < count; i++) {
            values[i].l = toJava(env, decode(arguments[i]));
            failure = exceptionText(env);
            if (!values[i].l && !failure) failure = @"Invalid UTF-8 input or allocation failure";
            if (failure) break;
        }
        // Resolve the new overload only when requested. Old clients and pinned
        // payloads can still use the original one-argument session API.
        jmethodID configuredCreate = NULL;
        if (!failure && method == 4) {
            configuredCreate = (*env)->GetStaticMethodID(env, facade, "createSession", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
            failure = exceptionText(env);
            if (!configuredCreate && !failure) failure = @"Configured session entry point is unavailable";
        }
        jmethodID methods[] = {createMethod, executeMethod, cancelMethod, closeMethod, configuredCreate};
        const char *beforeStages[] = {"invoke.createSession.before", "invoke.execute.before", "invoke.cancel.before", "invoke.closeSession.before", "invoke.configuredSession.before"};
        const char *afterStages[] = {"invoke.createSession.after", "invoke.execute.after", "invoke.cancel.after", "invoke.closeSession.after", "invoke.configuredSession.after"};
        BOOL diagnosticOK = recordStage(beforeStages[method], failure ? 7 : 0);
        jstring output = failure || !diagnosticOK ? NULL : (jstring)(*env)->CallStaticObjectMethodA(env, facade, methods[method], values);
        if (!failure) failure = exceptionText(env);
        diagnosticOK = recordStage(afterStages[method], failure ? 7 : 0) && diagnosticOK;
        NSString *text = failure || !diagnosticOK ? nil : fromJava(env, output);
        if (!failure) failure = exceptionText(env);
        if (!failure && !text) failure = @"Java facade returned a null response";
        LGRResult result = resultText(failure ?: text, failure ? 7 : 0);
        (*env)->PopLocalFrame(env, NULL);
        if (attached) {
            jint detached = (*vm)->DetachCurrentThread(vm);
            diagnosticOK = recordStage("thread.detached", detached) && diagnosticOK;
        }
        if (!diagnosticOK) { LGRFreeResult(result); return diagnosticFailureResult(); }
        return result;
    }
}
LGRResult LGRCreateSession(LGRString source) { return invoke(0, &source, 1); }
LGRResult LGRCreateSessionWithOptions(LGRString source, LGRString options) {
    LGRString args[] = {source, options}; return invoke(4, args, 2);
}
LGRResult LGRExecute(LGRString session, LGRString task, LGRString operation, LGRString request) {
    LGRString args[] = {session, task, operation, request}; return invoke(1, args, 4);
}
LGRResult LGRCancel(LGRString task) { return invoke(2, &task, 1); }
LGRResult LGRCloseSession(LGRString session) { return invoke(3, &session, 1); }
#else
int32_t LGRBridgeAvailable(void) { return 0; }
static LGRResult unavailable(void) { return resultText(@"OpenJDK Mobile payload is absent. Build and validate the pinned Zero XCFramework on macOS first.", 1); }
LGRResult LGRStart(LGRString cp, LGRString home, int32_t heap, LGRHostCallback callback, void *context) { (void)cp; (void)home; (void)heap; (void)callback; (void)context; return unavailable(); }
LGRResult LGRCreateSession(LGRString source) { (void)source; return unavailable(); }
LGRResult LGRCreateSessionWithOptions(LGRString source, LGRString options) { (void)source; (void)options; return unavailable(); }
LGRResult LGRExecute(LGRString session, LGRString task, LGRString op, LGRString request) { (void)session; (void)task; (void)op; (void)request; return unavailable(); }
LGRResult LGRCancel(LGRString task) { (void)task; return unavailable(); }
LGRResult LGRCloseSession(LGRString session) { (void)session; return unavailable(); }
#endif
