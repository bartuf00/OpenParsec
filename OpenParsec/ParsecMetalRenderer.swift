import MetalKit
import ParsecSDK
import OSLog

import SwiftUI
import UIKit


class ParsecMetalRenderer: NSObject, MTKViewDelegate {
    weak var mtkView: MTKView?
    var updateImage: (() -> Void)?

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    private var lastWidth: CGFloat = 1.0
    private var lastHeight: CGFloat = 1.0

    // 主NV12 Texture
    private var yTexture: MTLTexture?
    private var uvTexture: MTLTexture?
    private var textTexture: MTLTexture?

    var textDebugImage: UIImage?


    // 畫字 分辨Metal用 
    // MARK: 建立文字貼圖 (同時回傳 UIImage 方便 debug)
    func makeTextTexture(device: MTLDevice,
                        text: String,
                        size: CGSize = CGSize(width: 256, height: 64)) -> (MTLTexture?, UIImage?) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = Int(size.width) * 4

        // Metal 的 .bgra8Unorm 對應 BGRA + little endian + alpha 在前
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(data: nil,
                                    width: Int(size.width),
                                    height: Int(size.height),
                                    bitsPerComponent: 8,
                                    bytesPerRow: bytesPerRow,
                                    space: colorSpace,
                                    bitmapInfo: bitmapInfo)
        else { return (nil, nil) }

        // 背景透明（方便 debug）
        context.setFillColor(UIColor.clear.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        // 畫字
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .heavy),
            .foregroundColor: UIColor.red
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let drawRect = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
        UIGraphicsPushContext(context)
        attrString.draw(in: drawRect)
        UIGraphicsPopContext()
        

