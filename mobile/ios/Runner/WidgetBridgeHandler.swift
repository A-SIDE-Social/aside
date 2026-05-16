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
            reloadWidgets()
            result(true)

        case "cacheWidgetImage":
            guard let args = call.arguments as? [String: Any],
                  let imageUrl = args["imageUrl"] as? String,
                  let posterName = args["posterName"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "imageUrl and posterName required", details: nil))
                return
            }
            cacheWidgetImage(imageUrl: imageUrl, posterName: posterName, result: result)

        case "reloadWidgets":
            reloadWidgets()
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func cacheWidgetImage(imageUrl: String, posterName: String, result: @escaping FlutterResult) {
        guard let url = URL(string: imageUrl),
              let containerUrl = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupId) else {
            result(false)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, let original = UIImage(data: data) else {
                result(false)
                return
            }

            // Resize to max 400px for widget memory limits (~30MB)
            let maxDim: CGFloat = 400
            let size = original.size
            let scale = min(maxDim / size.width, maxDim / size.height, 1.0)
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let resized = renderer.jpegData(withCompressionQuality: 0.8) { ctx in
                original.draw(in: CGRect(origin: .zero, size: newSize))
            }

            let imageFile = containerUrl.appendingPathComponent("widget_image.jpg")
            let metaFile = containerUrl.appendingPathComponent("widget_meta.json")

            try? resized.write(to: imageFile)

            let meta: [String: String] = ["poster_name": posterName]
            if let metaData = try? JSONSerialization.data(withJSONObject: meta) {
                try? metaData.write(to: metaFile)
            }

            self.reloadWidgets()
            result(true)
        }.resume()
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
