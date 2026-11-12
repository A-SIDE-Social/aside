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

    // With UIScene, UIKit sends activation to FlutterSceneDelegate instead
    // of applicationDidBecomeActive. Observe the scene event so returning
    // from the Home Screen or a notification clears the delivered badge.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clearDeliveredNotifications),
      name: UIScene.didActivateNotification,
      object: nil
    )

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
    clearAppIconBadge()

    // Register for remote notifications
    application.registerForRemoteNotifications()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    clearDeliveredNotifications()
  }

  private func clearAppIconBadge() {
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0)
    } else {
      UIApplication.shared.applicationIconBadgeNumber = 0
    }
  }

  @objc private func clearDeliveredNotifications() {
    clearAppIconBadge()
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
    // A notification is a refresh hint, never authority to display its image.
    // Each widget fetches its own selection with the signed-in account's token.
    if userInfo["type"] as? String == "new_post" {
      WidgetKit.WidgetCenter.shared.reloadTimelines(ofKind: "KinWidget")
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
    clearAppIconBadge()
    if notification.request.content.userInfo["type"] as? String == "new_post" {
      WidgetKit.WidgetCenter.shared.reloadTimelines(ofKind: "KinWidget")
    }
    super.userNotificationCenter(
      center,
      willPresent: notification,
      withCompletionHandler: completionHandler
    )
  }

}
