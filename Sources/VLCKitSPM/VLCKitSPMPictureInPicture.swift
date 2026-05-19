#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import UIKit
import VLCKitSPMObjCBridge

@available(iOS 15.0, *)
public struct VLCKitSPMSubtitleOverlayRequest {
    public let presentationTime: TimeInterval
    public let sourceSize: CGSize
    public let renderSize: CGSize

    public init(presentationTime: TimeInterval, sourceSize: CGSize, renderSize: CGSize) {
        self.presentationTime = presentationTime
        self.sourceSize = sourceSize
        self.renderSize = renderSize
    }
}

@available(iOS 15.0, *)
public enum VLCKitSPMSampleBufferVideoOutputError: Error {
    case callbacksUnavailable
    case alreadyAttached
}

@available(iOS 15.0, *)
public final class VLCKitSPMSampleBufferVideoOutput {
    public typealias SubtitleOverlayProvider = (VLCKitSPMSubtitleOverlayRequest) -> NSAttributedString?

    public var playbackTimeProvider: (() -> TimeInterval)?
    public var subtitleOverlayProvider: SubtitleOverlayProvider?
    public var onFirstFrameEnqueued: (() -> Void)?
    public var onFrameEnqueued: (() -> Void)?
    public var onDebugEvent: ((String) -> Void)?

    public private(set) var isAttached = false
    public private(set) var hasEnqueuedFrame = false

    private let displayLayer: AVSampleBufferDisplayLayer
    private let stateLock = NSLock()
    private let enqueueQueue = DispatchQueue(label: "dev.soupy.vlckitspm.sample-buffer-output.enqueue")
    private let maxRenderSize: CGSize
    private let preferredFramesPerSecond: Double
    private var slots: [VideoFrameSlot] = []
    private var nextSlotIndex = 0
    private var slotWidth = 0
    private var slotHeight = 0
    private var slotPitch = 0
    private var sourceSize: CGSize = .zero
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolWidth = 0
    private var pixelBufferPoolHeight = 0
    private var formatDescription: CMVideoFormatDescription?
    private var timebase: CMTimebase?
    private var frameCounter: Int64 = 0
    private var didNotifyFirstFrame = false
    private var retainedOpaque: UnsafeMutableRawPointer?
    private weak var attachedMediaPlayer: AnyObject?
    private var debugEventCounts: [String: Int] = [:]

    public init(
        displayLayer: AVSampleBufferDisplayLayer,
        maxRenderSize: CGSize = CGSize(width: 1280, height: 720),
        preferredFramesPerSecond: Double = 24
    ) {
        self.displayLayer = displayLayer
        self.maxRenderSize = maxRenderSize
        self.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        self.displayLayer.videoGravity = .resizeAspect
        self.displayLayer.backgroundColor = UIColor.black.cgColor
    }

    deinit {
        detach()
    }

    public func attach(to mediaPlayer: AnyObject) throws {
        stateLock.lock()
        let alreadyAttached = isAttached
        stateLock.unlock()
        guard !alreadyAttached else {
            throw VLCKitSPMSampleBufferVideoOutputError.alreadyAttached
        }

        let opaque = Unmanaged.passRetained(self).toOpaque()
        VLCKitSPMActiveVideoOutputRegistry.shared.register(opaque)
        emitDebugEvent("attach installing callbacks")
        let installed = VLCKitSPMInstallVideoCallbacks(
            mediaPlayer,
            vlcSPMVideoLockCallback,
            vlcSPMVideoUnlockCallback,
            vlcSPMVideoDisplayCallback,
            vlcSPMVideoFormatCallback,
            vlcSPMVideoCleanupCallback,
            opaque
        )

        guard installed else {
            VLCKitSPMActiveVideoOutputRegistry.shared.unregister(opaque)
            Unmanaged<VLCKitSPMSampleBufferVideoOutput>.fromOpaque(opaque).release()
            throw VLCKitSPMSampleBufferVideoOutputError.callbacksUnavailable
        }

        stateLock.lock()
        isAttached = true
        attachedMediaPlayer = mediaPlayer
        retainedOpaque = opaque
        hasEnqueuedFrame = false
        didNotifyFirstFrame = false
        stateLock.unlock()
    }

