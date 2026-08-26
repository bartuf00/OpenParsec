import UIKit
import SwiftUI
import GLKit
import MetalKit
import AVFoundation

class SceneDelegate: UIResponder, UIWindowSceneDelegate
{
	var window: UIWindow?

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
	{
		// Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
		// If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
		// This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).

		// Create the SwiftUI view that provides the window contents.
		let contentView = ContentView()

		// Use a UIHostingController as window root view controller.
		if let windowScene = scene as? UIWindowScene
		{
		    let window = UIWindow(windowScene: windowScene)
		    window.rootViewController = UIHostingController(rootView: contentView)
		    self.window = window
		    window.makeKeyAndVisible()
		}
	}

	func sceneDidDisconnect(_ scene: UIScene)
	{
		// Called as the scene is being released by the system.
		// This occurs shortly after the scene enters the background, or when its session is discarded.
		// Release any resources associated with this scene that can be re-created the next time the scene connects.
		// The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).

		if ParsecBackgroundManager.shared.hasActiveConnection {
			CParsec.sendReleaseMessage()
			CParsec.disconnect()
		}

	}

	func sceneDidBecomeActive(_ scene: UIScene)
	{
		// Called when the scene has moved from an inactive state to an active state.
		// Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.

		// 不要操作UI或PiP状态，iOS会在sceneWillResignActive时自动停止PiP并在sceneDidBecomeActive时自动恢复，无需我们手动干预。我们只需要在sceneWillResignActive发送释放消息即可。
		ParsecBackgroundManager.shared.sceneDidBecomeActive()

	}

	func sceneWillResignActive(_ scene: UIScene)
	{
		// Called when the scene will move from an active state to an inactive state.
		// This may occur due to temporary interruptions (ex. an incoming phone call).

		if ParsecBackgroundManager.shared.hasActiveConnection {
			CParsec.sendReleaseMessage()
		}

		// Do NOT start PiP here — fires for app switcher gesture too. PiP starts in sceneDidEnterBackground.
		ParsecBackgroundManager.shared.sceneWillResignActive()
	}

	func sceneWillEnterForeground(_ scene: UIScene)
	{
		// Called as the scene transitions from the background to the foreground.
		// Use this method to undo the changes made on entering the background.
	}

	func sceneDidEnterBackground(_ scene: UIScene)
	{
		// PiP is only started from the user's menu button. Backgrounding without an active
		// PiP session lets ParsecBackgroundManager mark the connection for reconnect.
		ParsecBackgroundManager.shared.sceneDidEnterBackground()
	}

}


