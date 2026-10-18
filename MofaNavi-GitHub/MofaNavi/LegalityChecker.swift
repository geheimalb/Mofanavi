import Foundation
import MapKit
import CoreLocation

struct Violation: Identifiable {
    let id = UUID()
    let reason: String
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Geometrie

enum Geo {
    /// Koordinate in Meter relativ zu einem Ursprung (gut genug für kurze Distanzen)
    private static func meters(_ a: CLLocationCoordinate2D, from o: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((a.longitude - o.longitude) * 111_320 * cos(o.latitude * .pi / 180),
         (a.latitude - o.latitude) * 110_540)
    }

    static func distance(_ p: CLLocationCoordinate2D,
                         toSegment a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> Double {
        let A = meters(a, from: p)
        let B = meters(b, from: p)
        let dx = B.x - A.x, dy = B.y - A.y
        let len2 = dx * dx + dy * dy
        var t = len2 == 0 ? 0 : (-A.x * dx - A.y * dy) / len2
        t = max(0, min(1, t))
        let cx = A.x + t * dx, cy = A.y + t * dy
        return (cx * cx + cy * cy).squareRoot()
    }

    static func distance(_ p: CLLocationCoordinate2D, toPath path: [CLLocationCoordinate2D]) -> Double {
        guard let first = path.first else { return .infinity }
        if path.count == 1 { return distance(p, toSegment: first, first) }
        var best = Double.infinity
        for i in 0..<(path.count - 1) {
            best = min(best, distance(p, toSegment: path[i], path[i + 1]))
        }
        return best
    }

    static func start(of step: MKRoute.Step) -> CLLocationCoordinate2D {
        let pl = step.polyline
        guard pl.pointCount > 0 else { return pl.coordinate }
        return pl.points()[0].coordinate
    }
}

// MARK: - Legalitäts-Check

enum LegalityChecker {
    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private static let tolerance = 7.0   // Meter Abstand zur Straße
    private static let minRun = 5        // 5 Punkte à 10 m = ca. 50 m, damit Brücken/Unterführungen nicht zählen

    private struct Response: Decodable { let elements: [Way] }
    private struct Way: Decodable {
        let id: Int
        let tags: [String: String]?
        let geometry: [Pt]?
    }
    private struct Pt: Decodable {
        let lat: Double
        let lon: Double
        var coord: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    }

    /// Prüft die Route online gegen OpenStreetMap. Wirft einen Fehler, wenn der Dienst nicht erreichbar ist.
    static func check(route: MKRoute) async throws -> [Violation] {
        let dense = densify(coordinates(of: route), spacing: 10)
        guard dense.count > 1 else { return [] }

        let step = 12                                   // alle ca. 120 m ein Stützpunkt für die Abfrage
        let sampleIdx = Array(stride(from: 0, to: dense.count, by: step))
        var result: [Violation] = []
        var seen = Set<Int>()

        for group in sampleIdx.chunked(into: 50) {      // ca. 6 km pro Abfrage
            let start = group.first!
            let end = min(group.last! + step, dense.count - 1)
            var pts = group.map { dense[$0] }
            pts.append(dense[end])

            let ways = try await fetchForbiddenWays(along: pts)
            let slice = Array(dense[start...end])

            for w in ways where !seen.contains(w.id) {
                guard let geo = w.geometry?.map(\.coord), geo.count > 1 else { continue }
                if let hit = firstSustainedHit(slice, path: geo) {
                    seen.insert(w.id)
                    result.append(Violation(reason: describe(w.tags ?? [:]), coordinate: hit))
                }
            }
        }
        return result
    }

    /// Grobe Notlösung ohne Internet: Namen der Anweisungen prüfen
    static func heuristic(route: MKRoute) -> [Violation] {
        let pattern = "(?i)autobahn|schnellstra|kraftfahrstra|\\bA ?\\d{1,3}\\b"
        return route.steps
            .filter { $0.instructions.range(of: pattern, options: .regularExpression) != nil }
            .map { Violation(reason: $0.instructions, coordinate: Geo.start(of: $0)) }
    }

    // MARK: Overpass

    private static func fetchForbiddenWays(along pts: [CLLocationCoordinate2D]) async throws -> [Way] {
        let line = pts.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let query = """
        [out:json][timeout:25];
        way(around:20,\(line))["highway"]->.near;
        (
          way.near["highway"~"^(motorway|motorway_link)$"];
          way.near["motorroad"="yes"];
          way.near["moped"="no"];
          way.near["motor_vehicle"="no"];
          way.near["vehicle"="no"];
          way.near["access"="no"];
        );
        out tags geom;
        """
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("MofaNavi/1.0", forHTTPHeaderField: "User-Agent")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        req.httpBody = "data=\(encoded)".data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.elements.filter { isForbidden($0.tags ?? [:]) }
    }

    /// Regeln für Mofa/Moped (Klasse AM): keine Autobahn, keine Kraftfahrstraße, keine für Kfz gesperrten Wege
    private static func isForbidden(_ t: [String: String]) -> Bool {
        let allowed: Set<String> = ["yes", "designated", "permissive"]
        if let m = t["moped"] {
            if allowed.contains(m) { return false }
            if m == "no" { return true }
        }
        if t["highway"] == "motorway" || t["highway"] == "motorway_link" { return true }
        if t["motorroad"] == "yes" { return true }
        if let mv = t["motor_vehicle"], allowed.contains(mv) { return false }
        if t["motor_vehicle"] == "no" || t["vehicle"] == "no" || t["access"] == "no" { return true }
        return false
    }

    private static func describe(_ t: [String: String]) -> String {
        let label = [t["ref"], t["name"]].compactMap { $0 }.joined(separator: " ")
        let n = label.isEmpty ? "unbenannte Straße" : label
        if t["highway"] == "motorway" || t["highway"] == "motorway_link" { return "Autobahn: \(n)" }
        if t["motorroad"] == "yes" { return "Kraftfahrstraße: \(n)" }
        return "Für Mopeds gesperrt: \(n)"
    }

    private static func firstSustainedHit(_ slice: [CLLocationCoordinate2D],
                                          path: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        var run = 0
        for (i, p) in slice.enumerated() {
            if Geo.distance(p, toPath: path) <= tolerance {
                run += 1
                if run >= minRun { return slice[i - minRun + 1] }
            } else {
                run = 0
            }
        }
        return nil
    }

    // MARK: Hilfsfunktionen

    static func coordinates(of route: MKRoute) -> [CLLocationCoordinate2D] {
        let n = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }

    private static func densify(_ c: [CLLocationCoordinate2D], spacing: Double) -> [CLLocationCoordinate2D] {
        guard var prev = c.first else { return [] }
        var out = [prev]
        for next in c.dropFirst() {
            let d = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
            let n = max(1, Int(d / spacing))
            for k in 1...n {
                let t = Double(k) / Double(n)
                out.append(CLLocationCoordinate2D(
                    latitude: prev.latitude + (next.latitude - prev.latitude) * t,
                    longitude: prev.longitude + (next.longitude - prev.longitude) * t))
            }
            prev = next
        }
        return out
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
