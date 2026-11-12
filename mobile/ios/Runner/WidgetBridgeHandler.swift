import Foundation
import Flutter
import WidgetKit

class WidgetBridgeHandler: NSObject, FlutterPlugin {

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.lab1908.instadamn/app_group", binaryMessenger: registrar.messenger())
        let instance = WidgetBridgeHandler()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private static let appGroupId = "group.com.lab1908.instadamn"

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setToken":
            if let token = call.arguments as? String {
                Self.writeToContainer(key: "auth_token", value: token)
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "token required", details: nil))
            }

        case "setApiBaseUrl":
            if let url = call.arguments as? String {
                Self.writeToContainer(key: "api_base_url", value: url)
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "url required", details: nil))
            }

        case "setUserId":
            if let userId = call.arguments as? String {
                Self.writeToContainer(key: "user_id", value: userId)
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "userId required", details: nil))
            }

        case "getUserId":
            result(Self.readFromContainer(key: "user_id"))

        case "clearToken":
            Self.writeToContainer(key: "auth_token", value: "")
            Self.writeToContainer(key: "user_id", value: "")
            if let store = Self.store {
                try? FileManager.default.removeItem(at: store.container.appendingPathComponent("widget_session.json"))
                store.clearWidgetData()
            }
            reloadWidgets()
            result(true)

        case "setWidgetSession":
            guard let args = call.arguments as? [String: String],
                  let session = WidgetSession(userId: args["userId"], token: args["token"], baseURL: args["baseURL"]),
                  Self.readFromContainer(key: "user_id") == session.userId,
                  let store = Self.store else { result(false); return }
            if store.session?.userId != session.userId { store.clearWidgetData() }
            do {
                try JSONEncoder().encode(session).write(to: store.container.appendingPathComponent("widget_session.json"), options: [.atomic, .completeFileProtection])
                reloadWidgets(); result(true)
            } catch { result(false) }

        case "syncWidgetSources":
            guard let args = call.arguments as? [String: Any],
                  let ownerId = args["ownerId"] as? String,
                  let store = Self.store, store.session?.userId == ownerId,
                  let data = try? JSONSerialization.data(withJSONObject: args),
                  let sources = try? JSONDecoder().decode(WidgetSources.self, from: data),
                  sources.sources.allSatisfy({ $0.isValid && $0.ownerId == ownerId }) else { result(false); return }
            do {
                try data.write(to: store.container.appendingPathComponent("widget_sources.json"), options: [.atomic, .completeFileProtection])
                reloadWidgets(); result(true)
            } catch { result(false) }

        case "reloadWidgets":
            reloadWidgets()
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static var store: WidgetStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId).map { WidgetStore(container: $0) }
    }

    private func reloadWidgets() {
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func writeToContainer(key: String, value: String) {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId) else { return }
        try? value.write(to: url.appendingPathComponent("\(key).txt"), atomically: true, encoding: .utf8)
    }

    static func readFromContainer(key: String) -> String? {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let fileUrl = url.appendingPathComponent("\(key).txt")
        guard let value = try? String(contentsOf: fileUrl, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }
}
