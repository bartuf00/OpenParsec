# 輸入修復與子母畫面（PiP）行為更新說明

> 日期：2026-08-26
> 涉及檔案：`ParsecViewController.swift`、`PictureInPictureManager.swift`、`ParsecMetalRenderer.swift`、`SceneDelegate.swift`、`ParsecView.swift`

---

## 一、鍵盤卡鍵修復（新增 `pressesCancelled`）

### 問題
App 在硬體鍵盤按住中途被系統打斷（例如背景化、切換 App、來電）時，iOS 會送 `pressesCancelled` 而不是 `pressesEnded`。
本地原本沒有實作這個 callback，導致遠端主機持續認為按鍵還按著：

- 卡 Alt（連帶 `optCmdRemapActive` 的 Opt→Win remap 狀態殘留）
- 卡重複輸入（key repeat timer 繼續跑）

### 修法（`ParsecViewController.swift:579`）
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

## 二、Metal 子母畫面黑畫面修復

### 根因
`MetalCaptureSurfaceProvider.getMTLTexture()` 全專案**沒有任何呼叫者**——
`PictureInPictureManager` 的 CADisplayLink frame pump 一直把「從未被寫入內容的 pixel buffer」
丟給 `AVSampleBufferDisplayLayer`，所以 Metal 模式的 PiP 永遠是空的。

### 修法
1. `PictureInPictureManager` 新增：
   ```swift
   func metalCaptureTexture() -> MTLTexture?
   ```
2. `ParsecMetalRenderer.draw(in:)` 在主畫面 render pass 之後、同一個 commandBuffer 內，
   **追加第二個 render pass** 直接畫進 PiP capture texture：
   - 同一組 pipeline / NV12 texture 綁定（yTex / uvTex / textTex）
   - viewSize buffer 改傳 capture texture 的尺寸
   - `loadAction = .dontCare`、`storeAction = .store`

每幀同步更新，PiP 小窗即時反映畫面。GL 路徑此次未動。

---

## 三、PiP 啟動行為變更：自動 → 按鈕手動

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
- **SceneDelegate.sceneDidEnterBackground**：刪除整段自動 `startPiP()`，
  只保留 `ParsecBackgroundManager.shared.sceneDidEnterBackground()`。
  （該 manager 本身就會檢查 `isPiPActive / isStarting`，手動開啟的 PiP 不受影響）
- **ParsecView.menuView**：Zoom 按鈕下方新增「Picture in Picture」按鈕，
  僅在 `iOS 15+` 且設定 `enablePiP` 開啟時顯示。
- **startPiP()**：移除舊有的 0.5 秒延遲（背景啟動時期的產物），
  改為前景直接呼叫，並加上 `isPictureInPicturePossible` 前置檢查，
  避免系統拒絕啟動時 `isStarting` 卡死、之後再也按不動。

---

## 四、待驗證清單（需 Xcode 實機）

- [ ] Metal 模式連線 → 選單按 Picture in Picture → 回主畫面：小窗有即時畫面
- [ ] OpenGL 模式同上流程迴歸測試
- [ ] 不按按鈕直接退背景 → 斷線標記 → 回前景自動重連（行為與舊版一致）
- [ ] 硬體鍵盤按住 Alt+Tab 中途 Home 鍵切走 → 回來後無卡鍵、remap 可正常再次觸發
- [ ] 設定關閉 enablePiP → 選單不出現 PiP 按鈕