    public func detach() {
        stateLock.lock()
        guard isAttached else {
            stateLock.unlock()
            return
        }
        let player = attachedMediaPlayer
        let opaque = retainedOpaque
        isAttached = false
        attachedMediaPlayer = nil
        retainedOpaque = nil
        didNotifyFirstFrame = false
        stateLock.unlock()

        if let player {
            VLCKitSPMClearVideoCallbacks(player)
        }

        reset(removingDisplayedImage: true)

        if let opaque {
            VLCKitSPMActiveVideoOutputRegistry.shared.unregister(opaque)
            Unmanaged<VLCKitSPMSampleBufferVideoOutput>.fromOpaque(opaque).release()
        }
    }

    private func emitDebugEvent(_ event: String) {
        stateLock.lock()
        let count = (debugEventCounts[event] ?? 0) + 1
        debugEventCounts[event] = count
        stateLock.unlock()

        if count <= 5 || count == 10 || count == 30 || count % 120 == 0 {
            onDebugEvent?("\(event) count=\(count)")
        }
    }

    public func reset(removingDisplayedImage: Bool) {
        stateLock.lock()
        slots.removeAll()
        nextSlotIndex = 0
        slotWidth = 0
        slotHeight = 0
        slotPitch = 0
        sourceSize = .zero
        pixelBufferPool = nil
        pixelBufferPoolWidth = 0
        pixelBufferPoolHeight = 0
        formatDescription = nil
        timebase = nil
        frameCounter = 0
        hasEnqueuedFrame = false
        stateLock.unlock()

        DispatchQueue.main.async { [displayLayer] in
            displayLayer.controlTimebase = nil
            if removingDisplayedImage {
                displayLayer.flushAndRemoveImage()
            } else {
                displayLayer.flush()
            }
        }
    }

    fileprivate func configureFormat(
        opaque: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        chroma: UnsafeMutablePointer<CChar>?,
        width: UnsafeMutablePointer<CUnsignedInt>?,
        height: UnsafeMutablePointer<CUnsignedInt>?,
        pitches: UnsafeMutablePointer<CUnsignedInt>?,
        lines: UnsafeMutablePointer<CUnsignedInt>?
    ) -> CUnsignedInt {
        guard let chroma, let width, let height, let pitches, let lines else {
            emitDebugEvent("format missing arguments")
            return 0
        }
        emitDebugEvent("format input=\(width.pointee)x\(height.pointee)")

        let inputWidth = max(1, Int(width.pointee))
        let inputHeight = max(1, Int(height.pointee))
        let renderSize = Self.renderSize(for: CGSize(width: inputWidth, height: inputHeight), cappedBy: maxRenderSize)
        let renderWidth = max(1, Int(renderSize.width))
        let renderHeight = max(1, Int(renderSize.height))
        let pitch = renderWidth * 4

        chroma[0] = CChar(UInt8(ascii: "R"))
        chroma[1] = CChar(UInt8(ascii: "V"))
        chroma[2] = CChar(UInt8(ascii: "3"))
        chroma[3] = CChar(UInt8(ascii: "2"))
        width.pointee = CUnsignedInt(renderWidth)
        height.pointee = CUnsignedInt(renderHeight)
        pitches[0] = CUnsignedInt(pitch)
        lines[0] = CUnsignedInt(renderHeight)

        stateLock.lock()
        opaque?.pointee = retainedOpaque
        if slotWidth != renderWidth || slotHeight != renderHeight || slotPitch != pitch || slots.isEmpty {
            slots = (0..<3).map { _ in VideoFrameSlot(byteCount: pitch * renderHeight) }
            nextSlotIndex = 0
            slotWidth = renderWidth
            slotHeight = renderHeight
            slotPitch = pitch
            sourceSize = CGSize(width: inputWidth, height: inputHeight)
            pixelBufferPool = nil
            pixelBufferPoolWidth = 0
            pixelBufferPoolHeight = 0
            formatDescription = nil
            hasEnqueuedFrame = false
        }
        stateLock.unlock()

        return CUnsignedInt(slots.count)
    }

