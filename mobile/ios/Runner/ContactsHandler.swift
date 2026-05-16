import Flutter
import Contacts

/// Minimal MethodChannel handler for reading phone contacts.
/// Exposes permission request + phone number and email extraction — no UI, no photos.
class ContactsHandler: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.lab1908.instadamn/contacts",
      binaryMessenger: registrar.messenger()
    )
    let instance = ContactsHandler()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermission":
      requestPermission(result: result)
    case "getPhoneNumbers":
      getPhoneNumbers(result: result)
    case "getEmailAddresses":
      getEmailAddresses(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermission(result: @escaping FlutterResult) {
    let store = CNContactStore()
    let status = CNContactStore.authorizationStatus(for: .contacts)

    switch status {
    case .authorized:
      result(true)
    case .notDetermined:
      store.requestAccess(for: .contacts) { granted, _ in
        DispatchQueue.main.async {
          result(granted)
        }
      }
    default:
      result(false)
    }
  }

  private func getPhoneNumbers(result: @escaping FlutterResult) {
    let store = CNContactStore()
    let keys = [CNContactPhoneNumbersKey] as [CNKeyDescriptor]
    var phoneNumbers: [String] = []

    DispatchQueue.global(qos: .userInitiated).async {
      let request = CNContactFetchRequest(keysToFetch: keys)
      do {
        try store.enumerateContacts(with: request) { contact, _ in
          for phone in contact.phoneNumbers {
            let value = phone.value.stringValue
            if !value.isEmpty {
              phoneNumbers.append(value)
            }
          }
        }
        DispatchQueue.main.async {
          result(phoneNumbers)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "CONTACTS_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  private func getEmailAddresses(result: @escaping FlutterResult) {
    let store = CNContactStore()
    let keys = [CNContactEmailAddressesKey] as [CNKeyDescriptor]
    var emails: [String] = []

    DispatchQueue.global(qos: .userInitiated).async {
      let request = CNContactFetchRequest(keysToFetch: keys)
      do {
        try store.enumerateContacts(with: request) { contact, _ in
          for email in contact.emailAddresses {
            let value = email.value as String
            if !value.isEmpty {
              emails.append(value)
            }
          }
        }
        DispatchQueue.main.async {
          result(emails)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "CONTACTS_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }
}
