
import SwiftUI
import MetalKit
import GLKit

import UIKit
import ParsecSDK

typealias ParsecRenderer =
ParsecPlayground & ParsecRenderController


final class ParsecMetalTarget {
	static let shared = ParsecMetalTarget()

	var cqQueue:MTLCommandQueue?

	var texture: MTLTexture? = nil

	// ⚠️ 給 C SDK 用的 **指標位址**
	let texturePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
		let p = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
		p.initialize(to: nil)
		return p
	}()

	func reset() {
		texture = nil
		cqQueue = nil
		texturePtr.pointee = nil
	}

	deinit {
		texturePtr.deinitialize(count: 1)
		texturePtr.deallocate()
	}
}


// 新的處理方式測試 Metal

final class ParsecMetalViewControllerWrapper: NSObject, ParsecPlayground,ParsecRenderController, MTKViewDelegate {

    // MARK: - Properties

	private var settings = SettingsHandler.shared
    

    var viewController: UIViewController

    var mtkView: MTKView!

	var updateImage: (() -> Void)?

    private var metalDevice: MTLDevice!
    private var renderer: ParsecMetalRenderer?

	// MARK: - ParsecRenderController Metal FPS
	var view: UIView {
		get { mtkView }
		set { mtkView = newValue as? MTKView }
	}

	

	var preferredFPS: Int {
        get { mtkView?.preferredFramesPerSecond ?? 0 }
        set { mtkView?.preferredFramesPerSecond = newValue }
    }


	var _debugMES: String = ""   // 真正存值的變數

	var DebugMes: String {
		get { _debugMES }
		set { _debugMES = newValue }
	}

	func getFramesDisplayed() -> Int {
		let RES = renderer?.framesDisplayedCounter ?? 0

		ParsecRenderCenter.shared.Update_DebugMes("MetalFPS:\(RES)")

		return RES 
	}


	

    private var lastWidth: CGFloat = 1.0
    private var lastHeight: CGFloat = 1.0

    // MARK: - Init
    required init(viewController: UIViewController, updateImage: @escaping () -> Void) {
        self.viewController = viewController
        self.updateImage = updateImage
        super.init()

        metalDevice = MTLCreateSystemDefaultDevice()
    }

    var renderView: UIView { mtkView }

	var renderViewIfLoaded: UIView? { mtkView }

	var MetalProvider: CaptureSurfaceProvider?

    // MARK: - Setup
    func loadViewIfNeeded() {
		guard mtkView == nil else { return }

        mtkView = MTKView(frame: viewController.view.bounds)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.device = metalDevice
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.framebufferOnly = false
        mtkView.backgroundColor = .red



		// Use configured FPS or device max (for ProMotion displays)
		let fps = settings.preferredFramesPerSecond

		
		if fps == 0 {
			// Use device's maximum refresh rate (120Hz on ProMotion iPads)
			mtkView.preferredFramesPerSecond = Int(UIScreen.main.maximumFramesPerSecond)
		} else {
			mtkView.preferredFramesPerSecond = fps
		}


        viewController.view.addSubview(mtkView)

        // 初始化新的 PollFrame Renderer
        renderer = ParsecMetalRenderer(mtkView, updateImage: updateImage ?? {})

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let mtkView = self.mtkView else { return }
            mtkView.contentScaleFactor = viewController.view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        }


		if #available(iOS 15.0, *) {
			if SettingsHandler.shared.enablePiP {

				MetalProvider = MetalCaptureSurfaceProvider(device: metalDevice)

				if let metalProvider = MetalProvider {
					// 用 drawableSize (pixels) 而非 frame (points)
					let pipWidth = Int(mtkView.drawableSize.width)
					let pipHeight = Int(mtkView.drawableSize.height)
					metalProvider.setup(width: pipWidth, height: pipHeight)
			

					write_log_from_swift("Attempting PiP setup Metal🍫 (texture: \(pipWidth)x\(pipHeight))")
					// ✅ 在這裡加上 PiP setup
					if let mtkView = self.mtkView {
						PictureInPictureManager.shared.setup(
							sourceView: mtkView,
							provider: metalProvider // 你自己的 CaptureSurfaceProvider
						)
					}
					
					write_log_from_swift("Metal PiP setup complete🍫")

				}

			}
		}

        ParsecMetalViewControllerWrapper.sharedWrapper = self
    }

    func updateSize(width: CGFloat, height: CGFloat) {
        guard let view = mtkView else { return }
        let deltaW = abs(width - lastWidth)
        let deltaH = abs(height - lastHeight)
        if deltaW > 1 || deltaH > 1 {
            lastWidth = width
            lastHeight = height
            DispatchQueue.main.async {
                CParsec.setFrame(width, height, view.contentScaleFactor)
                print("SCALE", view.contentScaleFactor)
                print("Width:\(width)x\(height)")
            }
        }
    }

    

    // MARK: - MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 可以在這裡更新尺寸
    }

    func draw(in view: MTKView) {
        renderer?.draw(in: view)
        
    }

    // MARK: - Clean
    func cleanUp() {
		print("🧹 Metal cleanUp start")

		renderer?.cleanUp()
		renderer = nil
		updateImage = nil

		mtkView?.isPaused = true
		mtkView?.enableSetNeedsDisplay = true
		mtkView?.delegate = nil
        mtkView?.removeFromSuperview()
        mtkView = nil

		if ParsecMetalViewControllerWrapper.sharedWrapper === self {
			ParsecMetalViewControllerWrapper.sharedWrapper = nil
		}

		ParsecMetalTarget.shared.reset()

		MetalProvider = nil

		print("🧹 Metal cleanUp done")
    }

	deinit {
		cleanUp()
	}

    // MARK: - Shared
    static var sharedWrapper: ParsecMetalViewControllerWrapper?
}




