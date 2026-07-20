import BackgroundTasks
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var generationChannel: FlutterMethodChannel?
  private var generationBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private let continuedGenerationIdentifier = "com.example.havencat.generation"
  private var continuedGenerationTask: AnyObject?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 26.0, *) {
      BGTaskScheduler.shared.register(
        forTaskWithIdentifier: continuedGenerationIdentifier,
        using: nil
      ) { [weak self] task in
        guard
          let self,
          let continuedTask = task as? BGContinuedProcessingTask
        else { return }
        self.continuedGenerationTask = continuedTask
        continuedTask.progress.totalUnitCount = 100
        continuedTask.expirationHandler = { [weak self] in
          self?.generationChannel?.invokeMethod(
            "backgroundTimeExpired",
            arguments: nil
          )
          continuedTask.setTaskCompleted(success: false)
          self?.continuedGenerationTask = nil
        }
      }
    }
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
        if let error = self?.beginGenerationBackgroundTask() {
          result(error)
        } else {
          result(nil)
        }
      case "end":
        self?.endGenerationBackgroundTask()
        result(nil)
      case "progress":
        self?.reportGenerationProgress()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func beginGenerationBackgroundTask() -> FlutterError? {
    endGenerationBackgroundTask()
    if #available(iOS 26.0, *) {
      let request = BGContinuedProcessingTaskRequest(
        identifier: continuedGenerationIdentifier,
        title: "HavenCat is generating",
        subtitle: "Your response is being prepared"
      )
      request.strategy = .queue
      do {
        try BGTaskScheduler.shared.submit(request)
        return nil
      } catch {
        return FlutterError(
          code: "generation_background_submit_failed",
          message: "iOS rejected the continued generation task.",
          details: error.localizedDescription
        )
      }
    }
    generationBackgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "HavenCat generation"
    ) { [weak self] in
      guard let self else { return }
      self.generationChannel?.invokeMethod("backgroundTimeExpired", arguments: nil)
      self.endGenerationBackgroundTask()
    }
    if generationBackgroundTask == .invalid {
      return FlutterError(
        code: "generation_background_unavailable",
        message: "iOS did not grant background execution time.",
        details: nil
      )
    }
    return nil
  }

  private func endGenerationBackgroundTask() {
    if #available(iOS 26.0, *),
      let continuedTask = continuedGenerationTask as? BGContinuedProcessingTask
    {
      continuedTask.progress.completedUnitCount = continuedTask.progress.totalUnitCount
      continuedTask.setTaskCompleted(success: true)
      continuedGenerationTask = nil
    } else if #available(iOS 26.0, *) {
      BGTaskScheduler.shared.cancel(
        taskRequestWithIdentifier: continuedGenerationIdentifier
      )
    }
    guard generationBackgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(generationBackgroundTask)
    generationBackgroundTask = .invalid
  }

  private func reportGenerationProgress() {
    guard #available(iOS 26.0, *),
      let continuedTask = continuedGenerationTask as? BGContinuedProcessingTask
    else { return }
    continuedTask.progress.completedUnitCount = min(
      continuedTask.progress.completedUnitCount + 1,
      continuedTask.progress.totalUnitCount - 1
    )
  }
}