    fileprivate func lockFrame(planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
        stateLock.lock()
        guard !slots.isEmpty else {
            stateLock.unlock()
            emitDebugEvent("lock without slots")
            return nil
        }
        let slot = slots[nextSlotIndex]
        nextSlotIndex = (nextSlotIndex + 1) % slots.count
        let bytes = slot.bytes
        stateLock.unlock()

        planes?[0] = bytes
        emitDebugEvent("lock frame")
        return Unmanaged.passUnretained(slot).toOpaque()
    }

    fileprivate func displayFrame(pointer: UnsafeMutableRawPointer?) {
        guard let pointer else {
            emitDebugEvent("display nil picture")
            return
        }
        emitDebugEvent("display frame")
        let slot = Unmanaged<VideoFrameSlot>.fromOpaque(pointer).takeUnretainedValue()

        stateLock.lock()
        let width = slotWidth
        let height = slotHeight
        let pitch = slotPitch
        let currentSourceSize = sourceSize
        stateLock.unlock()

        guard width > 0, height > 0, pitch > 0 else {
            emitDebugEvent("display invalid format")
            return
        }
        guard let pixelBuffer = makePixelBuffer(width: width, height: height) else {
            emitDebugEvent("display pixel buffer failed")
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let destination = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let destinationPitch = CVPixelBufferGetBytesPerRow(pixelBuffer)
            if destinationPitch == pitch {
                destination.copyMemory(from: slot.bytes, byteCount: pitch * height)
            } else {
                for row in 0..<height {
                    let sourceRow = slot.bytes.advanced(by: row * pitch)
                    let destinationRow = destination.advanced(by: row * destinationPitch)
                    destinationRow.copyMemory(from: sourceRow, byteCount: min(pitch, destinationPitch))
                }
            }
            drawSubtitleOverlayIfNeeded(
                into: destination,
                width: width,
                height: height,
                bytesPerRow: destinationPitch,
                sourceSize: currentSourceSize
            )
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        enqueue(pixelBuffer: pixelBuffer)
    }

    fileprivate func cleanupFormat() {
        reset(removingDisplayedImage: false)
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        stateLock.lock()
        let needsPool = pixelBufferPool == nil || pixelBufferPoolWidth != width || pixelBufferPoolHeight != height
        stateLock.unlock()

        if needsPool {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!
            ]
            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 4
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)

            stateLock.lock()
            pixelBufferPool = pool
            pixelBufferPoolWidth = width
            pixelBufferPoolHeight = height
            formatDescription = nil
            stateLock.unlock()
        }

