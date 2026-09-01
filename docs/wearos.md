# Wear OS 版（standalone）

手錶跑的是**同一顆引擎**：transport → `Elm327Client` → `PollingEngine` →
Riverpod，一行協定邏輯都沒有分叉。這份文件記錄的是錶殼層的設計決策與
誠實的邊界。

## 設計

- **Glance-first**：橫向滑動的三頁（主錶盤 → 電池* → 數字牆），每頁一眼
  一個資訊。純黑底（AMOLED 省電，也是深色色盤自己的地基）。
- **主錶盤**：單一大型自繪圓錶，點擊循環 車速 → 轉速 → 水溫；長按→確認
  →中斷連線。圓錶面天然貼合圓錶殼。
- **電池頁**（有已安裝 community profile 才出現）：SoC 大字＋pack V/A。
  **與手機同一套每連線車輛確認**——未確認前只有「確認車輛」按鈕，確認
  對話框同樣在開啟前捕捉 connection generation、接受後驗證連線未變。
  **誠實邊界**：profile 安裝只存在於手機 UI，而錶 app 是 standalone
  （兩邊的 SharedPreferences 不互通），所以真錶上目前**沒有任何路徑**
  能讓這一頁出現。它是 widget 測試覆蓋的既成程式，不是已出貨的功能；
  補上 provisioning（錶上安裝流程或 Data Layer 同步）之前，不要對外
  宣稱錶有電池頁。
- **數字牆**：水溫／進氣溫／轉速／轉接器電壓，2×2 大字。
- **連線頁**：Demo 一鍵；BLE 兩鍵（掃描→點裝置）。連線期間以
  `FLAG_KEEP_SCREEN_ON` 常亮（駕駛儀表睡著比省下的電更糟；旗標綁定
  window，崩潰不會殘留）。

## 刻意不做

- **寫入操作一律不進錶**：清除故障碼、實驗室 one-shot probe、profile
  安裝／移除都只在手機上。小螢幕承載不了那些同意流程的資訊密度，
  簡化它們就是弱化它們。
- **Bluetooth Classic／Wi-Fi 不提供**：手錶 app 層開 RFCOMM 無官方
  文件也無查得先例；提供一顆註定失敗的按鈕比較小的清單更糟。
  **手錶版只支援 BLE 轉接器**（實測相容機種見
  `docs/hardware-compatibility.md`；OBDLink CX、vLinker MC+、Kiwi 3
  屬 BLE 機種）。

## 工程切面

- **UI 決策靠平台事實，不靠 flavor 也不靠幾何**：`isWatchFormFactor()`
  讀啟動時 prefetch 的 `PackageManager.FEATURE_WATCH`（platform channel，
  500ms timeout、失敗一律當手機）→ `WearShell`。窄的分割畫面手機仍是
  手機；同一顆 binary 在 Wear 模擬器上行為正確，與怎麼 build 無關。
- **`wear` product flavor 只為上架存在**：manifest overlay 宣告
  `uses-feature android.hardware.type.watch`（required）與
  `com.google.android.wearable.standalone`。applicationId 與手機版相同
  （`com.cbstudio.telltale`）——Google Play 同一個 listing 底下各自的
  form-factor artifact。

```bash
~/fvm/versions/3.47.0/bin/flutter build apk --debug --flavor wear
adb -s <wear-device> install -r build/app/outputs/flutter-apk/app-wear-debug.apk
```

## 已驗證與未驗證（誠實清單）

| 項目 | 狀態 |
| --- | --- |
| WearShell 三頁、Demo 連線、儀表即時更新 | ✅ Wear OS 模擬器（sdk_gwear_arm64）實測 |
| widget 測試（227dp 圓面幾何、頁面條件、循環、斷線確認、stale 熄滅、DEMO 標記、電池頁單一 owner＋generation 撤回） | ✅ `test/wear_shell_test.dart` |
| 電池頁在真錶上出現 | ❌ **不可達** —— 安裝只在手機、錶是 standalone，兩邊偏好設定不互通；需要 provisioning 路徑（錶上安裝或 Data Layer），列為後續 |
| BLE 直連實體轉接器 | ⚠️ **未於實錶驗證** —— 模擬器無 BLE。程式路徑與手機版共用（`universal_ble`），但 Wear 裝置上該套件無公開成功案例。上架前必須以真錶＋BLE 轉接器做一次 Gate 0 spike。2026-09-01 複查：當時只接上 Galaxy S24 Ultra 與 `sdk_gwear_arm64` 模擬器，沒有實體錶，Gate 0 仍未做 |
| 旋轉錶冠換頁 | ❌ 未做（`wearable_rotary` 已停維護；v1 以滑動代替，未來自 vendor 原生 channel） |
| Ambient mode | ❌ 未做（v1 = 連線時常亮；ambient 需 `wear_plus`，列為後續） |
| Play Wear OS track 上架 | ❌ 未做（需 target API 35+ 合規確認、384×384 截圖、release signing） |
