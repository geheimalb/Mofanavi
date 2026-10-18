import SwiftUI
import MapKit

struct ContentView: View {
    @ObservedObject private var navi = Navi.shared
    @State private var query = ""
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.1374, longitude: 11.5755),
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)))

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                UserAnnotation()
                if let d = navi.destination {
                    Marker(d.name ?? "Ziel", coordinate: d.placemark.coordinate)
                }
                if let r = navi.route {
                    MapPolyline(r)
                        .stroke(navi.violations.isEmpty ? Color.blue : Color.red, lineWidth: 6)
                }
                ForEach(navi.violations) { v in
                    Annotation(v.reason, coordinate: v.coordinate) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .padding(4)
                            .background(.white, in: Circle())
                    }
                }
            }
            .mapControls { MapUserLocationButton(); MapCompass() }
            .ignoresSafeArea()
            .onReceive(navi.$route) { r in
                guard let r, !navi.isGuiding else { return }
                let rect = r.polyline.boundingMapRect
                position = .rect(rect.insetBy(dx: -rect.width * 0.3, dy: -rect.height * 0.3))
            }
            .onReceive(navi.$isGuiding) { g in
                if g { position = .userLocation(followsHeading: true, fallback: .automatic) }
            }

            VStack(spacing: 8) {
                searchBar
                if !navi.results.isEmpty { resultList }
                Spacer()
                panel
            }
            .padding()
        }
    }

    // MARK: Teile

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
            TextField("Ziel in München und Umgebung", text: $query)
                .submitLabel(.search)
                .onSubmit { Task { await navi.search(query) } }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var resultList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(navi.results, id: \.self) { item in
                    Button {
                        Task { await navi.calculate(to: item) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Unbekannt").font(.headline)
                            Text(item.placemark.title ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if navi.isChecking {
                HStack {
                    ProgressView()
                    Text("Prüfe Route auf erlaubte Straßen …")
                }
            } else if let r = navi.route {
                if navi.isGuiding, let ins = navi.currentInstruction {
                    Text(ins).font(.title3.bold())
                    Text("in \(Int(navi.distanceToManeuver)) m")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(String(format: "%.1f km · ca. %d Min (Moped 45 km/h)",
                            r.distance / 1000, navi.etaMinutes(r)))
                    .font(.headline)

                if navi.violations.isEmpty {
                    Label("Keine Autobahn, Kraftfahrstraße oder gesperrte Straße erkannt",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Achtung: Auf dieser Route sind Mopeds nicht erlaubt!",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    ForEach(navi.violations.prefix(4)) { v in
                        Text("• \(v.reason)").font(.caption)
                    }
                }

                if let note = navi.checkNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    navi.isGuiding ? navi.stopGuidance() : navi.startGuidance()
                } label: {
                    Text(navi.isGuiding
                         ? "Navigation beenden"
                         : (navi.violations.isEmpty ? "Navigation starten" : "Trotzdem starten (Route prüfen!)"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(navi.isGuiding || !navi.violations.isEmpty ? .red : .blue)
            } else if let e = navi.error {
                Text(e)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity((navi.isChecking || navi.route != nil || navi.error != nil) ? 1 : 0)
    }
}
