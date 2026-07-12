import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var generationChannel: FlutterMethodChannel?
  private var generationBackgroundTask: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.example.havencat/generation_background",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    generationChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "begin":
        self?.beginGenerationBackgroundTask()
        result(nil)
      case "end":
        self?.endGenerationBackgroundTask()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func beginGenerationBackgroundTask() {
    endGenerationBackgroundTask()
    generationBackgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "HavenCat generation"
    ) { [weak self] in
      guard let self else { return }
      self.generationChannel?.invokeMethod("backgroundTimeExpired", arguments: nil)
      self.endGenerationBackgroundTask()
    }
  }

  private func endGenerationBackgroundTask() {
    guard generationBackgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(generationBackgroundTask)
    generationBackgroundTask = .invalid
  }
}
