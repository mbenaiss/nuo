import AVFoundation
import SafariServices
import SwiftUI
import VisionKit

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// Product and parcel label scanner for the `barcode` app command, with a manual entry fallback (simulator, no camera,
/// denied). The symbology goes to the gateway, which tells a retail code from a parcel label.
struct BarcodeScannerSheet: View {
    let onCode: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .checking
    @State private var manualCode = ""
    @State private var found: String?

    enum Phase { case checking, scanning, denied, unsupported }

    var body: some View {
        NavigationStack {
            ZStack {
                switch phase {
                case .checking:
                    ProgressView()
                case .scanning:
                    scanner
                case .denied:
                    fallback(
                        symbol: "camera.fill", title: "Camera access denied",
                        text: "Allow camera access in Settings to scan, or enter the code by hand.", showsSettings: true)
                case .unsupported:
                    fallback(
                        symbol: "barcode.viewfinder", title: "Scanner unavailable",
                        text: "This device cannot scan barcodes. Enter the code by hand.", showsSettings: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(phase == .scanning ? Color.black : Color.canvas)
            .navigationTitle("Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(phase == .scanning ? .white : Color.ink)
                }
            }
            .toolbarColorScheme(phase == .scanning ? .dark : nil, for: .navigationBar)
        }
        .task { await resolvePhase() }
    }

    private var scanner: some View {
        ZStack {
            BarcodeScannerView { code, symbology in
                guard found == nil else { return }
                found = code
                Haptics.success()
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    deliver(code, symbology: symbology)
                }
            }
            .ignoresSafeArea()
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(found == nil ? Color.white.opacity(0.9) : Color.good, lineWidth: 3)
                .frame(width: 280, height: 150)
                .animation(.snappy, value: found)
            VStack {
                Spacer()
                Text(found.map { String(localized: "Code \($0)") } ?? String(localized: "Aim at a barcode: food, cosmetic or parcel"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .contentTransition(.opacity)
                    .padding(.bottom, 40)
            }
        }
    }

    private func fallback(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey, showsSettings: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 72, height: 72)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(spacing: 6) {
                Text(title).font(.title3.bold()).foregroundStyle(Color.ink)
                Text(text).font(.subheadline).foregroundStyle(Color.text2).multilineTextAlignment(.center)
            }
            TextField("Barcode or tracking no.", text: $manualCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(14)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line))
            Button("Send code") { deliver(manualCode.trimmingCharacters(in: .whitespaces), symbology: nil) }
                .buttonStyle(InkButtonStyle())
                .disabled(!isValid(manualCode))
                .opacity(isValid(manualCode) ? 1 : 0.45)
            if showsSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Color.accent)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
    }

    private func isValid(_ code: String) -> Bool {
        let compact = code.filter { !$0.isWhitespace }
        return compact.allSatisfy { $0.isLetter || $0.isNumber } && compact.contains(where: \.isNumber) && (6...40).contains(compact.count)
    }

    private func deliver(_ code: String, symbology: String?) {
        dismiss()
        onCode(code, symbology)
    }

    private func resolvePhase() async {
        guard DataScannerViewController.isSupported else { phase = .unsupported; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { phase = .denied; return }
        default:
            phase = .denied
            return
        }
        phase = DataScannerViewController.isAvailable ? .scanning : .unsupported
    }
}

private struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String, String?) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13, .upce, .code128, .code39, .code93, .itf14, .qr, .dataMatrix, .pdf417])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !controller.isScanning { try? controller.startScanning() }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String, String?) -> Void
        init(onCode: @escaping (String, String?) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case let .barcode(barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty {
                    onCode(value, barcode.observation.symbology.rawValue)
                    return
                }
            }
        }
    }
}
