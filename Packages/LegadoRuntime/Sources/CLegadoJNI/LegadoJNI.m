#import <Foundation/Foundation.h>
#import "LegadoJNI.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
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
            BOOL same = facade && [configuredClassPath isEqual:cp] && [configuredJavaHome isEqual:home]
                && configuredHeap == maximumHeapMB && hostContext == context;
            pthread_mutex_unlock(&startupLock);
            return same ? resultText(@"{}", 0) : resultText(@"JVM is process scoped and cannot be restarted or reconfigured", 3);
        }
        startupAttempted = YES;
        configuredClassPath = [cp copy]; configuredJavaHome = [home copy]; configuredHeap = maximumHeapMB;
        hostCallback = callback; hostContext = context;
        NSString *cpOption = [@"-Djava.class.path=" stringByAppendingString:cp];
        NSString *homeOption = [@"-Djava.home=" stringByAppendingString:home];
        NSString *heapOption = [NSString stringWithFormat:@"-Xmx%dm", maximumHeapMB];
        JavaVMOption options[5] = {0};
        options[0].optionString = (char *)cpOption.UTF8String;
        options[1].optionString = (char *)homeOption.UTF8String;
        options[2].optionString = (char *)heapOption.UTF8String;
        options[3].optionString = "-Xint";
        options[4].optionString = "-Xshare:off";
        JavaVMInitArgs args = {0};
        args.version = JNI_VERSION_1_8; args.nOptions = 5; args.options = options; args.ignoreUnrecognized = JNI_FALSE;
        JNIEnv *env = NULL;
#if TARGET_OS_IPHONE
        loadfunctions();
#endif
        jint status = JNI_CreateJavaVM(&vm, (void **)&env, &args);
        NSString *failure = nil;
        if (status != JNI_OK || !env) failure = [NSString stringWithFormat:@"JNI_CreateJavaVM failed: %d", status];
        if (!failure) {
            jclass local = (*env)->FindClass(env, "io/yuedu/legado/LegadoRuntime");
            failure = exceptionText(env);
            if (!failure && local) {
                facade = (*env)->NewGlobalRef(env, local);
                (*env)->DeleteLocalRef(env, local);
                failure = exceptionText(env);
                if (!facade && !failure) failure = @"Cannot allocate JVM facade global reference";
                if (!failure) {
                    createMethod = (*env)->GetStaticMethodID(env, facade, "createSession", "(Ljava/lang/String;)Ljava/lang/String;");
                    failure = exceptionText(env);
                }
                if (!failure) {
                    executeMethod = (*env)->GetStaticMethodID(env, facade, "execute", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
                    failure = exceptionText(env);
                }
                if (!failure) cancelMethod = (*env)->GetStaticMethodID(env, facade, "cancel", "(Ljava/lang/String;)Ljava/lang/String;");
                if (!failure) failure = exceptionText(env);
                if (!failure) closeMethod = (*env)->GetStaticMethodID(env, facade, "closeSession", "(Ljava/lang/String;)Ljava/lang/String;");
                if (!failure) failure = exceptionText(env);
            } else if (!failure) failure = @"LegadoRuntime facade not found";
            if (!failure) {
                jclass nativeHost = (*env)->FindClass(env, "io/yuedu/legado/NativeHost");
                failure = exceptionText(env);
                if (!failure && nativeHost) {
                    JNINativeMethod method = { "dispatch", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", (void *)dispatchHost };
                    jint registered = (*env)->RegisterNatives(env, nativeHost, &method, 1);
                    failure = exceptionText(env);
                    if (!failure && registered != JNI_OK) failure = @"NativeHost registration failed";
                    (*env)->DeleteLocalRef(env, nativeHost);
                } else if (!failure) failure = @"NativeHost class not found";
            }
            if (failure && facade) { (*env)->DeleteGlobalRef(env, facade); facade = NULL; }
            (*vm)->DetachCurrentThread(vm);
        }
        pthread_mutex_unlock(&startupLock);
        return resultText(failure ?: @"{}", failure ? 4 : 0);
    }
}
// Each invocation gets its own JNIEnv and local frame. No JNIEnv crosses a Swift queue.
static LGRResult invoke(int method, LGRString *arguments, int count) {
    @autoreleasepool {
        pthread_mutex_lock(&startupLock);
        BOOL ready = facade != NULL;
        pthread_mutex_unlock(&startupLock);
        if (!ready) return resultText(@"JVM has not started successfully", 5);
        JNIEnv *env = NULL;
        jint status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8);
        BOOL attached = status == JNI_EDETACHED;
        if (attached) status = (*vm)->AttachCurrentThread(vm, (void **)&env, NULL);
        if (status != JNI_OK || !env) return resultText(@"Cannot attach worker thread to JVM", 6);
        if ((*env)->PushLocalFrame(env, 32) < 0) {
            exceptionText(env);
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
        jmethodID methods[] = {createMethod, executeMethod, cancelMethod, closeMethod};
        jstring output = failure ? NULL : (jstring)(*env)->CallStaticObjectMethodA(env, facade, methods[method], values);
        if (!failure) failure = exceptionText(env);
        NSString *text = failure ? nil : fromJava(env, output);
        if (!failure) failure = exceptionText(env);
        if (!failure && !text) failure = @"Java facade returned a null response";
        LGRResult result = resultText(failure ?: text, failure ? 7 : 0);
        (*env)->PopLocalFrame(env, NULL);
        if (attached) (*vm)->DetachCurrentThread(vm);
        return result;
    }
}
LGRResult LGRCreateSession(LGRString source) { return invoke(0, &source, 1); }
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
LGRResult LGRExecute(LGRString session, LGRString task, LGRString op, LGRString request) { (void)session; (void)task; (void)op; (void)request; return unavailable(); }
LGRResult LGRCancel(LGRString task) { (void)task; return unavailable(); }
LGRResult LGRCloseSession(LGRString session) { (void)session; return unavailable(); }
#endif
