import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Floating thumbnail shown in the bottom-left corner after a capture or a recording.
/// Hovering reveals Copy / Save in the centre and round buttons in the corners; the
/// thumbnail itself can be dragged into other apps.
///
/// A screenshot lives in memory (`capture`). A recording is a file already in the save
/// folder (`recordingURL`): closing the overlay leaves it there, Save As copies it elsewhere.
final class PreviewOverlay: NSPanel {
    static let cardSize = NSSize(width: 220, height: 138)

    let capture: CapturedImage?
    private(set) var recordingURL: URL?
    var onPin: ((CapturedImage) -> Void)?
    var onAnnotate: ((CapturedImage) -> Void)?
    /// Shows a recording in the system's Quick Look.
    var onQuickLook: ((URL) -> Void)?
    /// Converts a video to a GIF: (video, destination, longest side in pixels, done).
    var convertToGIF: ((URL, URL, Int, @escaping (Bool) -> Void) -> Void)?
    /// Called when the overlay wants to go away; the owner closes and forgets it.
    var onDismiss: ((PreviewOverlay) -> Void)?
    /// Hint that the pointer is doing something over this overlay; see `setHovering`.
    var onPointerActivity: (() -> Void)?
    /// Directory for the temporary PNG created when the thumbnail is dragged out.
    var dragDirectory: URL?
    /// Seconds without hovering before the overlay dismisses itself; nil keeps it until
    /// closed.
    var autoCloseDelay: TimeInterval? { didSet { restartAutoClose() } }
    var isRecording: Bool { recordingURL != nil }

    private let card: CardView
    private let controls = NSView()
    private let centre = NSStackView()
    private let busyLabel = NSTextField(labelWithString: L("gif.creating"))
    /// Longest side for a GIF made from this recording, so it comes out at point size.
    private let gifMaxSide: Int
    private var autoCloseTimer: Timer?
    private var busy = false
    private(set) var hovering = false