//
//class ParsecMetalViewControllerWrapper: NSObject, ParsecPlayground, ParsecRenderController, MTKViewDelegate {
//
//	// MARK: - Properties
//	let viewController: UIViewController
//	var mtkView: MTKView!
//	var preferredFPS: Int = 60 {
//		didSet { mtkView?.preferredFramesPerSecond = preferredFPS }
//	}
//	var updateImage: () -> Void
//	private var framesDisplayedCounter = 0
//
//
//
//	private var commandQueue: MTLCommandQueue!
//
//
//	var renderView: UIView {
//			mtkView
//	}
//
//
//
//	var lastWidth:CGFloat = 1.0
//	var lastHeight:CGFloat = 1.0
//
//	func setupParsecHolder(queue: MTLCommandQueue?, texture: MTLTexture?) {
//		guard let queue = queue, let texture = texture else {
//			print("❌ queue or texture is nil")
//			return
//		}
//
//		// 強引用
//		ParsecMetalHolder.commandQueue = queue
//		ParsecMetalHolder.texture = texture
//
//		ParsecMetalHolder.commandQueuePtr = Unmanaged.passUnretained(queue).toOpaque()
//
//
//		// ⚡ 這裡必須 cast 成 ParsecMetalTexture
//		ParsecMetalHolder.texPtrHolder.pointee = Unmanaged.passUnretained(texture).toOpaque()
//	}
//
//	
//
//	// MARK: - Init
//	required init(viewController: UIViewController, updateImage: @escaping () -> Void) {
//		self.viewController = viewController
//		self.updateImage = updateImage
//		super.init()
//	}
//
////	private func createParsecTargetTexture(size: CGSize) {
////		let desc = MTLTextureDescriptor.texture2DDescriptor(
////			pixelFormat: .bgra8Unorm,
////			width: Int(size.width),
////			height: Int(size.height),
////			mipmapped: false
////		)
////		desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
////		desc.storageMode = .private
////
////		renderTargetTexture = mtkView.device!.makeTexture(descriptor: desc)
////
////	}
//
//
//	// MARK: - ParsecPlayground
//	func loadViewIfNeeded() {
//		mtkView = MTKView(frame: viewController.view.bounds)
//
//		mtkView.device = MTLCreateSystemDefaultDevice()
//
//		guard let device = mtkView.device else {
//			fatalError("❌ Metal device not available!")
//		}
//		print("✅ Metal device available:", device)
//
//
//		mtkView.isPaused = false
//		mtkView.enableSetNeedsDisplay = false
//		mtkView.framebufferOnly = false
//
//		mtkView.isHidden = false
//		mtkView.backgroundColor = .red // 先給個底色確認有沒有被加到視圖層
//
//		mtkView.preferredFramesPerSecond = preferredFPS
//
//
//		// 設置 MTKView Delegate
//		mtkView.delegate = self
//
//
//		// 建立 CommandQueue
//		commandQueue = mtkView.device!.makeCommandQueue()
//
//		// 4. 加入父 view
//
//		viewController.view.addSubview(mtkView)
//
//
//		
//
//		DispatchQueue.main.async { [weak self] in
//			guard let self = self else { return }
//			self.mtkView.contentScaleFactor = self.viewController.view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
//			print("✅ MTKView scale set to", self.mtkView.contentScaleFactor)
//		}
//
//		// ⚡ 設定靜態 sharedWrapper
//		ParsecMetalViewControllerWrapper.sharedWrapper = self
//
//
//
//
//
//	}
//
//
//
//	func cleanUp() {
//		mtkView?.removeFromSuperview()
//		mtkView = nil
//	}
//
//	func updateSize(width: CGFloat, height: CGFloat) {
//
//		guard let mtkView = mtkView else {
//			// renderer 還沒 load view，不要動
//			return
//		}
//		mtkView.drawableSize = CGSize(width: width, height: height)
//
//
//		CParsec.setFrame(width, height, mtkView.contentScaleFactor)
//	}
//
//	// MARK: - ParsecRenderController
//	func drawFrameCompleted() { framesDisplayedCounter += 1 }
//	func getFramesDisplayed() -> Int { framesDisplayedCounter }
//
//	// MARK: - MTKViewDelegate
//	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
//
//		let scale = view.contentScaleFactor
//
//		let w = size.width  / view.contentScaleFactor
//		let h = size.height / view.contentScaleFactor
//
//		CParsec.setFrame(w, h, scale)
//		print("Scale:\(scale) \(w)x\(h)")
//
//	}
//
//
//
//	// 靜態共享 instance
//	static var sharedWrapper: ParsecMetalViewControllerWrapper?
//
//
//
//	func draw(in view: MTKView) {
//
//		guard
//			let drawable = view.currentDrawable,
//			let commandQueue = commandQueue
//		else { return }
//
//		let texture = drawable.texture
//
//		// 更新 Parsec holder（指標必須長生命週期，你已經做對）
//		setupParsecHolder(queue: commandQueue, texture: texture)
//
//		// ⚡ Parsec 會直接 render 到 drawable.texture
//		let status = CParsec.renderMetalFrame(
//			queue: commandQueue,
//			texture: texture,
//			preRender: nil,
//			opaque: nil,
//			timeout: 16
//		)
//
//		print("Parsec render status:", status)
//
//		// ⚠️ 不要自己再畫、不要 present
//		// MTKView 會在內部 display link 幫你處理
//
//		drawFrameCompleted()
//		updateImage()
//	}
//}

