import SwiftUI
import ParsecSDK
import Foundation
import AVFoundation

import OSLog
import Combine

struct ParsecStatusBar : View {
	@Binding var showMenu : Bool
	@State var metricInfo: String = "Loading..."
	@Binding var showDCAlert: Bool
	@Binding var DCAlertText: String

	@State var parsecViewController: ParsecViewController?
	@State var wasDisconnected: Bool = true

	@State private var timerCancellable: AnyCancellable?

	// 觀察全局設定變更
	@ObservedObject private var settings = SettingsHandler.shared
    

	init(showMenu: Binding<Bool>, showDCAlert: Binding<Bool>, DCAlertText: Binding<String>, parsecViewController: ParsecViewController) {
		_showMenu = showMenu
		_showDCAlert = showDCAlert
		_DCAlertText = DCAlertText
		self.parsecViewController = parsecViewController


	}
	
	var body: some View {
		// Overlay elements
		if showMenu
		{
			VStack()
			{
				Text(metricInfo)
					.frame(minWidth:200, maxWidth:.infinity)
					.multilineTextAlignment(.leading)
					.font(.system(size: 10))
					.lineSpacing(4)
					.lineLimit(nil)
			}
			.background(Rectangle().fill(Color("BackgroundPrompt").opacity(0.75)))
			.foregroundColor(Color("Foreground"))
			.frame(maxHeight: .infinity, alignment: .top)
			.zIndex(1)
			.edgesIgnoringSafeArea(.all)
			.onAppear {
				timerCancellable = Timer
					.publish(every: settings.statusBarTimer, on: .main, in: .common)
					.autoconnect()
					.sink { _ in
						poll()
					}
			}
			.onDisappear {
				timerCancellable?.cancel()
				timerCancellable = nil
			}
			
		}
		EmptyView()


	}
	
	func poll()
	{

		if showDCAlert
		{
			return // no need to poll if we aren't connected anymore
		}
		
		var pcs = ParsecClientStatus()
		let status = CParsec.getStatusEx(&pcs)
		
		if status != PARSEC_OK
		{

			if ParsecBackgroundManager.shared.isMarkedForReconnect {
				return
			}

			// PiP: connection died (screen lock killed GPU). Kill connection+audio once,
			// subsequent polls exit via isMarkedForReconnect above.
			var pipActive = false
			if #available(iOS 15.0, *) {
				pipActive = PictureInPictureManager.shared.isPiPActive
			}
			if pipActive {
				CParsec.disconnect()
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
				ParsecBackgroundManager.shared.connectionDidEnd()
				ParsecBackgroundManager.shared.markForReconnect()
				wasDisconnected = true
				return
			}

			wasDisconnected = true

			DCAlertText = "Disconnected (code \(status.rawValue))"
			showDCAlert = true
			return
		}

		// FIXME: This may cause memory leak?
		
		if showMenu
		{
			
			let decodeLatency = String(format: "%.2f", pcs.`self`.metrics.0.decodeLatency)
            let encodeLatency = String(format: "%.2f", pcs.`self`.metrics.0.encodeLatency)
            let networkLatency = String(format: "%.2f", pcs.`self`.metrics.0.networkLatency)
            let bitrate = String(format: "%.2f", pcs.`self`.metrics.0.bitrate)

            let codec = pcs.decoder.0.h265 ? "H265" : "H264"

			
            let resolution = "\(pcs.decoder.0.width)x\(pcs.decoder.0.height)"
            let colorFormat = pcs.decoder.0.color444 ? "4:4:4" : "4:2:0"

			let decoderName = String.fromBuffer(&pcs.decoder.0.name.0, length: 16)
			
			// ✅ 新增 FPS 參數（舉例，你的 GLK FPS）
			let glkFPS = settings.preferredFramesPerSecond
            let glkFPS_ACT = ParsecRenderCenter.shared.actualFPS()
		
			// 查增量實際 FPS（可每秒刷新）
			let deltaFPS = ParsecRenderCenter.shared.deltaFPS()

			let DebugMes = ParsecRenderCenter.shared.DebugMes()



			

			let metricsArray = [
			    "Decode \(decodeLatency)ms",
			    "Encode \(encodeLatency)ms",
			    "Network \(networkLatency)ms",
			    "Bitrate \(bitrate) Mbps",
			    "\(codec) \(resolution) \(colorFormat)",
			    decoderName,
			    "\n目標FPS \(glkFPS)",  
			    "平均FPS \(String(format: "%.2f", glkFPS_ACT))",
				"當前FPS \(String(format: "%.2f", deltaFPS))",
				"DebugMes: \(DebugMes ?? "")"
			]

			metricInfo = metricsArray.joined(separator: " ")

		

			
		}

//		if let pc = parsecViewController {
//			// Logic handled in ParsecViewController.scrollView
//		}
	}
}

