package io.yuedu.legado;

/** Registered by the embedding JNI bridge before any platform-dependent operation. */
public final class NativeHost {
    private NativeHost() {}
    public static native String dispatch(String taskId, String operation, String requestJson);
}
