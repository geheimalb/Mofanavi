import CarPlay
import SwiftUI
import MapKit
import Combine

/// Karte, die im CarPlay-Display hinter den Templates angezeigt wird.
struct CarMapView: View {
    @ObservedObject private var navi = Navi.shared

    var body: some View {
        Map(initialPosition: .userLocation(followsHeading: true, fallback: .automatic)) {
            UserAnnotation()
            if let r = navi.route {
                MapPolyline(r)
                    .stroke(navi.violations.isEmpty ? Color.blue : Color.red, lineWidth: 8)
            }
        }
    }
}

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPMapTemplateDelegate, CPSearchTemplateDelegate {

    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapTemplate: CPMapTemplate?
    private var session: CPNavigationSession?
    private var currentManeuver: CPManeuver?
    private var searchItems: [MKMapItem] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: Verbindung

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        self.carWindow = window
        window.rootViewController = UIHostingController(rootView: CarMapView())

        let template = CPMapTemplate()
        template.mapDelegate = self
        template.leadingNavigationBarButtons = [
            CPBarButton(title: "Ziel suchen") { [weak self] _ in self?.showSearch() }
        ]
        mapTemplate = template
        interfaceController.setRootTemplate(template, animated: true, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        Navi.shared.stopGuidance()
        cancellables.removeAll()
        self.interfaceController = nil
        self.carWindow = nil
        self.mapTemplate = nil
    }

    // MARK: Suche

    private func showSearch() {
        let search = CPSearchTemplate()
        search.delegate = self
        interfaceController?.pushTemplate(search, animated: true, completion: nil)
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        Task {
            let items = Array((await Navi.shared.searchItems(searchText)).prefix(12))
            searchItems = items
            let list = items.enumerated().map { (i, m) -> CPListItem in
                let li = CPListItem(text: m.name ?? "Ziel", detailText: m.placemark.title)
                li.userInfo = i
                return li
            }
            completionHandler(list)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let i = item.userInfo as? Int, i < searchItems.count else {
            completionHandler()
            return
        }
        let target = searchItems[i]
        Task {
            let route = await Navi.shared.calculate(to: target)
            await MainActor.run {
                interfaceController?.popTemplate(animated: true, completion: nil)
                if let route { showPreview(route: route, target: target) }
                completionHandler()
            }
        }
    }

    // MARK: Vorschau und Start

    private func showPreview(route: MKRoute, target: MKMapItem) {
        let navi = Navi.shared
        let summary = String(format: "%.1f km · ca. %d Min", route.distance / 1000, navi.etaMinutes(route))
        let info = navi.violations.isEmpty
            ? "Keine Autobahn oder Kraftfahrstraße erkannt"
            : "ACHTUNG: Verbotene Straße auf der Route!"
        let choice = CPRouteChoice(summaryVariants: [summary],
                                   additionalInformationVariants: [info],
                                   selectionSummaryVariants: [summary])
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(),
                          destination: target,
                          routeChoices: [choice])
        mapTemplate?.showTripPreviews([trip], textConfiguration: nil)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        mapTemplate.hideTripPreviews()
        session = mapTemplate.startNavigationSession(for: trip)
        Navi.shared.startGuidance()
        updateManeuver()

        cancellables.removeAll()
        Navi.shared.$currentStepIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateManeuver() }
            .store(in: &cancellables)
        Navi.shared.$distanceToManeuver
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                guard let self, let m = self.currentManeuver else { return }
                self.session?.updateEstimates(
                    CPTravelEstimates(distanceRemaining: Measurement(value: d, unit: .meters),
                                      timeRemaining: d / 11),
                    for: m)
            }
            .store(in: &cancellables)
        Navi.shared.$isGuiding
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.session?.finishTrip()
                self?.session = nil
            }
            .store(in: &cancellables)
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        Navi.shared.stopGuidance()
        session?.cancelTrip()
        session = nil
        cancellables.removeAll()
    }

    private func updateManeuver() {
        guard let route = Navi.shared.route else { return }
        let i = Navi.shared.currentStepIndex
        guard i < route.steps.count else { return }
        let step = route.steps[i]

        let m = CPManeuver()
        m.instructionVariants = [step.instructions]
        m.symbolImage = UIImage(systemName: "arrow.up")
        m.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: step.distance, unit: .meters),
            timeRemaining: step.distance / 11)
        currentManeuver = m
        session?.upcomingManeuvers = [m]
    }
}
