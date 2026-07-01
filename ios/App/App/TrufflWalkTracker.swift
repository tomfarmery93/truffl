import Foundation
import Capacitor
import CoreLocation

/**
 * TRU-56 (iOS): native background walk tracking — the iOS counterpart to the Android
 * WalkTrackingService / WalkTrackerPlugin.
 *
 * The web page's JS is suspended when the app is backgrounded or the screen is locked, so
 * persisting GPS pings from JS is unreliable. This plugin uses CoreLocation with background
 * location updates and POSTs each fix straight to Supabase (gps_pings) from native code, so
 * tracking continues off-screen until the walk is ended.
 *
 * Registered via CAPBridgedPlugin (Capacitor 8, Swift-only — no .m needed). The web calls
 * `Capacitor.Plugins.TrufflWalkTracker.start({...})` / `.stop()` (see walk/index.html); the
 * JS interface + filtering match the Android side so behaviour is identical across platforms.
 *
 * Requires (already in Info.plist): NSLocationWhenInUseUsageDescription,
 * NSLocationAlwaysAndWhenInUseUsageDescription, UIBackgroundModes → location.
 */
@objc(TrufflWalkTracker)
public class TrufflWalkTracker: CAPPlugin, CAPBridgedPlugin, CLLocationManagerDelegate {

    public let identifier = "TrufflWalkTracker"
    public let jsName = "TrufflWalkTracker"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]

    // Match the Android filters (WalkTrackingService): drop poor fixes + stationary GPS noise.
    private let maxAccuracyM: Double = 50
    private let minMoveM: Double = 8

    private var manager: CLLocationManager?
    private var supabaseUrl: String = ""
    private var anonKey: String = ""
    private var accessToken: String = ""
    private var walkSessionId: String = ""
    private var intervalMs: Double = 10000

    private var lastSent: Date?
    private var lastLocation: CLLocation?
    private var pendingStartCall: CAPPluginCall?

    // MARK: - Plugin methods

    @objc func start(_ call: CAPPluginCall) {
        guard let supabaseUrl = call.getString("supabaseUrl"),
              let anonKey = call.getString("anonKey"),
              let accessToken = call.getString("accessToken"),
              let walkSessionId = call.getString("walkSessionId") else {
            call.reject("Missing required tracking config (supabaseUrl, anonKey, accessToken, walkSessionId)")
            return
        }
        self.supabaseUrl = supabaseUrl
        self.anonKey = anonKey
        self.accessToken = accessToken
        self.walkSessionId = walkSessionId
        self.intervalMs = Double(call.getInt("intervalMs") ?? 10000)
        self.lastSent = nil
        self.lastLocation = nil

        // CLLocationManager must be created/used on a thread with an active run loop.
        DispatchQueue.main.async {
            let mgr = CLLocationManager()
            mgr.delegate = self
            mgr.desiredAccuracy = kCLLocationAccuracyBest
            mgr.activityType = .fitness
            mgr.pausesLocationUpdatesAutomatically = false
            mgr.distanceFilter = kCLDistanceFilterNone // we apply our own movement filter
            self.manager = mgr

            let status = mgr.authorizationStatus
            switch status {
            case .notDetermined:
                // Resume in didChangeAuthorization once the user responds.
                self.pendingStartCall = call
                mgr.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                self.beginUpdates(mgr)
                call.resolve()
            default:
                self.manager = nil
                call.reject("Location permission denied")
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.manager?.stopUpdatingLocation()
            self.manager?.allowsBackgroundLocationUpdates = false
            self.manager?.delegate = nil
            self.manager = nil
            call.resolve()
        }
    }

    // MARK: - Location

    private func beginUpdates(_ mgr: CLLocationManager) {
        // Safe to enable only with UIBackgroundModes → location present (it is).
        mgr.allowsBackgroundLocationUpdates = true
        mgr.showsBackgroundLocationIndicator = true
        mgr.startUpdatingLocation()
    }

    public func locationManagerDidChangeAuthorization(_ mgr: CLLocationManager) {
        guard let call = pendingStartCall else { return }
        switch mgr.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            pendingStartCall = nil
            beginUpdates(mgr)
            call.resolve()
        case .denied, .restricted:
            pendingStartCall = nil
            self.manager = nil
            call.reject("Location permission denied")
        default:
            break // still .notDetermined — wait for the user's choice
        }
    }

    public func locationManager(_ mgr: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // Poor accuracy (negative accuracy = invalid fix).
        if loc.horizontalAccuracy < 0 || loc.horizontalAccuracy > maxAccuracyM { return }

        let now = Date()
        if let last = lastLocation, let sent = lastSent {
            if now.timeIntervalSince(sent) * 1000 < intervalMs { return }   // time throttle
            if loc.distance(from: last) < minMoveM { return }               // stationary filter
        }

        lastSent = now
        lastLocation = loc
        postPing(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy)
    }

    public func locationManager(_ mgr: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal — keep the session alive; a later fix will succeed.
        CAPLog.print("TrufflWalkTracker location error: \(error.localizedDescription)")
    }

    // MARK: - Upload

    private func postPing(lat: Double, lng: Double, accuracy: Double) {
        guard let url = URL(string: supabaseUrl + "/rest/v1/gps_pings") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.timeoutInterval = 15

        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let body: [String: Any] = [
            "walk_session_id": walkSessionId,
            "lat": lat,
            "lng": lng,
            "accuracy_metres": Int(accuracy.rounded()),
            "recorded_at": iso.string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        req.httpBody = data

        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error = error {
                CAPLog.print("TrufflWalkTracker ping failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                CAPLog.print("TrufflWalkTracker ping HTTP \(http.statusCode)")
            }
        }.resume()
    }
}
