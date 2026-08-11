import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let baseAppGroup = "group.com.orangewoker.edui"

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
  }

  private func resolvedAppGroup() -> String {
    let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
    return groups?.first(where: { $0.contains(baseAppGroup) }) ?? baseAppGroup
  }
}
