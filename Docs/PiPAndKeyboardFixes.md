# 輸入修復與子母畫面（PiP）行為更新說明

> 日期：2026-08-26（同日二次修訂）
> 涉及檔案：`ParsecViewController.swift`、`PictureInPictureManager.swift`、`ParsecMetalRenderer.swift`、`ParsecGLKRenderer.swift`、`ParsecGLKViewController.swift`、`SceneDelegate.swift`、`ParsecView.swift`

---

## 一、鍵盤卡鍵修復（新增 `pressesCancelled`）

### 問題
App 在硬體鍵盤按住中途被系統打斷（例如背景化、切換 App、來電）時，iOS 會送 `pressesCancelled` 而不是 `pressesEnded`。
本地原本沒有實作這個 callback，導致遠端主機持續認為按鍵還按著：

- 卡 Alt（連帶 `optCmdRemapActive` 的 Opt→Win remap 狀態殘留）
- 卡重複輸入（key repeat timer 繼續跑）

### 修法（`ParsecViewController.swift`）
```swift
override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    CParsec.sendReleaseMessage()   // 釋放遠端所有按住的鍵
    stopKeyRepeat()                // 停掉重複計時器
    optCmdRemapActive = false      // 重置 remap 狀態
    altKeyHeld = false
}
```

### 與上游 PR #91 的取捨
上游 [hugeBlack/OpenParsec#91](https://github.com/hugeBlack/OpenParsec/pull/91) 修三件事：
外接滑鼠 indirectPointer 干擾、觸控板拖曳壞掉、Alt 被送成 Win。

經評估**不整顆 cherry-pick**，只吸收其中對本地有意義的 `pressesCancelled` 概念：
- Bug ①②：本地的觸控／滑鼠架構不同（外接滑鼠獨走 `GameController.swift` 的 GCMouse，
  沒有 TouchOverlayView），問題不存在，補丁無效。
- Bug ③（Alt→Win）：在本地是刻意保留的功能（`optCmdRemapActive`），不採用上游的移除。

---

## 二、鍵盤關閉後畫面偏下修復

### 問題
打開鍵盤時 `keyboardWillShow` 會把 scrollView 上捲 `height / 1.25`，
但 `keyboardWillHide` 只在**橫向**（width > height）才往回捲——直向模式下畫面永遠停在偏下的位置。

### 修法
改為「離開前快照、關閉時精準還原」，方向與縮放狀態通用：

- `keyboardWillShow`：第一次顯示時記下 `contentOffsetBeforeKeyboard`
- `keyboardWillHide`：無條件 `setContentOffset(contentOffsetBeforeKeyboard)` 還原，
  並補上 `scrollIndicatorInsets` 重置

此檔案為 GL/Metal 共用，兩個渲染後端一併生效。

---

## 三、子母畫面沒有畫面修復（GL / Metal 雙後端）

### 根本原因
兩個 provider 都只是「建立 buffer」但**從來沒有人把畫面畫進去**：

| 後端 | 原狀態 |
|---|---|
| Metal | `getMTLTexture()` 全專案零呼叫；且 texture cache 出的 texture 是 shader-read，不能當 render target |
| GL | `captureFBO` 建完就沒再綁定過，render loop 只畫到 GLKView drawable |

frame pump 一直把空 buffer 餵給 `AVSampleBufferDisplayLayer` → 黑畫面。

### Metal 修法
`MetalCaptureSurfaceProvider` 改用**顯式 IOSurface-backed MTLTexture**：

```swift
guard let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, ...)
desc.usage = [.shaderRead, .renderTarget]   // 關鍵：允許寫入
desc.storageMode = .shared
mtlTexture = device.makeTexture(descriptor: desc, iosurface: ioSurface, plane: 0)
```

`ParsecMetalRenderer.draw(in:)` 在主 pass 之後、同一 commandBuffer 追加第二個 render pass
畫進該 texture（同 pipeline / NV12 綁定）。

### GL 修法
1. **`ParsecGLKViewController`**：provider 改傳 `glkView.context`（原本另開一個
   沒人 set current 的新 context，texture/FBO 全落在錯的 context 上）。
2. **`GLCaptureSurfaceProvider`** 新增：
   - `beginCaptureFrame()` — 存下目前 FBO/viewport → 綁 captureFBO → 設 viewport
   - `endCaptureFrame()` — 還原 FBO/viewport
3. **`ParsecGLKRenderer.drawIn`**：主繪製後重繪一次進 capture FBO：
   ```swift
   CParsec.renderGLFrame(timeout: timeout)
   if PictureInPictureManager.shared.beginOpenGLCaptureFrame() {
       CParsec.renderGLFrame(timeout: 0)
       PictureInPictureManager.shared.endOpenGLCaptureFrame()
   }
   ```

### frame pump 生命週期順帶修正
- **CADisplayLink → DispatchSourceTimer**：display link 在 App 背景化後完全不觸發，
  PiP 小窗會凍結在最後一幀；GCD timer 在 audio session（`.playback`）維持程序存活時持續觸發。
- pump 從 `setup()` 移到 `startPiP()` 才啟動，`DidStop` / `failedToStart` / `teardown` 停止
  —— 不再全天候空轉餵空 buffer。
- `renderFrame()` 會偵測 pixelBuffer 身分變化（重建／尺寸變更），自動重建 format description。

---

## 四、PiP 啟動行為變更：自動 → 按鈕手動

### 原行為的問題
退到背景就自動啟動 PiP。當用戶正在看其他影片的小窗、又切回使用本 App 再退出時，
我們的 PiP 會強行搶走／打斷用戶正在看的影片視窗，非常干擾。

### 新行為
| 操作 | 行為 |
|---|---|
| 用戶在選單按「Picture in Picture」 | 前景立即啟動 PiP；之後回桌面小窗持續播放、連線保持 |
| 未按按鈕直接退到背景 | 不啟動 PiP，依 `ParsecBackgroundManager` 原邏輯標記斷線、返回後自動重連 |
| PiP 播放中用戶關閉小窗 | 走既有 `onPiPStopped` 流程（背景則釋放輸入並暫停） |

### 變更點
- **SceneDelegate.sceneDidEnterBackground**：刪除整段自動 `startPiP()`。
- **ParsecView.menuView**：Zoom 按鈕下方新增「Picture in Picture」按鈕，
  顯示條件：`iOS 15+` 且設定「Enable PiP」開啟。
- **startPiP()**：移除舊的 0.5 秒延遲，加 `isPictureInPicturePossible` 前置檢查，
  避免系統拒絕啟動時 `isStarting` 卡死。

> 注意：選單按鈕受設定「Enable PiP」控制，需先到設定頁開啟才會出現。

---

## 五、待驗證清單（需 Xcode 實機）

- [ ] Metal 模式連線 → 選單按 Picture in Picture → 回主畫面：小窗有即時畫面
- [ ] OpenGL 模式同上流程：小窗有即時畫面（本次重點修復）
- [ ] PiP 中背景停留 >1 分鐘：小窗畫面持續更新（GCD timer 生效驗證）
- [ ] 不按按鈕直接退背景 → 斷線標記 → 回前景自動重連（行為與舊版一致）
- [ ] 直向模式：開鍵盤→關鍵盤，畫面回到原位（不再偏下）；橫向迴歸測試
- [ ] 硬體鍵盤按住 Alt+Tab 中途 Home 鍵切走 → 回來後無卡鍵、remap 可正常再次觸發
