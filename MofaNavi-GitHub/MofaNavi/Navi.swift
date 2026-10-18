import SwiftUI
import MapKit
import CoreLocation
import AVFoundation

/// Gemeinsamer Zustand für iPhone-Oberfläche und CarPlay.
final class Navi: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Navi()

    @Published var results: [MKMapItem] = []
    @Published var destination: MKMapItem?
    @Published var route: MKRoute?
    @Published var violations: [Violation] = []
    @Published var checkNote: String?
    @Published var error: String?
    @Published var isChecking = false
    @Published var isGuiding = false
    @Published var currentStepIndex = 0
    @Published var distanceToManeuver: Double = 0
    @Published var location: CLLocation?

    private(set) var routeCoords: [CLLocationCoordinate2D] = []

    // München und Umgebung (Suche bis 50 km um den Marienplatz)
    let center = CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755)
    let maxDistanceFromMunich: CLLocationDistance = 50_000
    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
    }

    // Durchschnittstempo Moped (ca. 40 km/h bei erlaubten 45 km/h)
    private let avgSpeed: Double = 40.0 / 3.6

    private let locationManager = CLLocationManager()
    private let synth = AVSpeechSynthesizer()
    private var announcedNear = false
    private var lastReroute = Date.distantPast

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
           modes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
    }

    // MARK: Suche

    func searchItems(_ text: String) async -> [MKMapItem] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = text
        req.region = region
        guard let items = try? await MKLocalSearch(request: req).start().mapItems else { return [] }
        let c = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return items.filter {
            let p = $0.placemark.coordinate
            return CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: c) <= maxDistanceFromMunich
        }
    }

    func search(_ text: String) async {
        let items = await searchItems(text)
        await MainActor.run {
            results = items
            error = items.isEmpty ? "Nichts im Umkreis von 50 km um München gefunden." : nil
        }
    }

    // MARK: Routing

    @discardableResult
    func calculate(to item: MKMapItem) async -> MKRoute? {
        await MainActor.run {
            stopGuidance()
            isChecking = true
            error = nil
            checkNote = nil
            results = []
            route = nil
            violations = []
            destination = item
        }

        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        req.destination = item
        req.transportType = .automobile
        req.highwayPreference = .avoid
        req.tollPreference = .avoid
        req.requestsAlternateRoutes = true

        do {
            let routes = try await MKDirections(request: req).calculate().routes
            guard !routes.isEmpty else { throw URLError(.resourceUnavailable) }

            // Routen der Reihe nach prüfen, die erste ohne Verstoß gewinnt
            var checked: [(MKRoute, [Violation])] = []
            var offline = false
            for r in routes {
                do {
                    let v = try await LegalityChecker.check(route: r)
                    checked.append((r, v))
                    if v.isEmpty { break }
                } catch {
                    offline = true
                    break
                }
            }

            var note: String?
            let pick: (MKRoute, [Violation])
            if offline {
                pick = (routes[0], LegalityChecker.heuristic(route: routes[0]))
                note = "Online-Prüfung nicht möglich, nur grobe Prüfung der Straßennamen. Bitte Route selbst kontrollieren."
            } else {
                pick = checked.first(where: { $0.1.isEmpty }) ?? checked[0]
                if !pick.1.isEmpty {
                    note = "Keine komplett legale Route gefunden. Die rot markierten Stellen musst du umfahren."
                }
            }

            await MainActor.run {
                route = pick.0
                routeCoords = LegalityChecker.coordinates(of: pick.0)
                violations = pick.1
                checkNote = note
                isChecking = false
            }
            return pick.0
        } catch {
            await MainActor.run {
                self.error = "Keine Route gefunden."
                self.isChecking = false
            }
            return nil
        }
    }

    func etaMinutes(_ route: MKRoute) -> Int {
        Int((route.distance / avgSpeed / 60).rounded())
    }

    // MARK: Führung

    var currentInstruction: String? {
        guard let r = route, currentStepIndex < r.steps.count else { return nil }
        return r.steps[currentStepIndex].instructions
    }

    func startGuidance() {
        guard let route else { return }
        currentStepIndex = route.steps.firstIndex(where: { !$0.instructions.isEmpty }) ?? 0
        announcedNear = false
        isGuiding = true
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.startUpdatingLocation()
        if let ins = currentInstruction { speak(ins) }
    }

    func stopGuidance() {
        isGuiding = false
        locationManager.stopUpdatingLocation()
        synth.stopSpeaking(at: .immediate)
    }

    private func speak(_ text: String) {
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "de-DE")
        synth.speak(u)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        location = loc
        guard isGuiding, let route else { return }

        let steps = route.steps
        guard currentStepIndex < steps.count else { return }

        // Abstand zum nächsten Manöver
        let target = Geo.start(of: steps[currentStepIndex])
        let d = loc.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        distanceToManeuver = d

        if d < 150 && !announcedNear {
            announcedNear = true
            speak("In \(Int(d / 10) * 10) Metern: \(steps[currentStepIndex].instructions)")
        }
        if d < 30 {
            currentStepIndex += 1
            announcedNear = false
            if currentStepIndex >= steps.count {
                speak("Sie haben Ihr Ziel erreicht.")
                stopGuidance()
                return
            }
        }

        // Neuberechnung, wenn mehr als 80 m von der Route entfernt
        if Geo.distance(loc.coordinate, toPath: routeCoords) > 80,
           Date().timeIntervalSince(lastReroute) > 20,
           !isChecking,
           let dest = destination {
            lastReroute = Date()
            speak("Route wird neu berechnet.")
            Task {
                if await calculate(to: dest) != nil {
                    await MainActor.run { startGuidance() }
                }
            }
        }
    }
}
