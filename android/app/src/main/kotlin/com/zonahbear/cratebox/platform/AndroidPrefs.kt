// core's Prefs on SharedPreferences ("cratebox", the same file the platform classes use), and the settings the
// app reads in more than one place (Settings in AppModel.swift on iOS).
package com.zonahbear.cratebox.platform

import android.content.Context
import com.zonahbear.cratebox.core.Prefs

class AndroidPrefs(context: Context) : Prefs {
    val sp = context.applicationContext.getSharedPreferences("cratebox", Context.MODE_PRIVATE)
    override fun bool(k: String, d: Boolean) = runCatching { sp.getBoolean(k, d) }.getOrDefault(d)
    // doubles are kept as their bits in a Long, so they round-trip exactly
    override fun double(k: String, d: Double) = runCatching { if (sp.contains(k)) java.lang.Double.longBitsToDouble(sp.getLong(k, 0)) else d }.getOrDefault(d)
    override fun string(k: String, d: String) = runCatching { sp.getString(k, d) ?: d }.getOrDefault(d)
    override fun set(k: String, v: Any?) {
        val e = sp.edit()
        when (v) {
            null -> e.remove(k)
            is Boolean -> e.putBoolean(k, v)
            is Double -> e.putLong(k, java.lang.Double.doubleToRawLongBits(v))
            is Float -> e.putLong(k, java.lang.Double.doubleToRawLongBits(v.toDouble()))
            is Int -> e.putLong(k, java.lang.Double.doubleToRawLongBits(v.toDouble()))
            is Long -> e.putLong(k, java.lang.Double.doubleToRawLongBits(v.toDouble()))
            else -> e.putString(k, v.toString())
        }
        e.apply()
    }

    /** where half/double-time tracks land */
    val bpmRange: Pair<Double, Double> get() = when (string("cb.bpmRange", "88-175")) {
        "58-115" -> 58.0 to 116.0
        "68-135" -> 68.0 to 136.0
        "78-155" -> 78.0 to 156.0
        else -> 88.0 to 176.0
    }
}
