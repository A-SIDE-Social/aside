import Flutter
import UIKit
import AVFoundation
import FirebaseCore
import FirebaseMessaging
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()

    GeneratedPluginRegistrant.register(with: self)

    // Register contacts handler (lightweight platform channel for phone numbers)
    ContactsHandler.register(with: self.registrar(forPlugin: "ContactsHandler")!)

    // Register speech recognition handler (on-device SpeechAnalyzer, iOS 26+)
    SpeechPlugin.register(with: self.registrar(forPlugin: "SpeechPlugin")!)

    // Register screenshot detector — UIApplication.userDidTake
    // ScreenshotNotification fires after a foreground screenshot.
    // The Dart side (lib/core/platform/screenshot_service.dart)
    // surfaces this as a stream that the app root subscribes to.
    ScreenshotPlugin.register(with: self.registrar(forPlugin: "ScreenshotPlugin")!)

    // Register widget bridge (token sharing with widget + share extensions)
    if let registrar = self.registrar(forPlugin: "WidgetBridgeHandler") {
      WidgetBridgeHandler.register(with: registrar)
    }

    // Default flash to off
    if let device = AVCaptureDevice.default(for: .video), device.hasFlash {
      try? device.lockForConfiguration()
      device.flashMode = .off
      device.torchMode = .off
      device.unlockForConfiguration()
    }

    // Clear badge on launch
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0)
    }
    application.applicationIconBadgeNumber = 0

    // Register for remote notifications
    application.registerForRemoteNotifications()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    // Clear badge when app is opened — setBadgeCount is the modern API
    // (applicationIconBadgeNumber is deprecated in iOS 16+)
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0)
    }
    application.applicationIconBadgeNumber = 0
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
  }

  // Forward APNs token to Firebase Messaging for push notifications
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  // Handle remote notifications + widget updates
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    // Check if this is a new_post notification with an image to cache for the widget
    // FCM puts custom data fields directly in userInfo (not nested under "data")
    let type = userInfo["type"] as? String
    let imageUrl = userInfo["image_url"] as? String
    let posterName = userInfo["poster_name"] as? String
    if type == "new_post", let imageUrl = imageUrl, !imageUrl.isEmpty, let posterName = posterName {
      cacheWidgetImage(imageUrl: imageUrl, posterName: posterName) {
        completionHandler(.newData)
      }
      return
    }

    super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
  }

  // Foreground-push presentation. When a push arrives while the app
  // is already open we (a) zero the badge so the icon doesn't blip
  // up from the server's pre-resume count, and (b) forward to super
  // so the FCM SDK's onMessage stream still fires for the Dart side.
  //
  // Background pushes hit the OS notification center and bump the
  // badge as usual — that's the right behavior since the user isn't
  // actively in the app. This override only affects the active /
  // foreground case where the user clearly doesn't need a badge
  // ping for activity they're about to see anyway.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0)
    }
    super.userNotificationCenter(
      center,
      willPresent: notification,
      withCompletionHandler: completionHandler
    )
  }

  /// Download an image and cache it in the App Group container for the widget.
  private func cacheWidgetImage(imageUrl: String, posterName: String, completion: @escaping () -> Void) {
    guard let url = URL(string: imageUrl),
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.lab1908.instadamn") else {
      completion()
      return
    }

    URLSession.shared.dataTask(with: url) { data, response, error in
      defer { completion() }

      guard let data = data, error == nil,
            let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        return
      }

      // Write image
      let imageFile = container.appendingPathComponent("widget_image.jpg")
      try? data.write(to: imageFile)

      // Write metadata
      let meta: [String: String] = ["poster_name": posterName]
      if let metaData = try? JSONSerialization.data(withJSONObject: meta) {
        let metaFile = container.appendingPathComponent("widget_meta.json")
        try? metaData.write(to: metaFile)
      }

      // Tell WidgetKit to reload
      if #available(iOS 14.0, *) {
        WidgetKit.WidgetCenter.shared.reloadAllTimelines()
      }
    }.resume()
  }
}
