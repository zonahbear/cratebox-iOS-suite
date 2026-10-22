// The main thread as a coroutine dispatcher (what kotlinx-coroutines-android's Dispatchers.Main is, without
// pulling it into platform/). HEAT and the USB session run their awaits here, like the main actor on iOS.
package com.zonahbear.cratebox.platform

import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlin.coroutines.CoroutineContext

object Main : CoroutineDispatcher() {
    private val h = Handler(Looper.getMainLooper())
    override fun isDispatchNeeded(context: CoroutineContext) = Looper.myLooper() != Looper.getMainLooper()
    override fun dispatch(context: CoroutineContext, block: Runnable) { h.post(block) }
    fun scope() = CoroutineScope(SupervisorJob() + this)
}
