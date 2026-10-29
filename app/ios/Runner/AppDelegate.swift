import EventKit
import Flutter
import QuickLook
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private var scopedFolder: URL?
  private var previewItem: URL?
  private let events = EKEventStore()

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DatovkaFolder")
    else { return }
    let channel = FlutterMethodChannel(
      name: "cz.datovka/folder",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "resolve":
        result(self.resolveBookmark())
      case "store":
        let path = call.arguments as? String ?? ""
        result(self.storeBookmark(path))
      case "documents":
        result(
          NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        )
      case "materialize":
        // Files in iCloud Drive may be only placeholders on the phone; ask
        // for all of them and wait, off the main thread.
        let path = call.arguments as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
          let missing = self.materialize(path)
          DispatchQueue.main.async { result(missing) }
        }
      case "preview":
        // Attachments and calendar files open in Quick Look; its share
        // button saves them or hands them to another app.
        let path = call.arguments as? String ?? ""
        result(self.preview(path))
      case "calendar":
        let list = call.arguments as? [[String: Any]] ?? []
        self.addToCalendar(list) { added in result(added) }
      case "open":
        if let raw = call.arguments as? String, let url = URL(string: raw) {
          UIApplication.shared.open(url)
          result(true)
        } else {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func preview(_ path: String) -> Bool {
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return false }
    var top = window?.rootViewController
    while let shown = top?.presentedViewController { top = shown }
    guard let top else { return false }
    previewItem = URL(fileURLWithPath: path)
    let ql = QLPreviewController()
    ql.dataSource = self
    top.present(ql, animated: true)
    return true
  }

  /// Writes the events straight into the default calendar. Asks only for
  /// permission to add, not to read. Calls back with how many were added, or
  /// -1 when the permission was refused.
  private func addToCalendar(_ list: [[String: Any]], done: @escaping (Int) -> Void) {
    let save: (Bool, Error?) -> Void = { granted, _ in
      DispatchQueue.main.async {
        guard granted, let calendar = self.events.defaultCalendarForNewEvents else {
          done(-1)
          return
        }
        var added = 0
        for item in list {
          let e = EKEvent(eventStore: self.events)
          e.calendar = calendar
          e.title = item["title"] as? String ?? ""
          e.startDate = Date(timeIntervalSince1970: (item["start"] as? Double ?? 0) / 1000)
          e.endDate = Date(timeIntervalSince1970: (item["end"] as? Double ?? 0) / 1000)
          e.isAllDay = item["allDay"] as? Bool ?? false
          if let place = item["location"] as? String, !place.isEmpty { e.location = place }
          e.notes = item["notes"] as? String
          if item["alarm"] as? Bool ?? false {
            e.addAlarm(EKAlarm(relativeOffset: -86400))
          }
          if (try? self.events.save(e, span: .thisEvent)) != nil { added += 1 }
        }
        done(added)
      }
    }
    if #available(iOS 17.0, *) {
      events.requestWriteOnlyAccessToEvents(completion: save)
    } else {
      events.requestAccess(to: .event, completion: save)
    }
  }

  /// Downloads every file of the archive folder from iCloud Drive and waits
  /// up to two minutes. Returns how many files are still not on the phone.
  private func materialize(_ path: String) -> Int {
    guard !path.isEmpty else { return 0 }
    let dir = URL(fileURLWithPath: path)
    // Keep the access open: the app reads the archive right after this.
    if dir.startAccessingSecurityScopedResource() {
      scopedFolder = dir
    }
    let fm = FileManager.default
    let key = URLResourceKey.ubiquitousItemDownloadingStatusKey
    func status(_ url: URL) -> URLUbiquitousItemDownloadingStatus? {
      // A fresh URL, so the answer is not a cached one.
      try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [key])
        .ubiquitousItemDownloadingStatus
    }
    var pending: [URL] = []
    let items = (try? fm.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [key], options: [])) ?? []
    for item in items {
      let name = item.lastPathComponent
      var target = item
      // A placeholder of "x.db" is ".x.db.icloud".
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        let real = String(name.dropFirst().dropLast(".icloud".count))
        target = dir.appendingPathComponent(real)
      }
      let s = status(target)
      if name.hasSuffix(".icloud") || (s != nil && s != .current) {
        try? fm.startDownloadingUbiquitousItem(at: target)
        pending.append(target)
      }
    }
    let deadline = Date().addingTimeInterval(120)
    while !pending.isEmpty && Date() < deadline {
      pending.removeAll { url in
        let s = status(url)
        return s == .current || (s == nil && fm.fileExists(atPath: url.path))
      }
      if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.5) }
    }
    return pending.count
  }

  /// Remembers the folder from the document picker so the next launch can
  /// open it the way a computer opens ~/.dsgui.
  private func storeBookmark(_ path: String) -> Bool {
    guard !path.isEmpty else { return false }
    let url = URL(fileURLWithPath: path)
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing { url.stopAccessingSecurityScopedResource() }
    }
    guard
      let data = try? url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    else { return false }
    UserDefaults.standard.set(data, forKey: "datovkaDataBookmark")
    return true
  }

  private func resolveBookmark() -> String? {
    guard let data = UserDefaults.standard.data(forKey: "datovkaDataBookmark") else {
      return nil
    }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
    else { return nil }
    _ = url.startAccessingSecurityScopedResource()
    scopedFolder = url
    if stale,
      let fresh = try? url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    {
      UserDefaults.standard.set(fresh, forKey: "datovkaDataBookmark")
    }
    return url.path
  }
}

extension AppDelegate: QLPreviewControllerDataSource {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewItem == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    previewItem! as NSURL
  }
}
