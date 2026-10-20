package com.script.rhino

import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Optional integration hook evaluated by the existing Rhino instruction observer. */
internal class ScriptExecutionGuard(val checkActive: () -> Unit) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<ScriptExecutionGuard>
}