        // 建立 Metal Texture
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        textureDesc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: textureDesc) else { return (nil, nil) }

        let region = MTLRegionMake2D(0, 0, Int(size.width), Int(size.height))
        let data = context.data!
        texture.replace(region: region,
                        mipmapLevel: 0,
                        withBytes: data,
                        bytesPerRow: bytesPerRow)

        // Debug: 轉成 UIImage 檢查字有沒有畫上去
        var debugImage: UIImage? = nil
        if let cgImage = context.makeImage() {
            debugImage = UIImage(cgImage: cgImage)
        }

        return (texture, debugImage)
    }








    init(_ view: MTKView, updateImage: @escaping () -> Void) {
        self.mtkView = view
        self.updateImage = updateImage
        super.init()


        guard let device = view.device else { fatalError("Metal device not found") }
        commandQueue = device.makeCommandQueue()


        let (textTex, debugImage) = makeTextTexture(device: device, text: "Metal Testing")

        if let img = debugImage {
            // 在 UIImageView 顯示，確認字有沒有畫上去
            self.textDebugImage = img

        }
        self.textTexture = textTex
        

        // 建立簡單的 passthrough pipeline
        if let library = device.makeDefaultLibrary(),
           let vertexFunc = library.makeFunction(name: "vertexPassthrough"),
           let fragmentFunc = library.makeFunction(name: "fragmentNV12") {

            let pipelineDesc = MTLRenderPipelineDescriptor()
            pipelineDesc.vertexFunction = vertexFunc
            pipelineDesc.fragmentFunction = fragmentFunc
            pipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat

            pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDesc)
        }

        view.delegate = self
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
    }

    // PollFrame → 取得最新畫面
    func pollFrame() {
        let status = CParsec.renderMetalFrame(
            timeout: 16,
            ) { frame, image in
            self.handleFrame(frame, image: image)
            
            

        }
        print("PollFrame status:", status)
    }


    // 把 ParsecFrame + image buffer 複製到 Metal Texture
    private func handleFrame(_ frame: ParsecFrame, image: UnsafeRawPointer) {
        let width = Int(frame.width)
        let height = Int(frame.height)

        guard let device = mtkView?.device else { return }

        // Y 平面大小 = width * height
        let ySize = width * height
        let yPtr = image
        let uvPtr = image.advanced(by: ySize)

        // 建立 Y texture
        let yDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        yDesc.usage = [.shaderRead]
        yTexture = device.makeTexture(descriptor: yDesc)
        yTexture?.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: yPtr,
                        bytesPerRow: width)

        // 建立 UV texture (寬高各減半)
        let uvDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm,
            width: width / 2,
            height: height / 2,
            mipmapped: false
        )
        uvDesc.usage = [.shaderRead]
        uvTexture = device.makeTexture(descriptor: uvDesc)
        uvTexture?.replace(region: MTLRegionMake2D(0, 0, width / 2, height / 2),
                        mipmapLevel: 0,
                        withBytes: uvPtr,
                        bytesPerRow: width)
    }


    

    // MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastWidth = size.width
        lastHeight = size.height
        CParsec.setFrame(size.width, size.height, view.contentScaleFactor)
    }


    var framesDisplayedCounter: Int = 0

    func draw(in view: MTKView) {
        pollFrame()

        guard let drawable = view.currentDrawable,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let renderPass = view.currentRenderPassDescriptor,
            let pipelineState,
            let yTex = yTexture,
            let uvTex = uvTexture,
            let textTex = textTexture else { return }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
        encoder.setRenderPipelineState(pipelineState)

        // 傳入 viewSize 給頂點着色器
        var viewSize = SIMD2<Float>(Float(view.drawableSize.width),
                                    Float(view.drawableSize.height))
        let viewSizeBuffer = view.device!.makeBuffer(bytes: &viewSize,
                                                        length: MemoryLayout<SIMD2<Float>>.stride,
                                                        options: [])
        encoder.setVertexBuffer(viewSizeBuffer, offset: 0, index: 0)

        // 主螢幕不翻轉
        var flip: UInt32 = 0
        let flipBuffer = view.device!.makeBuffer(bytes: &flip,
                                                 length: MemoryLayout<UInt32>.stride,
                                                 options: [])
        encoder.setVertexBuffer(flipBuffer, offset: 0, index: 1)

        var showText: UInt32 = SettingsHandler.shared.MetalText ? 1 : 0

        let showTextBuffer = view.device!.makeBuffer(bytes: &showText,
                                                        length: MemoryLayout<UInt32>.stride,
                                                        options: [])
        encoder.setFragmentBuffer(showTextBuffer, offset: 0, index: 1)



        // 綁定 NV12 的兩個平面 + overlay
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.setFragmentTexture(textTex, index: 2) // Metal Test overlay

        // 畫全螢幕 quad
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.endEncoding()

        if #available(iOS 15.0, *) {
            if let pipTex = PictureInPictureManager.shared.metalCaptureTexture() {
                let pipPass = MTLRenderPassDescriptor()
                pipPass.colorAttachments[0].texture = pipTex
                pipPass.colorAttachments[0].loadAction = .clear
                pipPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                pipPass.colorAttachments[0].storeAction = .store

                if let pipEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pipPass) {
                    pipEncoder.setRenderPipelineState(pipelineState)

                    var pipSize = SIMD2<Float>(Float(pipTex.width), Float(pipTex.height))
                    let pipSizeBuffer = view.device!.makeBuffer(bytes: &pipSize,
                                                                length: MemoryLayout<SIMD2<Float>>.stride,
                                                                options: [])
                    pipEncoder.setVertexBuffer(pipSizeBuffer, offset: 0, index: 0)

                    // PiP 需要垂直翻轉（AVSampleBufferDisplayLayer 是左上原點）
                    var pipFlip: UInt32 = 1
                    let pipFlipBuffer = view.device!.makeBuffer(bytes: &pipFlip,
                                                                length: MemoryLayout<UInt32>.stride,
                                                                options: [])
                    pipEncoder.setVertexBuffer(pipFlipBuffer, offset: 0, index: 1)

                    pipEncoder.setFragmentBuffer(showTextBuffer, offset: 0, index: 1)
                    pipEncoder.setFragmentTexture(yTex, index: 0)
                    pipEncoder.setFragmentTexture(uvTex, index: 1)
                    pipEncoder.setFragmentTexture(textTex, index: 2)

                    pipEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    pipEncoder.endEncoding()
                }
            }
        }

        commandBuffer.present(drawable)

        commandBuffer.addCompletedHandler { [self] _ in
            self.framesDisplayedCounter += 1

        }
        commandBuffer.commit()


        

        updateImage?()
    }

    func cleanUp() {
        if let view = mtkView, (view.delegate as AnyObject?) === self {
            view.delegate = nil
        }

        mtkView?.isPaused = true
        updateImage = nil
        yTexture = nil
        uvTexture = nil
        textTexture = nil
        textDebugImage = nil
        pipelineState = nil
        commandQueue = nil
    }

    deinit {
        cleanUp()
    }

}





