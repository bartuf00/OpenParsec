import AVKit
import AVFoundation
import CoreVideo
import OpenGLES
import GLKit
import MetalKit
import CoreMedia



private let kGL_BGRA: GLenum = 0x80E1

protocol CaptureSurfaceProvider {
    func setup(width: Int, height: Int)
    func destroy()
    func getPixelBuffer() -> CVPixelBuffer?
}

// MARK: - Picture in Picture Manager for OpenGL
final class GLCaptureSurfaceProvider: CaptureSurfaceProvider {
    private var textureCache: CVOpenGLESTextureCache?
    private var pixelBuffer: CVPixelBuffer?
    private var cvTexture: CVOpenGLESTexture?
    private var captureFBO: GLuint = 0
    private var glContext: EAGLContext

    init(glContext: EAGLContext) {
        self.glContext = glContext
        CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, glContext, nil, &textureCache)
    }

    func setup(width: Int, height: Int) {
        destroy()

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferOpenGLESCompatibilityKey as String: true
        ]

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        guard let pixelBuffer = pb else { return }
        self.pixelBuffer = pixelBuffer

        var texture: CVOpenGLESTexture?
        CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            GLenum(GL_TEXTURE_2D),
            GL_RGBA,
            GLsizei(width), GLsizei(height),
            kGL_BGRA,
            GLenum(GL_UNSIGNED_BYTE),
            0,
            &texture
        )
        guard let cvTex = texture else { return }
        self.cvTexture = cvTex

        let textureName = CVOpenGLESTextureGetName(cvTex)
        glGenFramebuffers(1, &captureFBO)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), captureFBO)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER),
                               GLenum(GL_COLOR_ATTACHMENT0),
                               GLenum(GL_TEXTURE_2D),
                               textureName, 0)
    }

    func destroy() {
        if captureFBO != 0 {
            glDeleteFramebuffers(1, &captureFBO)
            captureFBO = 0
        }
        cvTexture = nil
        pixelBuffer = nil
    }

    func getPixelBuffer() -> CVPixelBuffer? {
        return pixelBuffer
    }
}

// MARK: - Picture in Picture Manager for Metal
final class MetalCaptureSurfaceProvider: CaptureSurfaceProvider {
    private var textureCache: CVMetalTextureCache?
    private var pixelBuffer: CVPixelBuffer?
    private var cvTexture: CVMetalTexture?
    private var device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func setup(width: Int, height: Int) {
        destroy()

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        guard let pixelBuffer = pb else { return }
        self.pixelBuffer = pixelBuffer

        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTex
        )
        guard let cvTexture = cvTex else { return }
        self.cvTexture = cvTexture
    }

    func destroy() {
        cvTexture = nil
        pixelBuffer = nil
    }

    func getPixelBuffer() -> CVPixelBuffer? {
        return pixelBuffer
    }

    func getMTLTexture() -> MTLTexture? {
        return cvTexture != nil ? CVMetalTextureGetTexture(cvTexture!) : nil
    }
}



@available(iOS 15.0, *)
class PictureInPictureManager: NSObject {
    static let shared = PictureInPictureManager()

    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    private var pipSourceView: UIView?

    private var captureProvider: CaptureSurfaceProvider?
    private var cachedFormatDescription: CMVideoFormatDescription?

    private var displayLink: CADisplayLink?
    private var currentPTS: CMTime = .zero

    private(set) var isPiPActive = false
    private(set) var isStarting = false
    private var isSetup = false

    var onPiPStopped: (() -> Void)?
    var onPiPStartFailed: (() -> Void)?
    var onRestoreUserInterface: (() -> Void)?

    private override init() { super.init() }

    // MARK: - Setup
    func setup(sourceView: UIView, provider: CaptureSurfaceProvider) {
        guard !isSetup else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        self.captureProvider = provider

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect

        let containerView = UIView(frame: sourceView.bounds)
        containerView.isUserInteractionEnabled = false

        containerView.frame = CGRect(x: -9999, y: -9999, width: 1, height: 1)

        containerView.layer.addSublayer(layer)
        layer.frame = containerView.bounds
        sourceView.addSubview(containerView)

        self.sampleBufferDisplayLayer = layer
        self.pipSourceView = containerView

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.pipController = controller

        startFramePump()
        isSetup = true

    }

    // MARK: - PiP Control

    private func startFramePump() {
        stopFramePump()

        currentPTS = .zero

        let link = CADisplayLink(target: self, selector: #selector(renderFrame))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)

        displayLink = link
    }

    private func stopFramePump() {
        displayLink?.invalidate()
        displayLink = nil
    }


    // MARK: PIP 繪製
    @objc
    private func renderFrame() {
        guard let pixelBuffer = captureProvider?.getPixelBuffer(),
            let layer = sampleBufferDisplayLayer else {
            return
        }

        // 建立 format description
        if cachedFormatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &cachedFormatDescription
            )
        }

        guard let format = cachedFormatDescription else {
            return
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: currentPTS,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?

        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr,
            let sb = sampleBuffer else {
            return
        }

        if layer.status == .failed {
            layer.flush()
        }

        layer.enqueue(sb)

        currentPTS = CMTimeAdd(
            currentPTS,
            CMTime(value: 1, timescale: 30)
        )
    }



    func startPiP() {
        guard isSetup, let controller = pipController,
              !isPiPActive, !isStarting else { return }

        guard controller.isPictureInPicturePossible else {
            write_log_from_swift("PiP not possible right now")
            return
        }

        isStarting = true
        controller.startPictureInPicture()
    }

    func stopPiP() {
        guard isSetup, let controller = pipController,
              isPiPActive else { return }
        isStarting = false
        controller.stopPictureInPicture()
    }

    func metalCaptureTexture() -> MTLTexture? {
        guard let provider = captureProvider as? MetalCaptureSurfaceProvider else { return nil }
        return provider.getMTLTexture()
    }

    // MARK: - Cleanup
    func teardown() {
        if isPiPActive {
            stopPiP()
        }

        stopFramePump()

        captureProvider?.destroy()
        captureProvider = nil
        pipController = nil
        sampleBufferDisplayLayer?.removeFromSuperlayer()
        sampleBufferDisplayLayer = nil
        pipSourceView?.removeFromSuperview()
        pipSourceView = nil
        isSetup = false
        isPiPActive = false
        isStarting = false
        cachedFormatDescription = nil
        onPiPStopped = nil
        onPiPStartFailed = nil
        onRestoreUserInterface = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Delegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isPiPActive = true
        isStarting = false

        write_log_from_swift("PiP 正在開始 (Delegate 回調)")
    }


    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {

        write_log_from_swift("PiP將開始 (Delegate 回調)")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isPiPActive = false
        onPiPStopped?()

        write_log_from_swift("PiP did stop")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onRestoreUserInterface?()
        completionHandler(true)

        write_log_from_swift("Restoring UI for PiP stop")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isPiPActive = false
        isStarting = false
        onPiPStartFailed?()

        write_log_from_swift("PiP failed to start: \(error.localizedDescription)")
    }
}





// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {

	func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
		// Live content — nothing to do
	}

	func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
		return CMTimeRange(start: .zero, duration: .positiveInfinity)
	}

	func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
		return false
	}

	func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
									didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
	}

	func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
									skipByInterval skipInterval: CMTime,
									completion completionHandler: @escaping () -> Void) {
		// Live content — no seeking
		completionHandler()
	}
}