        var pixelBuffer: CVPixelBuffer?
        stateLock.lock()
        let pool = pixelBufferPool
        stateLock.unlock()

        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        }
        return pixelBuffer
    }

    private func enqueue(pixelBuffer: CVPixelBuffer) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        stateLock.lock()
        let needsDescription = formatDescription == nil
            || CMVideoFormatDescriptionGetDimensions(formatDescription!).width != width
            || CMVideoFormatDescriptionGetDimensions(formatDescription!).height != height
            || CMFormatDescriptionGetMediaSubType(formatDescription!) != pixelFormat
        stateLock.unlock()

        if needsDescription {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            stateLock.lock()
            formatDescription = description
            stateLock.unlock()
        }

        stateLock.lock()
        guard let description = formatDescription else {
            stateLock.unlock()
            return
        }
        frameCounter += 1
        let fallbackTime = Double(frameCounter) / preferredFramesPerSecond
        stateLock.unlock()

        let mediaTime = playbackTimeProvider?() ?? fallbackTime
        let presentationTime = CMTime(seconds: mediaTime.isFinite ? max(0, mediaTime) : fallbackTime, preferredTimescale: 1000)
        let frameDuration = CMTime(seconds: 1.0 / preferredFramesPerSecond, preferredTimescale: 1000)
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard result == noErr, let sampleBuffer else {
            emitDebugEvent("enqueue sample create failed result=\(result)")
            return
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        enqueueQueue.async { [weak self, displayLayer] in
            guard let self else { return }

            self.stateLock.lock()
            let hasDisplayedAtLeastOneFrame = self.hasEnqueuedFrame
            self.stateLock.unlock()

            guard !hasDisplayedAtLeastOneFrame || displayLayer.isReadyForMoreMediaData else {
                self.emitDebugEvent("enqueue dropped not ready")
                return
            }

            if displayLayer.controlTimebase == nil {
                var newTimebase: CMTimebase?
                if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &newTimebase) == noErr,
                   let newTimebase {
                    CMTimebaseSetTime(newTimebase, time: presentationTime)
                    CMTimebaseSetRate(newTimebase, rate: 1.0)
                    displayLayer.controlTimebase = newTimebase
                    self.stateLock.lock()
                    self.timebase = newTimebase
                    self.stateLock.unlock()
                }
            } else if let timebase = displayLayer.controlTimebase {
                CMTimebaseSetRate(timebase, rate: 1.0)
            }

            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer)
            self.emitDebugEvent("enqueue sample status=\(displayLayer.status.rawValue)")
            self.stateLock.lock()
            self.hasEnqueuedFrame = true
            let shouldNotifyFirstFrame = !self.didNotifyFirstFrame
            if shouldNotifyFirstFrame {
                self.didNotifyFirstFrame = true
            }
            self.stateLock.unlock()

            if shouldNotifyFirstFrame {
                self.onFirstFrameEnqueued?()
            }
            self.onFrameEnqueued?()
        }
    }

    private func drawSubtitleOverlayIfNeeded(
        into baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        sourceSize: CGSize
    ) {
        let mediaTime = playbackTimeProvider?() ?? 0
        let request = VLCKitSPMSubtitleOverlayRequest(
            presentationTime: mediaTime,
            sourceSize: sourceSize,
            renderSize: CGSize(width: width, height: height)
        )
        guard let attributedText = subtitleOverlayProvider?(request), attributedText.length > 0 else {
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return
        }

        let maxTextWidth = CGFloat(width) * 0.86
        let bounding = attributedText.boundingRect(
            with: CGSize(width: maxTextWidth, height: CGFloat(height) * 0.35),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textHeight = ceil(bounding.height)
        let horizontalInset = (CGFloat(width) - maxTextWidth) / 2
        let bottomInset = max(CGFloat(height) * 0.08, 24)
        let textRect = CGRect(
            x: horizontalInset,
            y: CGFloat(height) - bottomInset - textHeight,
            width: maxTextWidth,
            height: textHeight + 8
        )

        UIGraphicsPushContext(context)
        attributedText.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
    }

    private static func renderSize(for sourceSize: CGSize, cappedBy cap: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: 640, height: 360)
        }
        let maxWidth = cap.width > 0 ? cap.width : sourceSize.width
        let maxHeight = cap.height > 0 ? cap.height : sourceSize.height
        let scale = min(maxWidth / sourceSize.width, maxHeight / sourceSize.height, 1.0)
        return CGSize(width: floor(sourceSize.width * scale), height: floor(sourceSize.height * scale))
    }
}

@available(iOS 15.0, *)
public protocol VLCKitSPMPictureInPictureControllerDelegate: AnyObject {
    func pictureInPictureControllerWillStart(_ controller: VLCKitSPMPictureInPictureController)
    func pictureInPictureControllerDidStart(_ controller: VLCKitSPMPictureInPictureController)
    func pictureInPictureController(_ controller: VLCKitSPMPictureInPictureController, failedToStart error: Error)
    func pictureInPictureControllerWillStop(_ controller: VLCKitSPMPictureInPictureController)
    func pictureInPictureControllerDidStop(_ controller: VLCKitSPMPictureInPictureController)
    func pictureInPictureController(_ controller: VLCKitSPMPictureInPictureController, restoreUserInterface completionHandler: @escaping (Bool) -> Void)
    func pictureInPictureControllerPlay(_ controller: VLCKitSPMPictureInPictureController)
    func pictureInPictureControllerPause(_ controller: VLCKitSPMPictureInPictureController)
    func pictureInPictureController(_ controller: VLCKitSPMPictureInPictureController, skipByInterval interval: CMTime)
    func pictureInPictureControllerIsPlaying(_ controller: VLCKitSPMPictureInPictureController) -> Bool
    func pictureInPictureControllerDuration(_ controller: VLCKitSPMPictureInPictureController) -> TimeInterval
    func pictureInPictureControllerCurrentTime(_ controller: VLCKitSPMPictureInPictureController) -> TimeInterval
}