//
//class ParsecMetalRenderer: NSObject, MTKViewDelegate {
//	var mtkView: MTKView
//	var updateImage: () -> Void
//
//	// Metal pipeline
//	private var commandQueue: MTLCommandQueue!
//	private var pipelineState: MTLRenderPipelineState!
//
//	// 紀錄尺寸
//	private var lastWidth: CGFloat = 1.0
//	private var lastHeight: CGFloat = 1.0
//
//	init(_ view: MTKView, updateImage: @escaping () -> Void) {
//		self.mtkView = view
//		self.updateImage = updateImage
//		super.init()
//
//		guard let device = view.device else { fatalError("Metal device not found") }
//
//		// 1️⃣ 建立 CommandQueue
//		commandQueue = device.makeCommandQueue()
//
//		// 2️⃣ 建立簡單 Pipeline (Passthrough shader)
//		if let library = device.makeDefaultLibrary(),
//		   let vertexFunc = library.makeFunction(name: "vertexPassthrough"),
//		   let fragmentFunc = library.makeFunction(name: "fragmentPassthrough") {
//
//			let pipelineDesc = MTLRenderPipelineDescriptor()
//			pipelineDesc.vertexFunction = vertexFunc
//			pipelineDesc.fragmentFunction = fragmentFunc
//			pipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
//
//			do {
//				pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
//			} catch {
//				fatalError("Failed to create pipeline state: \(error)")
//			}
//		} else {
//			fatalError("Failed to load default Metal library or functions")
//		}
//
//		// 3️⃣ MTKView 設置
//		view.delegate = self
//		view.enableSetNeedsDisplay = false
//		view.isPaused = false
//		view.framebufferOnly = false
//		view.colorPixelFormat = .bgra8Unorm
//	}
//
//	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
//		lastWidth = size.width
//		lastHeight = size.height
//		CParsec.setFrame(size.width, size.height, view.contentScaleFactor)
//	}
//
//	func draw(in view: MTKView) {
//		let newWidth = view.drawableSize.width
//		let newHeight = view.drawableSize.height
//
//		// 1️⃣ 更新尺寸
//		if newWidth != lastWidth || newHeight != lastHeight {
//			CParsec.setFrame(newWidth, newHeight, view.contentScaleFactor)
//			lastWidth = newWidth
//			lastHeight = newHeight
//		}
//
//		guard let drawable = view.currentDrawable else { return }
//
//		// 2️⃣ 用 Parsec render 到 drawable.texture
//		CParsec.renderMetalFrame(queue: commandQueue, drawable: drawable)
//
//		// 3️⃣ 用 pipeline 把 texture 畫到 screen
//		guard let renderPass = view.currentRenderPassDescriptor,
//			  let commandBuffer = commandQueue.makeCommandBuffer() else { return }
//
//		let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
//		encoder.setRenderPipelineState(pipelineState)
//		encoder.setFragmentTexture(drawable.texture, index: 0)
//		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
//		encoder.endEncoding()
//
//		commandBuffer.present(drawable)
//		commandBuffer.commit()
//
//		// 4️⃣ 通知 wrapper frame 已完成
//		if let wrapper = mtkView.delegate as? ParsecMetalViewControllerWrapper {
//			wrapper.drawFrameCompleted()
//		}
//
//		// 5️⃣ callback
//		updateImage()
//	}
//}


