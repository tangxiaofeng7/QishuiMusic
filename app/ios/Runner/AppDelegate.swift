import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerPlatformChannel()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// sodam/platform：openUrl / canOpenUrl / shareFile / deviceInfo
  /// （在线升级拉起 TrollStore 安装、运行日志导出、设置页运行环境展示）。
  private func registerPlatformChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "sodam/platform", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "canOpenUrl":
        guard let url = (call.arguments as? [String: Any])?["url"] as? String,
              let target = URL(string: url) else {
          result(FlutterError(code: "args", message: "url missing", details: nil))
          return
        }
        result(UIApplication.shared.canOpenURL(target))
      case "openUrl":
        guard let url = (call.arguments as? [String: Any])?["url"] as? String,
              let target = URL(string: url) else {
          result(FlutterError(code: "args", message: "url missing", details: nil))
          return
        }
        UIApplication.shared.open(target, options: [:]) { opened in
          result(opened)
        }
      case "shareFile":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "args", message: "path missing", details: nil))
          return
        }
        self?.presentShareSheet(path: path, result: result)
      case "deviceInfo":
        result(self?.collectDeviceInfo())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 设备运行环境（对齐 Beans-Music 崩溃日志的环境字段）：
  /// model = 通用型号名（iPhone/iPad），machine = utsname 芯片型号（iPhone17,1）。
  private func collectDeviceInfo() -> [String: String] {
    let device = UIDevice.current
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { text, element in
      guard let byte = element.value as? Int8, byte != 0 else { return }
      text.append(String(UnicodeScalar(UInt8(bitPattern: byte))))
    }
    #if targetEnvironment(simulator)
    let simulator = "true"
    #else
    let simulator = "false"
    #endif
    return [
      "os": device.systemName,
      "osVersion": device.systemVersion,
      "model": device.model,
      "machine": machine,
      "simulator": simulator,
    ]
  }

  private func presentShareSheet(path: String, result: @escaping FlutterResult) {
    guard let controller = window?.rootViewController else {
      result(false)
      return
    }
    let url = URL(fileURLWithPath: path)
    let picker = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    picker.popoverPresentationController?.sourceView = controller.view
    controller.present(picker, animated: true) {
      result(true)
    }
  }
}