@available(iOS 15.0, *)
public extension VLCKitSPMPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStart(_ controller: VLCKitSPMPictureInPictureController) {}
    func pictureInPictureControllerDidStart(_ controller: VLCKitSPMPictureInPictureController) {}
    func pictureInPictureController(_ controller: VLCKitSPMPictureInPictureController, failedToStart error: Error) {}
    func pictureInPictureControllerWillStop(_ controller: VLCKitSPMPictureInPictureController) {}
    func pictureInPictureControllerDidStop(_ controller: VLCKitSPMPictureInPictureController) {}
    func pictureInPictureController(_ controller: VLCKitSPMPictureInPictureController, restoreUserInterface completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
    func pictureInPictureControllerPlay(_ controller: VLCKitSPMPictureInPictureController) {}
    func pictureInPictureControllerPause(_ controller: VLCKitSPMPictureInPictureController) {}
    func pictureInPictureController(_ controller: VLCKitSPMPictureInPictureController, skipByInterval interval: CMTime) {}
    func pictureInPictureControllerIsPlaying(_ controller: VLCKitSPMPictureInPictureController) -> Bool { true }
    func pictureInPictureControllerDuration(_ controller: VLCKitSPMPictureInPictureController) -> TimeInterval { 0 }
    func pictureInPictureControllerCurrentTime(_ controller: VLCKitSPMPictureInPictureController) -> TimeInterval { 0 }
}

@available(iOS 15.0, *)
public final class VLCKitSPMPictureInPictureController: NSObject {
    public weak var delegate: VLCKitSPMPictureInPictureControllerDelegate?

    public static var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    public var isPictureInPictureSupported: Bool {
        Self.isPictureInPictureSupported
    }

    public var isPictureInPicturePossible: Bool {
        controller?.isPictureInPicturePossible ?? false
    }

    public var isPictureInPictureActive: Bool {
        controller?.isPictureInPictureActive ?? false
    }

    private var controller: AVPictureInPictureController?
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    public init(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = sampleBufferDisplayLayer
        super.init()
        guard Self.isPictureInPictureSupported else { return }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.requiresLinearPlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller
    }

    @discardableResult
    public func startPictureInPicture() -> Bool {
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else {
            return false
        }
        controller.invalidatePlaybackState()
        controller.startPictureInPicture()
        return true
    }

    public func stopPictureInPicture() {
        controller?.stopPictureInPicture()
    }

    public func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    private func sanitizedPlaybackTimes() -> (current: TimeInterval, duration: TimeInterval) {
        let rawCurrent = delegate?.pictureInPictureControllerCurrentTime(self) ?? 0
        let rawDuration = delegate?.pictureInPictureControllerDuration(self) ?? 0
        let current = rawCurrent.isFinite ? max(0, rawCurrent) : 0
        let durationIsUsable = rawDuration.isFinite && rawDuration > max(5, current + 1)
        let duration = durationIsUsable ? rawDuration : max(600, current + 600)
        return (min(current, max(0, duration - 0.5)), duration)
    }
}

@available(iOS 15.0, *)
extension VLCKitSPMPictureInPictureController: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        delegate?.pictureInPictureControllerWillStart(self)
    }

    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        delegate?.pictureInPictureControllerDidStart(self)
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        delegate?.pictureInPictureController(self, failedToStart: error)
    }

    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        delegate?.pictureInPictureControllerWillStop(self)
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        delegate?.pictureInPictureControllerDidStop(self)
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        delegate?.pictureInPictureController(self, restoreUserInterface: completionHandler)
    }
}

