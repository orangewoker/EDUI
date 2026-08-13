import Flutter
import Security
import UIKit
import UniformTypeIdentifiers
import WidgetKit

// These Security task APIs exist on iOS but are not exposed by the public
// Swift module in every Xcode SDK. Bind their stable C symbols explicitly.
private typealias EDUISecTask = OpaquePointer

@_silgen_name("SecTaskCreateFromSelf")
private func eduiSecTaskCreateFromSelf(_ allocator: CFAllocator?) -> EDUISecTask?

@_silgen_name("SecTaskCopyValueForEntitlement")
private func eduiSecTaskCopyValueForEntitlement(
  _ task: EDUISecTask,
  _ entitlement: CFString,
  _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> CFTypeRef?

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let baseAppGroup = "group.com.orangewoker.edui"
  private var backupResult: FlutterResult?
  private var backupFileURL: URL?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EDUIAppGroupResolver")
    let channel = FlutterMethodChannel(
      name: "edui/app_group",
      binaryMessenger: registrar!.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "resolve":
        result(self?.resolvedAppGroup() ?? self?.baseAppGroup)
      case "sync":
        self?.syncWidgetData(call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let backupRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "EDUIICloudBackup"
    )
    let backupChannel = FlutterMethodChannel(
      name: "edui/icloud_backup",
      binaryMessenger: backupRegistrar!.messenger()
    )
    backupChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleBackupCall(call, result: result)
    }
  }

  private func handleBackupCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard backupResult == nil else {
      result(FlutterError(code: "busy", message: "另一个文件操作仍在进行", details: nil))
      return
    }
    switch call.method {
    case "export":
      guard
        let arguments = call.arguments as? [String: Any],
        let contents = arguments["contents"] as? String,
        let filename = arguments["filename"] as? String
      else {
        result(FlutterError(code: "invalid_arguments", message: "备份参数无效", details: nil))
        return
      }
      do {
        let safeName = filename.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        backupResult = result
        backupFileURL = url
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        guard let presenter = topViewController() else {
          backupResult = nil
          backupFileURL = nil
          try? FileManager.default.removeItem(at: url)
          result(FlutterError(code: "unavailable", message: "当前无法打开文件选择器", details: nil))
          return
        }
        presenter.present(picker, animated: true)
      } catch {
        result(FlutterError(code: "export_failed", message: "无法创建备份文件", details: error.localizedDescription))
      }
    case "import":
      backupResult = result
      let type = UTType.json
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type], asCopy: true)
      picker.delegate = self
      picker.allowsMultipleSelection = false
      picker.modalPresentationStyle = .formSheet
      guard let presenter = topViewController() else {
        backupResult = nil
        result(FlutterError(code: "unavailable", message: "当前无法打开文件选择器", details: nil))
        return
      }
      presenter.present(picker, animated: true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var controller = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  private func finishBackup(_ value: Any?) {
    let result = backupResult
    backupResult = nil
    if let url = backupFileURL {
      try? FileManager.default.removeItem(at: url)
      backupFileURL = nil
    }
    result?(value)
  }

  private func resolvedAppGroup() -> String {
    writableAppGroups().first ?? baseAppGroup
  }

  private func syncWidgetData(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = call.arguments as? [String: Any],
      let accounts = arguments["accounts"] as? String,
      let payload = arguments["payload"] as? String
    else {
      result(FlutterError(
        code: "invalid_widget_data",
        message: "小组件同步参数无效",
        details: nil
      ))
      return
    }

    let groups = writableAppGroups()
    var writtenGroups: [String] = []
    for group in groups {
      guard writeWidgetData(accounts: accounts, payload: payload, to: group) else {
        continue
      }
      writtenGroups.append(group)
    }
    guard !writtenGroups.isEmpty else {
      result(FlutterError(
        code: "app_group_unavailable",
        message: "签名没有为 EDUI 主程序提供可写的 App Group",
        details: ["candidates": appGroupCandidates()]
      ))
      return
    }
    WidgetCenter.shared.reloadTimelines(ofKind: "EDUIWidget")
    result(["groups": writtenGroups, "count": writtenGroups.count])
  }

  private func writeWidgetData(
    accounts: String,
    payload: String,
    to group: String
  ) -> Bool {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: group
    ) else {
      return false
    }

    let defaults = UserDefaults(suiteName: group)
    defaults?.set(accounts, forKey: "quota_accounts")
    defaults?.set(payload, forKey: "quota_payload")
    defaults?.set(Date().timeIntervalSince1970, forKey: "quota_synced_at")
    defaults?.synchronize()

    do {
      let envelope: [String: Any] = [
        "quota_accounts": accounts,
        "quota_payload": payload,
        "quota_synced_at": Date().timeIntervalSince1970,
      ]
      let data = try JSONSerialization.data(withJSONObject: envelope)
      try data.write(
        to: container.appendingPathComponent("edui-widget-data.json"),
        options: .atomic
      )
      return defaults?.string(forKey: "quota_accounts") == accounts
    } catch {
      return defaults?.string(forKey: "quota_accounts") == accounts
    }
  }

  private func writableAppGroups() -> [String] {
    appGroupCandidates().filter {
      FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: $0
      ) != nil
    }
  }

  private func appGroupCandidates() -> [String] {
    uniqueStrings(
      signedApplicationGroups() + alternateAppGroups() + [baseAppGroup]
    )
  }

  /// Reads the entitlement that is actually active after sideload re-signing.
  /// QuanNengSign and AltStore-family tools can rewrite App Groups without
  /// adding ALTAppGroups to Info.plist, so the signed value is authoritative.
  private func signedApplicationGroups() -> [String] {
    guard
      let task = eduiSecTaskCreateFromSelf(nil),
      let value = eduiSecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.application-groups" as CFString,
        nil
      )
    else {
      return []
    }
    return strings(from: value)
  }

  private func alternateAppGroups() -> [String] {
    let value = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups")
    if let groups = value as? [String: String] {
      return uniqueStrings(Array(groups.values) + Array(groups.keys))
    }
    return strings(from: value)
  }

  private func strings(from value: Any?) -> [String] {
    if let group = value as? String { return [group] }
    if let groups = value as? [String] { return groups }
    if let groups = value as? NSArray {
      return groups.compactMap { $0 as? String }
    }
    return []
  }

  private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}

extension AppDelegate: UIDocumentPickerDelegate {
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishBackup(nil)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let source = urls.first else {
      finishBackup(nil)
      return
    }
    if backupFileURL != nil {
      finishBackup(true)
      return
    }
    do {
      let data = try Data(contentsOf: source)
      guard data.count <= 5 * 1024 * 1024 else {
        finishBackup(FlutterError(code: "file_too_large", message: "备份文件不能超过 5 MB", details: nil))
        return
      }
      guard let contents = String(data: data, encoding: .utf8) else {
        finishBackup(FlutterError(code: "invalid_encoding", message: "备份文件不是 UTF-8 文本", details: nil))
        return
      }
      finishBackup(contents)
    } catch {
      finishBackup(FlutterError(code: "import_failed", message: "无法读取备份文件", details: error.localizedDescription))
    }
  }
}
