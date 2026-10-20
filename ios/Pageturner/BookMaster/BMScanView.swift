import SwiftUI
import AVFoundation

/// A book's barcode: the camera reads the EAN-13 (books are ISBNs on the back
/// cover), and the digits go back for a catalogue search. A frame marks where
/// the code should sit; the first good read closes the sheet.
struct BMScanView: View {
    var onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScannerView(denied: $denied) { code in
                onCode(code)
                dismiss()
            }
            .ignoresSafeArea()
            if denied {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("Camera access is off")
                        .font(.headline)
                    Text("Allow the camera in Settings to scan a barcode — or type the ISBN instead.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .ptButtonStyle(prominent: true)
                }
                .padding(24)
                .ptGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(24)
            } else {
                Text("Point at the barcode on the back cover")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .ptGlassCapsule()
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Scan a barcode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

/// The capture session itself: rear camera, metadata for the barcode kinds a
/// book carries, the first candidate wins.
private struct ScannerView: UIViewControllerRepresentable {
    @Binding var denied: Bool
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onDenied = { denied = true }
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.stop()
    }
}

/// The preview layer fills the view; metadata lands on the main queue.
private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void = { _ in }
    var onDenied: () -> Void = {}
    private let session = AVCaptureSession()
    private var fired = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                Task { @MainActor in ok ? self?.configure() : self?.onDenied() }
            }
        default: onDenied()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { onDenied(); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { onDenied(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.ean13, .ean8, .upce, .code128]
        startSession()
    }

    /// startRunning/stopRunning block — Apple wants them off the main queue.
    private func startSession() {
        guard !session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    func stop() {
        guard session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !fired,
              let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        else { return }
        // A book's EAN-13 is its ISBN (978/979-prefixed); anything else still
        // goes back — the search can only say no.
        fired = true
        onCode(code)
    }
}
