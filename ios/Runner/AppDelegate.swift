import Flutter
import UIKit
import UniformTypeIdentifiers

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
      guard call.method == "resolve" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.resolvedAppGroup() ?? self?.baseAppGroup)
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
    let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
    return groups?.first(where: { $0.contains(baseAppGroup) }) ?? baseAppGroup
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
