import AppKit
import CoreLocation
import MapKit

/// Map and the system-formatted place address share one rounded inspector region.
@MainActor
final class MediaLocationCard: NSView, MKMapViewDelegate {
    struct Coordinate: Hashable, Sendable {
        let latitude: Double
        let longitude: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
        var mapCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct Place: Sendable {
        let title: String
        let address: String?

        init(title: String, address: String?) {
            self.title = title
            self.address = address
        }

        init(mapItem: MKMapItem) {
            // Let MapKit format regional address order. No street/POI searches
            // or handwritten administrative-area concatenation.
            let representations = mapItem.addressRepresentations
            let fullAddress = Self.nonempty(representations?.fullAddress(includingRegion: true, singleLine: true))
                ?? Self.nonempty(mapItem.address?.fullAddress)
            title = Self.nonempty(mapItem.name)
                ?? Self.nonempty(mapItem.address?.shortAddress)
                ?? Self.nonempty(representations?.cityWithContext)
                ?? "拍摄位置"
            address = fullAddress == title ? nil : fullAddress
        }

        private static func nonempty(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    typealias Resolver = @MainActor (Coordinate) async throws -> Place

    let mapView = MKMapView()
    private let titleField = NSTextField(wrappingLabelWithString: "拍摄位置")
    private let addressField = NSTextField(wrappingLabelWithString: "正在查找地点…")
    private let openButton = NSButton()
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let textStack = NSStackView()
    private let footer = NSView()
    var onContentChange: (() -> Void)?
    private let resolver: Resolver?
    private var lookupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var geocodingRequest: MKReverseGeocodingRequest?
    private var generation = UUID()
    private var resolvedPlaces: [Coordinate: Place] = [:]
    private(set) var coordinate: Coordinate?
    private(set) var isResolving = false
    private(set) var resolutionSucceeded = false

    var displayedTitle: String { titleField.stringValue }
    var displayedAddress: String? { addressField.isHidden ? nil : addressField.stringValue }
    var textFields: [NSTextField] { [titleField, addressField].filter { !$0.isHidden } }

    init(resolver: Resolver? = nil) {
        self.resolver = resolver
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("拍摄位置")

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsZoomControls = false
        mapView.showsCompass = false
        mapView.showsPitchControl = false
        mapView.showsUserTrackingButton = false
        mapView.showsUserLocation = false
        mapView.setAccessibilityLabel("拍摄位置地图")
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "Location")
        mapView.delegate = self
        mapView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openInMaps)))

        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleField.textColor = .labelColor
        addressField.font = .systemFont(ofSize: NSFont.systemFontSize)
        addressField.textColor = .secondaryLabelColor
        for field in [titleField, addressField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.isSelectable = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleField)
        textStack.addArrangedSubview(addressField)
        textStack.addArrangedSubview(retryButton)
        for field in [titleField, addressField] {
            field.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }
        retryButton.bezelStyle = .inline
        retryButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.setAccessibilityLabel("重新获取此位置的地点名称")
        retryButton.isHidden = true

        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.isBordered = false
        openButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "在地图中打开")
        openButton.contentTintColor = .secondaryLabelColor
        openButton.target = self
        openButton.action = #selector(openInMaps)
        openButton.toolTip = "在地图中打开"
        openButton.setAccessibilityLabel("在地图中打开此位置")

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(textStack)
        footer.addSubview(openButton)
        addSubview(mapView)
        addSubview(footer)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.heightAnchor.constraint(equalToConstant: 180),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.topAnchor.constraint(equalTo: mapView.bottomAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            textStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
            textStack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -12),
            openButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            openButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 10),
            openButton.widthAnchor.constraint(equalToConstant: 20),
            openButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Apple's semantic fill for a large grouped region keeps the footer
        // visibly attached to the map in light and dark appearances.
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }

    override func layout() {
        super.layout()
        let width = textStack.bounds.width
        guard width > 0 else { return }
        for field in [titleField, addressField] where field.preferredMaxLayoutWidth != width {
            field.preferredMaxLayoutWidth = width
            field.invalidateIntrinsicContentSize()
        }
    }

    func show(_ newCoordinate: Coordinate?, simulateFailure: Bool = false) {
        if !simulateFailure, let newCoordinate, coordinate == newCoordinate,
           isResolving || resolutionSucceeded { return }
        invalidateRequest()
        coordinate = newCoordinate
        setAccessibilityLabel("拍摄位置")
        resolutionSucceeded = false
        mapView.removeAnnotations(mapView.annotations)
        retryButton.isHidden = true
        isHidden = newCoordinate == nil
        openButton.isEnabled = newCoordinate != nil
        guard let newCoordinate else {
            titleField.stringValue = ""
            addressField.stringValue = ""
            addressField.isHidden = true
            return
        }

        // The pin always remains at the supplied media coordinate. A reverse
        // geocoder's representative point must not move the shooting location.
        let pin = MKPointAnnotation()
        pin.coordinate = newCoordinate.mapCoordinate
        pin.title = "拍摄位置"
        mapView.addAnnotation(pin)
        mapView.setRegion(MKCoordinateRegion(center: newCoordinate.mapCoordinate,
            latitudinalMeters: 1_200, longitudinalMeters: 1_200), animated: false)
        titleField.stringValue = "拍摄位置"
        addressField.stringValue = "正在查找地点…"
        addressField.isHidden = false
        titleField.toolTip = nil
        addressField.toolTip = nil
        if simulateFailure {
            showFailure()
            return
        }
        if let place = resolvedPlaces[newCoordinate] {
            apply(place)
            return
        }
        resolve(newCoordinate)
    }

    func cancelResolution() { invalidateRequest() }

    func resumeResolution() {
        guard let coordinate, !isResolving, !resolutionSucceeded else { return }
        show(coordinate)
    }

    private func invalidateRequest() {
        generation = UUID()
        geocodingRequest?.cancel()
        geocodingRequest = nil
        lookupTask?.cancel()
        lookupTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        isResolving = false
    }

    private func resolve(_ requestedCoordinate: Coordinate) {
        let requestGeneration = generation
        isResolving = true
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            guard let self, self.generation == requestGeneration,
                  self.coordinate == requestedCoordinate, self.isResolving else { return }
            self.invalidateRequest()
            self.showFailure()
        }
        lookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let place: Place
                if let resolver = self.resolver {
                    place = try await resolver(requestedCoordinate)
                } else {
                    guard let request = MKReverseGeocodingRequest(location: requestedCoordinate.location) else {
                        throw LocationError.noAddress
                    }
                    request.preferredLocale = Locale.current
                    self.geocodingRequest = request
                    let items = try await request.mapItems
                    guard let item = items.first else { throw LocationError.noAddress }
                    place = Place(mapItem: item)
                }
                guard !Task.isCancelled, self.generation == requestGeneration,
                      self.coordinate == requestedCoordinate else { return }
                if self.resolvedPlaces.count >= 64 { self.resolvedPlaces.removeAll() }
                self.resolvedPlaces[requestedCoordinate] = place
                self.geocodingRequest = nil
                self.lookupTask = nil
                self.deadlineTask?.cancel()
                self.deadlineTask = nil
                self.isResolving = false
                self.apply(place)
            } catch {
                guard !Task.isCancelled, self.generation == requestGeneration,
                      self.coordinate == requestedCoordinate else { return }
                self.geocodingRequest = nil
                self.lookupTask = nil
                self.deadlineTask?.cancel()
                self.deadlineTask = nil
                self.isResolving = false
                self.showFailure()
            }
        }
    }

    private func apply(_ place: Place) {
        titleField.stringValue = place.title
        titleField.toolTip = place.title
        addressField.stringValue = place.address ?? ""
        addressField.toolTip = place.address
        addressField.isHidden = place.address == nil
        retryButton.isHidden = true
        resolutionSucceeded = true
        setAccessibilityLabel("拍摄位置：\(place.title)")
        needsLayout = true
        onContentChange?()
    }

    private func showFailure() {
        titleField.stringValue = "拍摄位置"
        addressField.stringValue = "暂时无法获取地点名称"
        addressField.isHidden = false
        retryButton.isHidden = false
        resolutionSucceeded = false
        setAccessibilityLabel("拍摄位置：暂时无法获取地点名称")
        needsLayout = true
        onContentChange?()
    }

    @objc private func retry() {
        guard let coordinate else { return }
        show(coordinate)
    }

    @objc private func openInMaps() {
        guard let coordinate else { return }
        let item = MKMapItem(location: coordinate.location, address: nil)
        item.name = resolutionSucceeded ? titleField.stringValue : "拍摄位置"
        item.openInMaps()
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        guard annotation is MKPointAnnotation else { return nil }
        let marker = mapView.dequeueReusableAnnotationView(withIdentifier: "Location", for: annotation)
            as! MKMarkerAnnotationView
        marker.displayPriority = .required
        marker.titleVisibility = .hidden
        marker.subtitleVisibility = .hidden
        marker.canShowCallout = false
        marker.animatesWhenAdded = false
        marker.setAccessibilityLabel("拍摄位置")
        return marker
    }

    private enum LocationError: Error { case noAddress }
}