// CRITICAL: This class exists to PERSIST the ParsecViewController instance across SwiftUI view updates.
// Do not remove or change to a struct. If ParsecViewController is recreated, the keyboard responder chain breaks.
class ParsecSession: ObservableObject {
    let controller: ParsecViewController
    
    init() {
        self.controller = ParsecViewController()
    }
}

struct ParsecView: View
{
	@Binding var currentView: ViewType
	
	@State var showDCAlert: Bool = false
	@State var DCAlertText: String = "Disconnected (reason unknown)"
    @State var metricInfo: String = "Loading..."



	@State var hideOverlay: Bool = false
	@State var showMenu: Bool = false

	@State var showKeyboard: Bool = false
	
	// 已遷義至 SettingsHandler
	//@State var zoomEnabled: Bool = false

	// 已遷義至 SettingsHandler
	// @State var muted: Bool = false
	// @State var preferH265: Bool = true
	// @State var constantFps = false
	
	@State var resolutions: [ParsecResolution]
	@State var bitrates: [Int]
	
    // Persist the VC across view updates using StateObject.
    // CRITICAL: Changing this to @State or a simple var will break the keyboard after menu interactions.
	@StateObject var session = ParsecSession()
    
    // Observer shared state for updates
    @ObservedObject var dataModel = DataManager.model

	// 配置變更會觸發 ParsecRenderCenter 的更新，這裡直接觀察 SettingsHandler 的相關屬性即可。
	@ObservedObject private var settings = SettingsHandler.shared
    
    // Computed property for convenience refactoring
    var parsecViewController: ParsecViewController {
        return session.controller
    }
	
	
	//@State var showDisplays: Bool = false
	
	init(currentView: Binding<ViewType>)
	{
		_currentView = currentView
		// parsecViewController logic moved to ParsecSession
        
		_resolutions = State(initialValue: ParsecResolution.resolutions)
		_bitrates = State(initialValue: ParsecResolution.bitrates)
	
    }
    
    // We need to set up the callback somewhere safer than init.
    // 'onAppear' is a good place, or inside the init of ParsecSession if possible (but it doesn't have access to binding).
    // Let's use onAppear/post.

	private var mainButton: some View {
		Button {
			showMenu.toggle()
			if showMenu {
				ParsecRenderCenter.shared.getHostUserData()
			}
		} label: {
			Image("IconTransparent")
				.resizable()
				.frame(width: 48, height: 48)
				.opacity(showMenu ? 1 : 0.25)
				.background(
					Color("BackgroundPrompt")
						.opacity(showMenu ? 0.75 : 0.15)
				)
				.cornerRadius(8)

		}
		.padding(8)

	}
	private var keyboardButton: some View {
		Button(action: toggleKeyboard) {
			Image(systemName: "keyboard")
				.resizable()
				.scaledToFit()
				.foregroundColor(Color("Foreground"))
				.background(
					Color("BackgroundPrompt")
						.opacity(showKeyboard ? 0.75 : 0.15)
				)
				.opacity(showKeyboard ? 1 : 0.25)
				.frame(width: 40, height: 40)
				.cornerRadius(8)

		}.padding(8)
	}