@available(iOS 15.0, *)
extension VLCKitSPMPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            delegate?.pictureInPictureControllerPlay(self)
        } else {
            delegate?.pictureInPictureControllerPause(self)
        }
        pictureInPictureController.invalidatePlaybackState()
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        delegate?.pictureInPictureController(self, skipByInterval: skipInterval)
        pictureInPictureController.invalidatePlaybackState()
        completionHandler()
    }

    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !(delegate?.pictureInPictureControllerIsPlaying(self) ?? true)
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let times = sanitizedPlaybackTimes()
        return CMTimeRange(start: .zero, duration: CMTime(seconds: times.duration, preferredTimescale: 1000))
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool, completion: @escaping () -> Void) {
        if playing {
            delegate?.pictureInPictureControllerPlay(self)
        } else {
            delegate?.pictureInPictureControllerPause(self)
        }
        pictureInPictureController.invalidatePlaybackState()
        completion()
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, timeRangeForPlayback sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) -> CMTimeRange {
        let times = sanitizedPlaybackTimes()
        return CMTimeRange(start: .zero, duration: CMTime(seconds: times.duration, preferredTimescale: 1000))
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, currentTimeFor sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) -> CMTime {
        let times = sanitizedPlaybackTimes()
        return CMTime(seconds: times.current, preferredTimescale: 1000)
    }
}

@available(iOS 15.0, *)
private final class VLCKitSPMActiveVideoOutputRegistry: @unchecked Sendable {
    static let shared = VLCKitSPMActiveVideoOutputRegistry()

    private let lock = NSLock()
    private var latestOpaque: UnsafeMutableRawPointer?

    func register(_ opaque: UnsafeMutableRawPointer) {
        lock.lock()
        latestOpaque = opaque
        lock.unlock()
    }

    func unregister(_ opaque: UnsafeMutableRawPointer) {
        lock.lock()
        if latestOpaque == opaque {
            latestOpaque = nil
        }
        lock.unlock()
    }

    func fallbackOpaque() -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        return latestOpaque
    }
}

@available(iOS 15.0, *)
private final class VideoFrameSlot {
    let bytes: UnsafeMutableRawPointer

    init(byteCount: Int) {
        bytes = UnsafeMutableRawPointer.allocate(byteCount: max(1, byteCount), alignment: 64)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: max(1, byteCount))
    }

    deinit {
        bytes.deallocate()
    }
}

@available(iOS 15.0, *)
private let vlcSPMVideoLockCallback: VLCKitSPMVideoLockCallback = { opaque, planes in
    guard let opaque else { return nil }
    return Unmanaged<VLCKitSPMSampleBufferVideoOutput>.fromOpaque(opaque).takeUnretainedValue().lockFrame(planes: planes)
}

@available(iOS 15.0, *)
private let vlcSPMVideoUnlockCallback: VLCKitSPMVideoUnlockCallback = { _, _, _ in
}

@available(iOS 15.0, *)
private let vlcSPMVideoDisplayCallback: VLCKitSPMVideoDisplayCallback = { opaque, picture in
    guard let opaque else { return }
    Unmanaged<VLCKitSPMSampleBufferVideoOutput>.fromOpaque(opaque).takeUnretainedValue().displayFrame(pointer: picture)
}

@available(iOS 15.0, *)
private let vlcSPMVideoFormatCallback: VLCKitSPMVideoFormatCallback = { opaque, chroma, width, height, pitches, lines in
    let currentOpaque = opaque.pointee ?? VLCKitSPMActiveVideoOutputRegistry.shared.fallbackOpaque()
    guard let currentOpaque else { return 0 }
    if opaque.pointee == nil {
        opaque.pointee = currentOpaque
    }
    return Unmanaged<VLCKitSPMSampleBufferVideoOutput>.fromOpaque(currentOpaque).takeUnretainedValue().configureFormat(
        opaque: opaque,
        chroma: chroma,
        width: width,
        height: height,
        pitches: pitches,
        lines: lines
    )
}

@available(iOS 15.0, *)
private let vlcSPMVideoCleanupCallback: VLCKitSPMVideoCleanupCallback = { opaque in
    guard let opaque else { return }
    Unmanaged<VLCKitSPMSampleBufferVideoOutput>.fromOpaque(opaque).takeUnretainedValue().cleanupFormat()
}
#endif
