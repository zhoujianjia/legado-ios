#ifndef LEGADO_JNI_H
#define LEGADO_JNI_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// Standard UTF-8 with an explicit byte length, never JNI's modified UTF-8.
typedef struct { const uint8_t *bytes; size_t count; } LGRString;
typedef struct { uint8_t *bytes; size_t count; int32_t code; } LGRResult;
typedef LGRResult (*LGRHostCallback)(void *context, LGRString task, LGRString operation, LGRString request);

int32_t LGRBridgeAvailable(void);
LGRResult LGRMakeResult(const uint8_t *bytes, size_t count, int32_t code);
void LGRFreeResult(LGRResult result);
// Configures a process-scoped, app-owned diagnostics root. No files are created
// until LGRStart attempts JVM startup on its worker thread.
LGRResult LGRSetDiagnosticsDirectory(LGRString directory);
LGRResult LGRStart(LGRString classPath, LGRString javaHome, int32_t maximumHeapMB,
                   LGRHostCallback callback, void *context);
LGRResult LGRCreateSession(LGRString sourceJSON);
LGRResult LGRExecute(LGRString sessionID, LGRString taskID, LGRString operation, LGRString requestJSON);
LGRResult LGRCancel(LGRString taskID);
LGRResult LGRCloseSession(LGRString sessionID);
#ifdef __cplusplus
}
#endif
#endif