	private var menuView: some View {

		VStack(spacing:3) {
			Button(action:disableOverlay)
			{
				Text("Hide Overlay")
					.padding(8)
					.frame(maxWidth:.infinity)
					.multilineTextAlignment(.center)
			}
			Button(action: toggleMute)
			{
				Text("Sound: \(settings.savedMuted ? "OFF" : "ON")")
					.padding(8)
					.frame(maxWidth:.infinity)
					.multilineTextAlignment(.center)
			}
			Menu() {
				ForEach(resolutions, id: \.self) { resolution in
					Button(action: {
						changeResolution(res: resolution)
					}) {
						if resolution.width == dataModel.resolutionX && resolution.height == dataModel.resolutionY {
							Label(resolution.desc, systemImage: "checkmark")
						} else {
							Text(resolution.desc)
						}
					}
				}
			} label: {
				Text("Resolution")
					.padding(8)
					.frame(maxWidth:.infinity)
					.multilineTextAlignment(.center)
			}
			Menu() {
				ForEach(bitrates, id: \.self) { bitrate in
					Button(action: {
						changeBitRate(bitrate: bitrate)
					}) {
						if bitrate == dataModel.bitrate {
							Label("\(bitrate) Mbps", systemImage: "checkmark")
						} else {
							Text("\(bitrate) Mbps")
						}
					}
				}
			} label: {
				Text("Bitrate")
					.padding(8)
					.frame(maxWidth:.infinity)
					.multilineTextAlignment(.center)
			}
			if (DataManager.model.displayConfigs.count > 1) {
				Menu() {
					Button("Auto") {
						changeDisplay(displayId: "none")
					}
					ForEach(DataManager.model.displayConfigs, id: \.self) { config in
						Button("\(config.name) \(config.adapterName)") {
							changeDisplay(displayId: config.id)
						}
					}
				} label: {
					Text("Switch Display")
						.padding(8)
						.frame(maxWidth:.infinity)
						.multilineTextAlignment(.center)
				}
			}

			Button(action: toggleH265)
			{
				Text("Codec: \(SettingsHandler.shared.decoder == DecoderPref.h264 ? "H264" : "H265")")
					.padding(8)
					.frame(maxWidth:.infinity)
					.multilineTextAlignment(.center)
			}
			
			MultiPicker(selection: $settings.preferredFramesPerSecond, options:
			[
				Choice("Auto \(UIScreen.main.maximumFramesPerSecond) FPS", 0),
				Choice("120 FPS", 120),
				Choice("90 FPS", 90),
				Choice("60 FPS", 60),
				Choice("30 FPS", 30)
			])
			.padding(8)
			.frame(maxWidth:.infinity)
			.multilineTextAlignment(.center)
			
			Button(action: toggleConstantFps)
			{
				Text("Constant FPS: \(SettingsHandler.shared.savedConstantFps ? "ON" : "OFF")")
					.padding(8)
					.frame(maxWidth:.infinity)
					.multilineTextAlignment(.center)
			}
			Button(action: toggleZoom)
			{
				Text("Zoom: \(SettingsHandler.shared.savedZoom ? "ON" : "OFF")")
					.padding(8)
					.frame(maxWidth:.infinity)
					.multilineTextAlignment(.center)
			}
			if #available(iOS 15.0, *), settings.enablePiP {
				Button(action: {
					showMenu = false
					PictureInPictureManager.shared.startPiP()
				}) {
					Text("Picture in Picture")
						.padding(8)
						.frame(maxWidth:.infinity)
						.multilineTextAlignment(.center)
				}
			}
			Rectangle()
				.fill(Color("Foreground"))
				.opacity(0.25)
				.frame(height:1)
			Button(action: {
				disconnect(isBackgroundDisconnect:false)
			}) {
				Text("Disconnect")
					.foregroundColor(.red)
					.padding(8)
					.frame(maxWidth:.infinity)
					.multilineTextAlignment(.center)
			}
		}
		.background(Color("BackgroundPrompt").opacity(0.75))
		.foregroundColor(Color("Foreground"))
		.frame(maxWidth:175)
		.cornerRadius(8)

	}


	var body: some View
	{
		ZStack {

			UIViewControllerWrapper(self.parsecViewController)
			.ignoresSafeArea(.keyboard)   // 🚫 禁止鍵盤影響 layout
			.zIndex(-1)
				

			ParsecStatusBar(showMenu: $showMenu, showDCAlert: $showDCAlert, DCAlertText: $DCAlertText, parsecViewController: parsecViewController)
				.zIndex(1)

			VStack(alignment: .leading, spacing: 4) {
				if !hideOverlay
				{
					HStack(spacing: 8 ) {
						// 主按鈕
						mainButton

						if settings.showKeyboardButton {
							// 快速呼出keyboard
							keyboardButton
						}

						Spacer()
					}
					.padding()


				}
				if showMenu {

					menuView
					.padding(.leading)

				}
				Spacer()
			}
			.zIndex(2)

		}
		.statusBarHidden(settings.hideStatusBar)
		.alert(isPresented:$showDCAlert)
		{
			Alert(
				title: Text(DCAlertText), dismissButton:.default(Text("Close"), action:{
				disconnect(isBackgroundDisconnect:false)
				})
				)
		}
		.onAppear(perform:post)
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ParsecBackgroundDisconnect"))) { _ in
			if #available(iOS 15.0, *) {
				if PictureInPictureManager.shared.isPiPActive {
					return
				}
			}
			disconnect(isBackgroundDisconnect: true)
		}

	}
	
	func post()
	{


		ParsecBackgroundManager.shared.onShouldDisconnect = {
			NotificationCenter.default.post(name: NSNotification.Name("ParsecBackgroundDisconnect"), object: nil)
		}

		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.onPiPStopped = { [self] in
				if UIApplication.shared.applicationState != .active {
					// Synchronous — DispatchQueue.main.async may never execute if iOS suspends the app
					CParsec.sendReleaseMessage()
					let RES = CParsec.pause()
					write_log_from_swift("PiP stopped, disconnecting \(String(describing: RES))")

					try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
					ParsecBackgroundManager.shared.markForReconnect()
					DispatchQueue.main.async {
						self.disconnect(isBackgroundDisconnect: true)
					}
				} else {
					
					if ParsecBackgroundManager.shared.isReconnecting {
						return
					}
					// Check actual Parsec status — timers don't reliably fire in background
					var pcs = ParsecClientStatus()
					let currentStatus = CParsec.getStatusEx(&pcs)
					if currentStatus != PARSEC_OK || ParsecBackgroundManager.shared.isMarkedForReconnect {
						CParsec.disconnect()
						try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
						ParsecBackgroundManager.shared.markForReconnect()
						DispatchQueue.main.async {
							self.disconnect(isBackgroundDisconnect: true)
						}
					}
				}
			}
			PictureInPictureManager.shared.onPiPStartFailed = { [self] in
				if UIApplication.shared.applicationState != .active {

					CParsec.sendReleaseMessage()
					let RES = CParsec.pause()
					write_log_from_swift("PiP start failed, paused Parsec \(String(describing: RES))")

					ParsecBackgroundManager.shared.markForReconnect()
					DispatchQueue.main.async {
						self.disconnect(isBackgroundDisconnect: true)
					}
				}
			}
		}
	
		hideOverlay = settings.noOverlay

        // Setup callback to update local state
        parsecViewController.onKeyboardVisibilityChanged = { visible in
            showKeyboard = visible
        }

		parsecViewController.setKeyboardVisible(showKeyboard)
	}
	
	
	func disableOverlay()
	{
		hideOverlay = true
		showMenu = false
	}
	
	func toggleMute()
	{
		settings.savedMuted.toggle()
		ParsecRenderCenter.shared.setMuted(settings.savedMuted)

		write_log_from_swift("muted \(settings.savedMuted ? "true" : "false")")

	}
	
	/*func genDisplaySheet() -> ActionSheet
	{
		let len:Int = 16
		var outputs = [ParsecOutput?](repeating:nil, count:len)
		ParsecGetOutputs(&outputs, UInt32(len))
		print("Listing \(outputs.count) displays")

		func getDeviceName(_ output:ParsecOutput) -> String
		{
			return withUnsafePointer(to:output.device)
			{
				$0.withMemoryRebound(to: UInt8.self, capacity:MemoryLayout.size(ofValue:$0))
				{
					String(cString:$0)
				}
			}
		}

		let buttons = outputs.enumerated().map
		{ i, output in
			Alert.Button.default(Text("\(i) - \(getDeviceName(output))"), action:{print("Selected device \(i)")})
		}
		return ActionSheet(title: Text("Select a Display:"), buttons:buttons + [Alert.Button.cancel()])
	}*/
	
	func disconnect(isBackgroundDisconnect: Bool = false)
	{


		if !isBackgroundDisconnect {
			ParsecBackgroundManager.shared.disableAutoReconnect()
		}

		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.teardown()
		}

		// 包含ReleaseMessage和disconnect兩個步驟，確保完全斷開連接並釋放資源
		ParsecRenderCenter.shared.shutdown()

		parsecViewController.keyboardVisible = false

		parsecViewController.scrollView.zoomScale = 1.0
		parsecViewController.scrollView.contentOffset = .zero

		write_log_from_swift("Disconnected User initiated disconnect")

		setView(.main)
	}

	private func setView(_ view: ViewType)
	{
		withAnimation(.easeInOut) {
			currentView = view
		}
	}
	
	func changeResolution(res: ParsecResolution) {
		DataManager.model.resolutionX = res.width
		DataManager.model.resolutionY = res.height

		ParsecRenderCenter.shared.requestResolutionUpdate()
		ParsecRenderCenter.shared.applyIfPossible()
		
		write_log_from_swift("resolution \(res.width)x\(res.height)")

	}

	func changeBitRate(bitrate: Int) {
		DataManager.model.bitrate = bitrate

		write_log_from_swift("bitrate \(bitrate)")

		ParsecRenderCenter.shared.requestBitrateUpdate()
	}
	func updateFPS(_ fps: Int = 0) {

		if fps == 0 {
			// Use device's maximum refresh rate (120Hz on ProMotion iPads)
			ParsecRenderCenter.shared.updateFPS(Int(UIScreen.main.maximumFramesPerSecond))
		} else {
			ParsecRenderCenter.shared.updateFPS(fps)
		}

		write_log_from_swift("preferredFramesPerSecond \(fps == 0 ? "Device max->\(UIScreen.main.maximumFramesPerSecond)" : String(fps))")

	}

	func toggleH265() {
		DispatchQueue.main.async {
			SettingsHandler.shared.decoder = SettingsHandler.shared.decoder == DecoderPref.h264 ? DecoderPref.h265 : DecoderPref.h264

			// 套用配置變更
			CParsec.applyConfig()
			write_log_from_swift("decoder \(SettingsHandler.shared.decoder == DecoderPref.h264 ? "H264" : "H265")")

			// 這裡不需要直接調用 applyIfPossible，因為 updateHostVideoConfig 已經在內部處理了。
		}
	}


	func toggleConstantFps() {
		DispatchQueue.main.async {
			SettingsHandler.shared.savedConstantFps.toggle()
			DataManager.model.constantFps = SettingsHandler.shared.savedConstantFps

			CParsec.updateHostVideoConfig()
			write_log_from_swift("constantFps \(SettingsHandler.shared.savedConstantFps ? "true" : "false")")
			// 這裡不需要直接調用 applyIfPossible，因為 updateHostVideoConfig 已經在內部處理了。
		}
	}

	func toggleKeyboard() {

		showKeyboard.toggle()
		parsecViewController.setKeyboardVisible(showKeyboard)

		write_log_from_swift("keyboardVisible \(showKeyboard ? "true" : "false")")

	}
	
	func toggleZoom() {
		DispatchQueue.main.async {
			SettingsHandler.shared.savedZoom.toggle()
			parsecViewController.setZoomEnabled(SettingsHandler.shared.savedZoom)

			write_log_from_swift("zoomEnabled \(SettingsHandler.shared.savedZoom ? "true" : "false")")
		}
	}
	
	func changeDisplay(displayId: String) {
		DispatchQueue.main.async {
			DataManager.model.output = displayId
			CParsec.updateHostVideoConfig()
			
			write_log_from_swift("display \(displayId)")
			// 這裡不需要直接調用 applyIfPossible，因為 updateHostVideoConfig 已經在內部處理了。
		}
	}
	
	

}

// from https://github.com/utmapp/UTM/blob/117e3a962f2f46f7d847632d65fa7a85a2bb0cfa/Platform/iOS/VMWindowView.swift#L314
private extension View {
	func prefersPersistentSystemOverlaysHidden() -> some View {
		if #available(iOS 16, *) {
			return self.persistentSystemOverlays(.hidden)
		} else {
			return self
		}
	}
}
