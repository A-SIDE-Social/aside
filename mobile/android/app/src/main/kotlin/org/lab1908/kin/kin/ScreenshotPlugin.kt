package org.lab1908.kin.kin

import android.app.Activity
import android.os.Build
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Screenshot detector — Android 14+ (API 34) implementation.
 *
 * Uses [Activity.registerScreenCaptureCallback], the public API
 * Google added in Android 14 specifically for "the user just
 * screenshotted my app" detection. Requires the
 * `android.permission.DETECT_SCREEN_CAPTURE` permission (declared
 * in AndroidManifest.xml). The permission is a normal permission —
 * granted at install time, no runtime prompt.
 *
 * Pre-API 34 devices: callback registration is gated on the SDK
 * version check below, so older phones simply receive zero events.
 * The user accepted this trade-off explicitly: "if this misses some
 * android devices that is fine." Android 14+ adoption is large
 * enough that this covers the meaningful majority while avoiding
 * the alternative — a MediaStore ContentObserver requiring
 * READ_EXTERNAL_STORAGE, which is intrusive overkill for screenshot
 * detection alone.
 *
 * Lifecycle: registers the callback when the Activity attaches and
 * unregisters when it detaches — including across config changes
 * (rotation), so we don't leak a callback past the Activity's life.
 */
class ScreenshotPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private var activity: Activity? = null

    /// Holder for the Activity.ScreenCaptureCallback. Typed `Any?` so
    /// the class symbol Activity.ScreenCaptureCallback is NEVER
    /// referenced at class-load time — only inside @RequiresApi(34)
    /// methods that are themselves only called from sites guarded by
    /// `Build.VERSION.SDK_INT >= 34`.
    ///
    /// Why this matters: a `private val callback = Activity.Screen
    /// CaptureCallback { ... }` field gets initialized in the class's
    /// <init>, whose bytecode references the callback class. On
    /// Android < 14 that class doesn't exist → NoClassDefFoundError on
    /// plugin instantiation → MainActivity.configureFlutterEngine()
    /// fails → app never launches. The `@RequiresApi` annotation is a
    /// lint hint, NOT a runtime gate. Confirmed in the wild on a Gaza
    /// user's pre-API-34 phone with the entire app failing to start.
    private var screenCaptureCallback: Any? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "com.lab1908.instadamn/screenshot")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "com.lab1908.instadamn/screenshot_events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        result.notImplemented()
    }

    // ---- ActivityAware ------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        registerCallbackIfSupported()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        unregisterCallbackIfSupported()
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        registerCallbackIfSupported()
    }

    override fun onDetachedFromActivity() {
        unregisterCallbackIfSupported()
        activity = null
    }

    private fun registerCallbackIfSupported() {
        if (Build.VERSION.SDK_INT < 34) return
        registerCallback34()
    }

    private fun unregisterCallbackIfSupported() {
        if (Build.VERSION.SDK_INT < 34) return
        unregisterCallback34()
    }

    /// Splitting register/unregister into @RequiresApi(34) methods
    /// keeps every Activity.ScreenCaptureCallback symbol reference
    /// confined to bytecode the JVM only verifies after the SDK_INT
    /// gate above has decided we're on API 34+. On older devices,
    /// these methods' bytecode is never linked, so the missing class
    /// can't trigger a NoClassDefFoundError.

    @RequiresApi(34)
    private fun registerCallback34() {
        val a = activity ?: return
        try {
            val cb = Activity.ScreenCaptureCallback {
                // Fires on the main thread per Android docs. Push event
                // over the EventChannel — Dart-side ScreenshotService
                // surfaces it as a Stream<void>. Empty map keeps the
                // channel contract forward-compatible.
                eventSink?.success(emptyMap<String, Any>())
            }
            screenCaptureCallback = cb
            a.registerScreenCaptureCallback(a.mainExecutor, cb)
        } catch (e: Throwable) {
            // Defensive: some OEMs may not honor the API even on
            // API 34+. Swallow rather than crash.
            android.util.Log.w("ScreenshotPlugin", "register failed: $e")
        }
    }

    @RequiresApi(34)
    private fun unregisterCallback34() {
        val a = activity ?: return
        val cb = screenCaptureCallback as? Activity.ScreenCaptureCallback
            ?: return
        try {
            a.unregisterScreenCaptureCallback(cb)
        } catch (e: Throwable) {
            android.util.Log.w("ScreenshotPlugin", "unregister failed: $e")
        }
        screenCaptureCallback = null
    }

    // ---- StreamHandler ------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