    init(capture: CapturedImage) {
        self.capture = capture
        gifMaxSide = 0
        card = CardView(frame: NSRect(origin: .zero, size: Self.cardSize))
        super.init(contentRect: NSRect(origin: .zero, size: Self.cardSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure()
        if let file = capture.fileURL {
            loadThumbnail(of: file, imageSize: capture.pixelSize)
        } else {
            // Enough pixels to aspect-fill the card on a Retina display, and no more.
            let fill = max(Self.cardSize.width / capture.pixelSize.width,
                           Self.cardSize.height / capture.pixelSize.height)
            let longSide = max(capture.pixelSize.width, capture.pixelSize.height)
            card.image = capture.downsampled(maxPixel: min(longSide * fill * 2, 1600))
        }
    }

    /// Overlay for a finished recording (.mp4 or .gif) in the save folder.
    init(recording url: URL, gifMaxSide: Int) {
        capture = nil
        recordingURL = url
        self.gifMaxSide = gifMaxSide
        card = CardView(frame: NSRect(origin: .zero, size: Self.cardSize))
        super.init(contentRect: NSRect(origin: .zero, size: Self.cardSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure()
        loadThumbnail(of: url)
    }

    private func configure() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        card.wantsLayer = true
        card.onPointerActivity = { [weak self] in self?.onPointerActivity?() }
        // A drag hands over the file itself: a recording in the save folder, or the
        // capture's own file, which then outlives the card a while for the app reading it.
        card.dragFile = { [weak self] in
            guard let self = self else { return nil }
            if let url = self.recordingURL { return url }
            if let capture = self.capture, let file = capture.fileURL {
                capture.wasDraggedOut = true
                return file
            }
            return self.writeDragFile()
        }
        card.onDragCompleted = { [weak self] in self?.dismiss() }
        contentView = card
        buildControls(in: card)
        setAccessibilityIdentifier("preview")
        exposeAsImage(card, label: isRecording ? L("preview.recording") : L("preview.screenshot"), id: "preview.image",
                      buttonsIn: controls)
    }

    private var isVideo: Bool { recordingURL?.pathExtension.lowercased() == "mp4" }

    /// The system's thumbnail service decodes the image or video outside this process,
    /// so none of the memory that decoding needs is ever allocated here. The request asks
    /// for enough pixels to aspect-fill the card.
    private func loadThumbnail(of url: URL, imageSize: CGSize? = nil) {
        var size = CGSize(width: Self.cardSize.width * 1.6, height: Self.cardSize.width * 1.6)
        if let image = imageSize, image.width > 0, image.height > 0 {
            // The thumbnail fits inside the requested size, so a very tall or wide image
            // (a scrolling capture) needs a matching request to still cover the card sharply.
            let fill = max(Self.cardSize.width / image.width, Self.cardSize.height / image.height)
            let cap = min(1, 3000 / max(image.width * fill, image.height * fill))
            size = CGSize(width: image.width * fill * cap, height: image.height * fill * cap)
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.cgImage else { return }
            DispatchQueue.main.async { self?.card.image = image }
        }
    }

    private func buildControls(in card: NSView) {
        controls.frame = card.bounds
        controls.autoresizingMask = [.width, .height]
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        controls.alphaValue = 0
        controls.isHidden = true
        card.addSubview(controls)

        centre.addArrangedSubview(makePill(L("action.copy"), #selector(copyItem)))
        // A recording is saved already; its button saves a copy somewhere else.
        centre.addArrangedSubview(makePill(isRecording ? L("action.saveAs") : L("action.save"), #selector(saveItem)))
        centre.orientation = .vertical
        centre.spacing = 7
        centre.translatesAutoresizingMaskIntoConstraints = false
        busyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        busyLabel.textColor = .white
        busyLabel.isHidden = true
        busyLabel.translatesAutoresizingMaskIntoConstraints = false
        let closeButton = makeRoundIconButton(symbol: "xmark", label: L("action.close"),
                                              target: self, action: #selector(closeClicked))
        [centre, busyLabel, closeButton].forEach(controls.addSubview)
        NSLayoutConstraint.activate([
            centre.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            centre.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            busyLabel.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            busyLabel.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            closeButton.topAnchor.constraint(equalTo: controls.topAnchor, constant: 7),
            closeButton.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 7)
        ])

        // Top right pins a screenshot or opens a recording in Quick Look; bottom left
        // annotates a screenshot or turns a video into a GIF.
        let topRight = capture != nil
            ? makeRoundIconButton(symbol: "pin.fill", label: L("action.pin"),
                                  target: self, action: #selector(pinImage))
            : makeRoundIconButton(symbol: "eye.fill", label: L("preview.quickLook"),
                                  target: self, action: #selector(showQuickLook))
        controls.addSubview(topRight)
        topRight.topAnchor.constraint(equalTo: controls.topAnchor, constant: 7).isActive = true
        topRight.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -7).isActive = true
        var corner: NSView?
        if capture != nil {
            corner = makeRoundIconButton(symbol: "pencil", label: L("action.annotate"),
                                         target: self, action: #selector(annotateImage))
        } else if isVideo {
            corner = makeRoundIconButton(symbol: "GIF", label: L("preview.saveAsGIF"),
                                         target: self, action: #selector(saveAsGIF))
        }
        if let corner = corner {
            controls.addSubview(corner)
            corner.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -7).isActive = true
            corner.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 7).isActive = true
        }
        // Bottom right opens a recording in the app the system opens it with (QuickTime
        // Player, by default), for trimming and the like: no editor of our own.
        if let url = recordingURL {
            let app = NSWorkspace.shared.urlForApplication(toOpen: url)
                .map { FileManager.default.displayName(atPath: $0.path) }
            let open = makeRoundIconButton(symbol: "arrow.up.forward.app",
                                           label: app.map { L("preview.openWith", ($0 as NSString).deletingPathExtension) }
                                               ?? L("preview.open"),
                                           target: self, action: #selector(openInDefaultApp))
            controls.addSubview(open)
            open.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -7).isActive = true
            open.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -7).isActive = true
        }
    }

    @objc private func openInDefaultApp() {
        guard let url = recordingURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func makePill(_ title: String, _ action: Selector, width: CGFloat = 92,
                          height: CGFloat = 26) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: height > 24 ? 12 : 11, weight: .medium)
        ])
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        button.layer?.cornerRadius = height / 2
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: height).isActive = true
        return button
    }

    // MARK: Hover and auto-close

    /// Shows or hides the controls. Called by the owner, which knows which overlay of
    /// the stack is actually under the pointer.
    func setHovering(_ over: Bool) {
        guard over != hovering else { return }
        hovering = over
        if over {
            controls.isHidden = false
            autoCloseTimer?.invalidate()
        } else {
            restartAutoClose()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            controls.animator().alphaValue = (over || busy) ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.hovering, !self.busy else { return }
            self.controls.isHidden = true
        })
    }

    private func restartAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        guard let delay = autoCloseDelay, !hovering, !busy else { return }
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    override func close() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        super.close()
    }

    // MARK: Actions

    private func dismiss() {
        onDismiss?(self)
    }

    @objc private func closeClicked() {
        guard !busy else { return }
        dismiss()
    }

    @objc private func copyItem() {
        if let url = recordingURL {
            // The file is what gets pasted, so it has to outlive the overlay.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        } else {
            capture?.copyToPasteboard()
        }
        dismiss()
    }

    @objc private func pinImage() {
        guard let capture = capture else { return }
        onPin?(capture)
        dismiss()
    }

    /// Only looks: the preview stays, so the recording can still be saved or discarded.
    @objc private func showQuickLook() {
        guard let url = recordingURL else { return }
        onQuickLook?(url)
    }

    @objc private func annotateImage() {
        guard let capture = capture else { return }
        onAnnotate?(capture)
        dismiss()
    }

    /// Asks where to save. `finish` receives the chosen location, or nil if cancelled.
    private func askSaveLocation(type: UTType, name: String, finish: @escaping (URL?) -> Void) {
        autoCloseTimer?.invalidate()
        let picker = NSSavePanel()
        picker.allowedContentTypes = [type]
        picker.nameFieldStringValue = name
        picker.directoryURL = Settings.saveDirectory
        QuietMode.activate()
        picker.begin { [weak self] result in
            if result == .OK, let url = picker.url {
                finish(url)
            } else {
                self?.restartAutoClose()
                finish(nil)
            }
        }
    }

    @objc private func saveItem() {
        if let source = recordingURL {
            let type = UTType(filenameExtension: source.pathExtension) ?? .data
            askSaveLocation(type: type, name: source.lastPathComponent) { [weak self] url in
                guard let url = url else { return }
                // A copy: the recording stays where it was recorded.
                guard url.standardizedFileURL != source.standardizedFileURL else { self?.dismiss(); return }
                do {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: source, to: url)
                    self?.dismiss()
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        } else if let capture = capture, let data = capture.pngData() {
            askSaveLocation(type: .png, name: capture.suggestedFileName) { [weak self] url in
                guard let url = url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    self?.dismiss()
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    /// Saves the video as a GIF at a chosen location; the video stays where it was.
    @objc private func saveAsGIF() {
        guard let video = recordingURL, !busy else { return }
        let name = video.deletingPathExtension().lastPathComponent + ".gif"
        askSaveLocation(type: .gif, name: name) { [weak self] url in
            guard let self = self, let url = url, let convert = self.convertToGIF else { return }
            self.setBusy(true)
            convert(video, url, self.gifMaxSide) { [weak self] succeeded in
                guard let self = self else { return }
                self.setBusy(false)
                if succeeded {
                    self.dismiss()
                } else {
                    let alert = NSAlert()
                    alert.messageText = L("error.gifConversion")
                    alert.runModal()
                }
            }
        }
    }

    /// While a GIF is being written the controls give way to a progress note.
    private func setBusy(_ value: Bool) {
        busy = value
        busyLabel.isHidden = !value
        controls.subviews.forEach { if $0 !== busyLabel { $0.isHidden = value } }
        controls.isHidden = !(value || hovering)
        controls.alphaValue = (value || hovering) ? 1 : 0
    }

    /// Writes the capture to a temporary PNG so drop targets receive a real file.
    private func writeDragFile() -> URL? {
        guard let capture = capture, let directory = dragDirectory, let data = capture.pngData() else { return nil }
        let url = directory.appendingPathComponent(capture.suggestedFileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("%@: could not write drag file: %@", AppInfo.name, error.localizedDescription)
            return nil
        }
    }
}