//class ParsecMetalRendererold: NSObject, MTKViewDelegate {
//    var mtkView: MTKView
//    var updateImage: () -> Void
//    var lastWidth: CGFloat = 1.0
//	var lastHeight: CGFloat = 1.0
//
//
//	// Metal pipeline
//	var commandQueue: MTLCommandQueue!
//	var pipelineState: MTLRenderPipelineState!
//
//
//
//
//    init(_ view: MTKView, updateImage: @escaping () -> Void) {
//
//
//		self.mtkView = view
//        self.updateImage = updateImage
//
//		super.init()
//
//		guard let device = view.device else { fatalError("Metal device not found") }
//		commandQueue = device.makeCommandQueue()
//
//		// 建立簡單 pipeline，把 texture 畫到 screen
//		let library = device.makeDefaultLibrary()
//		let vertexFunc = library?.makeFunction(name: "vertexPassthrough")
//		let fragmentFunc = library?.makeFunction(name: "fragmentPassthrough")
//
//		let pipelineDesc = MTLRenderPipelineDescriptor()
//		pipelineDesc.vertexFunction = vertexFunc
//		pipelineDesc.fragmentFunction = fragmentFunc
//		pipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
//
//		pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDesc)
//
//
//
//        view.delegate = self
//
//
//
//
//
//    }
//    
//	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
//		CParsec.setFrame(size.width, size.height, view.contentScaleFactor)
//
//		lastWidth = size.width
//		lastHeight = size.height
//
//
//	}
//
//
//
//	func draw(in view: MTKView) {
//		let newWidth = view.drawableSize.width
//		let newHeight = view.drawableSize.height
//
//		if newWidth != lastWidth || newHeight != lastHeight {
//			CParsec.setFrame(newWidth, newHeight, view.contentScaleFactor)
//			lastWidth = newWidth
//			lastHeight = newHeight
//		}
//
//		guard let drawable = view.currentDrawable else { return }
//
//		CParsec.renderMetalFrame(
//			queue: commandQueue, drawable: drawable
//		)
//
//		drawable.present()
//
//		// 2️⃣ 畫到 screen
////		guard let commandBuffer = commandQueue.makeCommandBuffer(),
////			  let renderPass = view.currentRenderPassDescriptor else {
////			return
////		}
////
////		let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
////		encoder.setRenderPipelineState(pipelineState)
////
////		// 設定 drawable texture
////		encoder.setFragmentTexture(drawable.texture, index: 0)
////
////		// 畫 full screen quad
////		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
////		encoder.endEncoding()
////
////		commandBuffer.present(drawable)
////		commandBuffer.commit()
//
//
//
//
//
//
////		os_log("Drawable texture size: \(drawable.texture.width)x\(drawable.texture.height)")
////		os_log("Drawable pixel format: \(drawable.texture.pixelFormat.rawValue)")
////
//
//
//		if let wrapper = mtkView.delegate as? ParsecMetalViewControllerWrapper {
//			wrapper.drawFrameCompleted()
//		}
//
//		updateImage()
//	}
//
//}


//
//class ParsecMetalRenderer:NSObject, MTKViewDelegate
//{
//	var parent:ParsecMetalViewControllerWrapper
//	var onBeforeRender:() -> Void
//	var metalDevice:MTLDevice!
//	var metalCommandQueue:MTLCommandQueue!
//	var metalTexture:MTLTexture!
//	var metalTexturePtr:UnsafeMutableRawPointer?
//	
//	var lastWidth:CGFloat = 1.0
//
//	init(
//		_ parent:ParsecMetalViewControllerWrapper,
//		_ beforeRender:@escaping () -> Void
//	)
//	{
//		self.parent = parent;
//		onBeforeRender = beforeRender
//		if let metalDevice = MTLCreateSystemDefaultDevice()
//		{
//			self.metalDevice = metalDevice
//		}
//		self.metalCommandQueue = metalDevice.makeCommandQueue()
//		metalTexture = metalDevice.makeTexture(descriptor:MTLTextureDescriptor())
//		metalTexturePtr = createTextureRef(&metalTexture)
//		
//		super.init()
//	}
//	
//	func mtkView(_ view:MTKView, drawableSizeWillChange size:CGSize) { }
//	
//	func draw(in view:MTKView)
//	{
//		onBeforeRender()
//		let deltaWidth: CGFloat = view.frame.size.width - lastWidth
//		if deltaWidth > 0.1 || deltaWidth < -0.1
//		{
//			CParsec.setFrame(view.frame.size.width, view.frame.size.height, view.contentScaleFactor)
//			lastWidth = view.frame.size.width
//		}
//		CParsec.renderMetalFrame(&metalCommandQueue, &metalTexturePtr)
//	}
//}



