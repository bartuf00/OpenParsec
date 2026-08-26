import GLKit
import ParsecSDK

class ParsecGLKRenderer:NSObject, GLKViewDelegate, GLKViewControllerDelegate
{
	var glkView:GLKView
	var glkViewController:GLKViewController
	
	var lastWidth:CGFloat = 1.0
	var lastHeight: CGFloat = 1.0
	var lastScale: CGFloat = 0.0

	var lastImg: CGImage?
	let updateImage: () -> Void
	
	init(_ view:GLKView, _ viewController:GLKViewController,_ updateImage: @escaping () -> Void)
	{
		self.updateImage = updateImage
		glkView = view
		glkViewController = viewController

		super.init()

		glkView.delegate = self
		glkViewController.delegate = self

	}

	deinit
	{
		glkView.delegate = nil
		glkViewController.delegate = nil
	}

	func glkView(_ view: GLKView, drawIn rect: CGRect) {
		let width = view.bounds.size.width
		let height = view.bounds.size.height
		let scale = view.contentScaleFactor

		let deltaWidth = abs(width - lastWidth)
		let deltaHeight = abs(height - lastHeight)
		let deltaScale = abs(scale - lastScale)

		if deltaWidth > 0.1 || deltaHeight > 0.1 || deltaScale > 0.001 {
			// 用邏輯大小 + scale 告訴 Parsec
			CParsec.setFrame(width, height, scale)

			// 用像素大小設置 OpenGL viewport
			glViewport(0, 0,
					GLsizei(view.drawableWidth),
					GLsizei(view.drawableHeight))

			lastWidth = width
			lastHeight = height
			lastScale = scale
			print("SCALE", scale)
			print("Width:\(width)x\(height)")
		}

		let fps = SettingsHandler.shared.preferredFramesPerSecond == 0
			? UIScreen.main.maximumFramesPerSecond
			: SettingsHandler.shared.preferredFramesPerSecond
		let timeout = UInt32(max(1000 / fps, 8))

		CParsec.renderGLFrame(timeout: timeout)

		if #available(iOS 15.0, *) {
			if PictureInPictureManager.shared.beginOpenGLCaptureFrame() {
				CParsec.renderGLFrame(timeout: 0)

				// 翻轉 FBO 內容：AVSampleBufferDisplayLayer 是左上原點，OpenGL 是左下原點
				var captureFBO: GLint = 0
				glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &captureFBO)
				let w = view.drawableWidth
				let h = view.drawableHeight
				glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(captureFBO))
				glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), GLuint(captureFBO))
				glBlitFramebuffer(0, 0, w, h,
								  0, h, w, 0,
								  GLbitfield(GL_COLOR_BUFFER_BIT),
								  GLenum(GL_LINEAR))

				PictureInPictureManager.shared.endOpenGLCaptureFrame()
			}
		}

		updateImage()
	}


	func glkViewControllerUpdate(_ controller:GLKViewController) { }


}
