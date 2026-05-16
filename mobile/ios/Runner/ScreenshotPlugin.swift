import Flutter
import UIKit

/// Subscribes to UIApplication.userDidTakeScreenshotNotification and
/// emits an event over an EventChannel each time. UIKit posts that
/// notification AFTER the OS captures a screenshot while the app is
/// foreground — we can't intercept beforehand and we can't block the
/// screenshot itself; the goal is gentle awareness, not enforcement.
///
/// The Flutter side (lib/core/platform/screenshot_service.dart)
/// listens and shows a slide-up overlay banner with privacy copy.
class ScreenshotPlugin: NSObject, FlutterPlugin {
    private var eventSink: FlutterEventSink?

    static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.lab1908.instadamn/screenshot",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.lab1908.instadamn/screenshot_events",
            binaryMessenger: registrar.messenger()
        )
        let instance = ScreenshotPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)

        // Subscribe immediately at registration time so we don't miss
        // a screenshot taken before the Dart side first listens.
        // (NSNotificationCenter dispatches synchronously on the
        // posting thread, so we capture without race.)
        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(instance.onScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // No method calls today — the plugin is event-only. Reserve
        // for v2 in case we want a "did you screenshot" debug ping.
        result(FlutterMethodNotImplemented)
    }

    @objc private func onScreenshot(_ notification: Notification) {
        // The notification carries no useful payload; the event itself
        // is the signal. Send `{}` for a future-proof shape so we can
        // add fields later without changing the channel contract.
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?([:])
        }
    }
}

extension ScreenshotPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