//
//class ParsecMetalViewControllerWrapper : ParsecPlayground,ParsecRenderController {
//    let viewController: UIViewController
//    var mtkView: MTKView!
//    var renderer: ParsecMetalRenderer!
//    
//    var updateImage: () -> Void
//
//	private var framesDisplayedCounter: Int = 0
//    
//    var preferredFPS: Int {
//        get { mtkView.preferredFramesPerSecond }
//        set { mtkView.preferredFramesPerSecond = newValue }
//    }
//    
//    func drawFrameCompleted() {
//        framesDisplayedCounter += 1
//    }
//    
//    func getFramesDisplayed() -> Int {
//        return framesDisplayedCounter
//    }
//
//    
//	required init(
//		viewController: UIViewController,
//		updateImage: @escaping () -> Void
//	) {
//        self.viewController = viewController
//        self.updateImage = updateImage
//    }
//    
//    func viewDidLoad() {
//        mtkView = MTKView(frame: viewController.view.bounds)
//        mtkView.device = MTLCreateSystemDefaultDevice()
//		mtkView.enableSetNeedsDisplay = false
//		mtkView.isPaused = false
//
//		mtkView.colorPixelFormat = .bgra8Unorm
//
//        mtkView.preferredFramesPerSecond = SettingsHandler.shared.fpsPerFrame
//
//		mtkView.clearColor = MTLClearColor(
//			red: 1.0,
//			green: 0.0,
//			blue: 0.0,
//			alpha: 1.0
//		)
//
//		mtkView.framebufferOnly = false
//
//        renderer = ParsecMetalRenderer(mtkView, updateImage: updateImage)
//        viewController.view.addSubview(mtkView)
//    }
//    
//	func updateSize(width: CGFloat, height: CGFloat) {
//		mtkView.frame.size = CGSize(width: width, height: height)
//		mtkView.drawableSize = CGSize(width: width, height: height) 
//	}
//
//	func cleanUp() {
//		mtkView?.removeFromSuperview()
//		renderer = nil
//	}
//}
//


/*import SwiftUI
import MetalKit

struct ParsecMetalViewController: UIViewRepresentable
{
	let onBeforeRender:() -> Void
	
	func makeCoordinator() -> ParsecMetalRenderer
	{
		ParsecMetalRenderer(self, onBeforeRender)
	}
	
	func makeUIView(context: UIViewRepresentableContext<ParsecMetalViewController>) -> MTKView
	{
		let metalView = MTKView()
		metalView.delegate = context.coordinator
		metalView.preferredFramesPerSecond = 60
		metalView.enableSetNeedsDisplay = true
		
		if let metalDevice = MTLCreateSystemDefaultDevice()
		{
			metalView.device = metalDevice
		}
		
		metalView.framebufferOnly = false
		metalView.drawableSize = metalView.frame.size
		return metalView
	}
	
	func updateUIView(_ uiView:MTKView, context: UIViewRepresentableContext<ParsecMetalViewController>) { }
}*/
