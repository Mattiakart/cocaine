// The island's Mirror page: the camera (MirrorController) and its preview.

import AppKit
import AVFoundation
import Combine
import CoreAudio
import EventKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

/// A live view of the front camera, mirrored like a mirror. The camera runs only while it is on screen.
final class MirrorController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Camera: Identifiable, Equatable { var id: String; var name: String }
    @Published var denied = false
    @Published var hasFrames = false
    @Published var stalled = false
    @Published var cameras: [Camera] = []
    @Published var selected = ""
    @Published var flip = AppDefaults.store.object(forKey: "mirrorFlip") as? Bool ?? true { didSet { AppDefaults.store.set(flip, forKey: "mirrorFlip") } }
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "local.cocaine.mirror")
    private var gotFrame = false
    private var generation = 0

    /// Checks the camera permission, asks for it if it was never asked, then starts the camera.
    func start() {
        denied = false; hasFrames = false; stalled = false
        wanted = true
        switch Permissions.state(.camera) {
        case .granted: run()
        case .notAsked:
            Permissions.request(.camera) { [weak self] in
                guard let self else { return }
                if Permissions.state(.camera) != .granted { self.denied = true }
                else if self.wanted { self.run() }               // the page may have closed while macOS asked
            }
        case .denied: denied = true
        }
    }
    private var wanted = false

    private func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }

    private func run() {
        let devices = discover()
        cameras = devices.map { Camera(id: $0.uniqueID, name: $0.localizedName) }
        // The Mac's own camera first: the "default" can be an iPhone that isn't ready.
        let builtIn = devices.first { $0.deviceType == .builtInWideAngleCamera }?.uniqueID
        if selected.isEmpty || !cameras.contains(where: { $0.id == selected }) { selected = builtIn ?? cameras.first?.id ?? "" }
        configure(selected)
    }

    /// Points the session at that camera (replacing the previous one) and starts it; watches that pictures really arrive.
    func configure(_ id: String) {
        selected = id
        generation += 1
        let mine = generation
        gotFrame = false; hasFrames = false; stalled = false
        queue.async {
            guard let cam = AVCaptureDevice(uniqueID: id) ?? self.discover().first, let input = try? AVCaptureDeviceInput(device: cam) else {
                DispatchQueue.main.async { self.stalled = true }
                return
            }
            self.session.beginConfiguration()
            for old in self.session.inputs { self.session.removeInput(old) }
            if self.session.canAddInput(input) { self.session.addInput(input) }
            if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) {
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == mine, !self.hasFrames else { return }
            self.stalled = true
        }
    }

    /// The first picture: the camera works. The data output was only there to see it: it is removed (it would keep converting
    /// and delivering 30 frames a second next to the preview for as long as the page is open). Choosing another camera adds it again.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !gotFrame else { return }
        gotFrame = true
        DispatchQueue.main.async { self.hasFrames = true; self.stalled = false }
        queue.async {
            self.session.beginConfiguration()
            if self.session.outputs.contains(self.output) { self.session.removeOutput(self.output) }
            self.session.commitConfiguration()
        }
    }

    func stop() {
        generation += 1
        wanted = false
        hasFrames = false; stalled = false
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }
}

/// The camera's picture, live. `flip` turns it into a mirror (left and right swapped, as in a real one).
private struct MirrorPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let flip: Bool

    final class PreviewView: NSView {
        let preview: AVCaptureVideoPreviewLayer
        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ v: PreviewView, context: Context) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        v.preview.setAffineTransform(CGAffineTransform(scaleX: flip ? -1 : 1, y: 1))
        CATransaction.commit()
    }
}

extension IslandView {
    // MARK: mirror

    var mirrorTab: some View {
        let mr = model.mirror
        return HStack(alignment: .top, spacing: Space.gutter) {      // template A: 250 pt, a 22 pt gutter (as Home, Focus, Status)
            ZStack {
                Color.white.opacity(0.08)
                if mr.denied {
                    VStack(spacing: Space.m) {
                        Text(L("Allow the camera in System Settings → Privacy & Security → Camera")).font(UI.detail).multilineTextAlignment(.center).foregroundStyle(UI.secondary)
                        Button(L("Allow")) { Permissions.request(.camera) { mr.start() } }
                            .buttonStyle(CocaineButtonStyle(kind: .primary, height: CTL.hDialog))
                    }.padding(12)
                } else {
                    MirrorPreview(session: mr.session, flip: mr.flip)
                    if !mr.hasFrames {
                        Text(mr.stalled ? L("No picture from the camera. Is another app using it?") : L("Starting the camera…"))
                            .font(UI.detail).multilineTextAlignment(.center).foregroundStyle(UI.secondary).padding(12)
                    }
                }
            }
            .frame(width: 250, height: 146).clipShape(RoundedRectangle(cornerRadius: CTL.cardRadius))
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(spacing: Space.m) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill").font(UI.icon).foregroundStyle(mr.flip ? Island.accent : UI.hint).frame(width: UI.iconColumn)
                    Text(L("Mirror")).font(UI.value).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    CocaineSwitch(on: mr.flip) { mr.flip.toggle() }.accessibilityLabel(L("Mirror"))
                }
                .help(L("On: like a mirror (left and right swapped). Off: as others see you."))
                if mr.cameras.count > 1 {
                    HStack(spacing: Space.m) {
                        Image(systemName: "camera").font(UI.icon).foregroundStyle(UI.hint).frame(width: UI.iconColumn)
                        IslandValueButton(title: L("Camera"), value: mr.cameras.first { $0.id == mr.selected }?.name ?? L("Camera")) {
                            IslandChoices.ask(L("Camera"), icon: "camera", mr.cameras.map { DialogChoice(id: $0.id, title: $0.name, symbol: $0.id == mr.selected ? "checkmark" : "camera") }) { mr.configure($0) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                Text(L("The camera runs only while this page is open.")).font(UI.detail).foregroundStyle(UI.hint).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { mr.start() }
        .onDisappear { mr.stop() }
    }

}
