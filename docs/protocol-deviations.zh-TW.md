# 公式與 AT 指令的交叉驗證記錄

這個 App 的 OBD2 實作起於一份整理過的技術筆記。動手之前，筆記裡每一條會影響
**真實硬體行為**的項目 —— AT 初始化指令、PID 公式、物理常數 —— 都逐條對權威
來源(SAE J1979、ELM327 datasheet)查證過。以下是查證結果，以及最後決定不照
筆記做的地方與理由。

**為什麼要留這份紀錄:** 查出了三個會弄壞真車連線的錯誤(`ATCRA 7B0`、`ATCFC0`、
無條件的 `ATSH 7E0`),其中 `ATCFC0` 是第一輪只確認「指令合法」而漏掉的。這一行
曾經寫著「兩個」—— 它寫於 §2 加入 `ATSH 7E0` 之前,於是這份文件的摘要跟它自己的
內文說了不同的數字。二手的技術筆記是起點,不是標準 —— 照抄一份沒有驗證過的
公式表,就是把「看起來合理的錯數字」直接印在錶上。

驗證日期：2026-08-15

---

## 1. 已查證正確、照筆記實作

### 標準 Mode 01 PID 公式（筆記 §3.2）

對照 SAE J1979 標準值（Wikipedia OBD-II PIDs 條目），筆記全數正確：

| PID | 筆記 | 權威來源 | |
|---|---|---|---|
| 0104 引擎負載 | `A*100/255` | `100/255 × A` | ✅ |
| 0105 冷卻液溫度 | `A-40` | `A − 40` | ✅ |
| 010B 進氣歧管壓力 | `A` | `A` | ✅ |
| 010C 引擎轉速 | `((A*256)+B)/4` | `(256A + B)/4` | ✅ |
| 010D 車速 | `A` | `A` | ✅ |
| 010E 點火提前角 | `(A/2)-64` | `(A/2) − 64` | ✅ |
| 010F 進氣溫度 | `A-40` | `A − 40` | ✅ |
| 0110 MAF | `((A*256)+B)/100` | `(256A + B)/100` | ✅ |
| 0111 節氣門位置 | `A*100/255` | `100/255 × A` | ✅ |

### 車輛物理常數（筆記 §4.3）

獨立以單位換算重新推導，全部正確：

- **MPG 換算 235.215**：100 km = 62.13712 mi，1 US gal = 3.785411784 L → `62.13712 × 3.785411784 = 235.2145` ✅
- **油耗係數 0.33094**：`3600 / (14.7 × 740) = 0.330943` ✅
- **Speed-Density MAF**：四行程每兩轉進氣一次 → 體積流量 `RPM × Vd / 120` L/s；理想氣體 `n = PV/RT`；乘莫耳質量 28.97 g/mol → `MAF = RPM × MAP × Vd × 28.97 / (120 × 8.314 × T_K) × VE/100` ✅
  - 筆記另一處寫的係數 `0.029039` 即 `28.97 / (120 × 8.314) = 0.029037`，一致 ✅
- **馬力/扭力**：`W / 745.6999` = hp ✅；`扭力(ft·lb) = hp × 5252 / RPM` ✅（5252 = 33000/2π）；`N·m = ft·lb × 1.35582` ✅

### ELM327 AT 指令（筆記 §2.2）

- `ATST66`：ST 以 4 ms 為單位，`0x66` = 102 → 408 ms ✅
- `AT@1`（裝置描述）為有效指令，App 照送 ✅

筆記同一份清單裡的 `ATAT2` 與 `ATCFC0` 也都是**合法**的 AT 指令 —— 但這一節的
標題是「照筆記實作」，把只驗證過語法的項目放進來，位置本身就會被讀成「已實作」。
兩者都不送，理由各自列在 §2。

---

## 2. 已查證有誤，App 刻意偏離

### ❌ `ATCRA 7B0` — 筆記 §2.2 步驟 16

筆記寫「Set CAN RX Filter `7B0`，Filters incoming frames to ECU reply address `7B0`/`7E8`」。

**這是錯的。** 標準 11-bit OBD-II 位址配置為：

- `7DF` — 功能性廣播請求
- `7E0`–`7E7` — 對各 ECU 的實體請求（`7E0` = 引擎 ECM）
- `7E8`–`7EF` — 對應的回應（`7E0` 的回應是 `7E8`）

`7B0` 不屬於這個範圍。既然筆記步驟 14 才剛把發送標頭設成 `AT SH 7E0`，接著把接收過濾器設成 `7B0` 會**把 ECU 從 `7E8` 送回來的回應全部濾掉** — 連線看似成功，但之後每個 PID 查詢都拿到 `NO DATA`。

附在筆記後面的參考實作照抄了這個值，之所以測試仍全綠，是因為它們的 mock transport 對 `ATCRA` 一律回 `OK` 而不模擬過濾行為。

**App 的處理**：初始化序列**不送 `ATCRA`**。ELM327 預設接受所有回應，一般 OBD 應用不需要設過濾器；只有在多 ECU 吵雜匯流排上才需要，屆時應設為 `7E8`（或依 `AT SH` 的目標推導 `header + 8`）。相關程式碼見 `lib/obd/elm327_client.dart` 的 `Elm327Client.initSequence`。

### ❌ `ATCFC0` — 筆記 §2.2 步驟 15

筆記寫「Flow Control OFF，Disables automatic CAN flow control formatting for raw multiline framing」。

**這是錯的，而且危害比 `ATCRA 7B0` 更隱蔽。** ELM327 datasheet 的 *CFC0 and CFC1* 一節原文：

> The ISO 15765-4 CAN protocol expects a 'Flow Control' message to always be sent in response to a 'First Frame' message, and the ELM327 automatically sends these without any intervention by the user. **If experimenting with a non-OBD system**, it may be desirable to turn this automatic response off… **The default setting is CFC1 - Flow Controls on.**

也就是說 `CFC0` 是給「非 OBD 的 CAN 實驗」用的。在真車上關掉它，任何**超過 7 個資料位元組**的回應 —— VIN（Mode 09）、多筆故障碼（Mode 03）、fastMode 批次查詢 —— 都只會收到 First Frame 然後停住等一個永遠不會送出的 Flow Control 幀。

第一輪查證時我只確認了「`ATCFC0` 是合法的 AT 指令」，那是驗證**語法**而非**語義**，因此漏掉了。

**App 的處理**：初始化序列**不送 `ATCFC0`**，保留 ELM327 的預設 `CFC1`。

### ❌ `ATSH 7E0` 無條件送出 — 筆記 §2.2

筆記把「設定引擎 ECU 傳送標頭」列為固定的初始化步驟。**這是第三個會讓真車完全不能用的錯誤，而且它的受害範圍最大 —— 所有非 11-bit CAN 的車。**

datasheet p.11 的指令摘要列出 `ATSH` 只有三種形式：

| 形式 | 位元組 | 適用 |
|---|---|---|
| `SH xyz` | 1.5（3 個十六進位字元） | 11-bit CAN |
| `SH xxyyzz` | 3 | J1850、ISO 9141-2、ISO 14230-4 |
| `SH wwxxyyzz` | 4 | 29-bit CAN |

`7E0` 是三個十六進位字元，也就是**專屬於 11-bit CAN 的形式**。在 J1850／ISO 9141-2／KWP2000 上它不是一個合法的三位元組標頭；在 29-bit CAN 上它也不是四位元組標頭。轉接器要嘛回 `?`，要嘛裝進一個無意義的值 —— 兩種結果都一樣：**`ATSP0` 剛剛辛苦偵測出來的正確定址被丟掉了**，之後每一個查詢都送到不存在的目標，車子明明會回應卻一個字都收不到。

datasheet p.42 對這件事的立場很清楚：

> these header bytes normally are assigned automatically and generally do not need adjustment

**App 的處理**：初始化序列**完全不設實體標頭**，保留 `ATSP0` 建立的協定預設值。標頭改為**逐請求**選擇，而且只在該標頭於偵測到的匯流排上真的有意義時才送出（見 `lib/obd/addressing.dart`）。

一個延伸的細節：App 儲存自訂 PID 時，預設標頭欄位是 `7E0`。這個值在 11-bit CAN 上確實就是引擎控制器的位址，所以那裡照送；在其他匯流排上它被視為「**沒有指定偏好**」而非一道指令。使用者若真的設了一個在該匯流排上不可能存在的標頭（例如在舊協定車上填 `7E1`），該 PID 會被標為錯誤而**不是**改送到別的控制器 —— 從錯的 ECU 拿到的數字，跟從對的 ECU 拿到的長得一模一樣。

### ❌ `ATAT2` — 筆記 §2.2

筆記列 `ATAT2`（Adaptive Timing 2）。**App 送的是 `ATAT1`。**

兩者都啟用自適應計時，AT2 是更激進的變體，會縮短 ECU 用來回答的視窗。ELM327
datasheet 以 AT1 為預設值，也以 AT1 為建議值。單看指令，AT2 只是「快一點、
邊際一點」；放進這個 App 就不是了 —— 它把單一次 `NO DATA` 當成「這台車不支援
這個 PID」的證據，於是**一次錯過的視窗會讓一個其實可用的錶整個 session 退場**，
而使用者只會在畫面上看到「此車輛不支援」。理由與程式碼並置於
`Elm327Client.initSequence`。

這四個 ❌ 裡有兩個（`ATCFC0`、`ATAT2`）在第一輪查證時是通過的，因為當時只驗
「這是不是合法的 AT 指令」。合法與該送是兩件事，而這份文件記的是第二件。

### ⚠️ 初始化步驟數：筆記說 16，App 是 14

筆記 §2.2 列 16 步。App 的 `Elm327Client.initSequence` 是 **14 條**：

```
ATZ ATE0 ATL0 ATM0 ATS0 ATAT1 ATST66 ATSP0 ATI AT@1 ATRV 0100 ATDP ATDPN
```

推導：16 − `ATSH 7E0` − `ATCFC0` − `ATCRA 7B0` + `0100` 探測 = 14。三個減項的
理由是上面各自的 ❌，加項是 §3.5。

這一行曾經寫著「15 條」。那個算術只扣了 `ATCRA` —— 它是在 `ATCFC0` 與
`ATSH 7E0` 被判定為有害之前寫的，也從沒把 App 自己加的 `0100` 探測算進去。

附在筆記後面的參考實作取的是**另一種** 15 條（只省略 `ATDPN`，其餘照抄），
所以「App 14、參考實作 15」這個差距不是「少一條」那麼單純：參考實作送而 App
不送的有四條（`ATAT2`、`ATSH 7E0`、`ATCFC0`、`ATCRA 7B0`），App 送而參考實作
不送的有三條（`ATAT1`、`0100`、`ATDPN`），順序也不同。

---

## 3. 筆記未涵蓋、但真實硬體必須處理的行為

以下不是筆記的錯誤，而是筆記根本沒提、但缺了就會在真車上失敗的項目。附在筆記後面的參考實作，其 mock transport 都不模擬這些情境，所以它們測試全綠也證明不了什麼。

### 3.1 `ATSP0` 之後的協定搜尋會遠超一般逾時

自動協定搜尋（`ATSP0`）後的第一次查詢，ELM327 會逐一嘗試各種匯流排協定，先回 `SEARCHING...` 才給答案；冷車或較舊的車輛可能超過 10 秒。用一般的 5 秒逾時會在連線其實即將成功時把它砍掉。

**處理**：`Elm327Client._extendTimeoutIfSearching()` — 在緩衝區出現 `SEARCHING` 時把該指令的期限延長到 `protocolSearchTimeout`（25 秒）。`SEARCHING` 本身就是轉接器仍在工作的正面證據。

### 3.2 `ATE0` 生效前，回音仍然開著

`ATE0` 是序列的第 2 步，所以第 1 步 `ATZ` 的回應**一定**包含被回音的 `ATZ` 本身。直接取第一行當版本字串，會把轉接器版本記成 "ATZ"。

**處理**：`Elm327Client._identityLine()` 跳過與送出指令相同的那一行。

### 3.3 切換 CAN 標頭後必須切得回來

查詢變速箱 PID（`7E1`）之後若不切回 `7E0`，後續所有引擎 PID 都會拿到 `NO DATA`。原本的條件式只在標頭 ≠ `7E0` 時才送 `AT SH`，於是一旦切走就再也回不來。

**處理**：`PollingEngine._pollBatch()` 每一次查詢都走
`Elm327Client.sendAddressed(header, command)`，不再自己判斷該不該切。
`sendAddressed` 只在 `BusAddressing.shouldTransmit(header)` 成立時轉給
`sendOnHeader`；後者比對自己記著的 `_currentHeader`，相同就略過 `ATSH`、不浪費
頻寬，而且**只在轉接器確認之後**才把 `_currentHeader` 更新成新值 —— 一次沒被
承認的切換若被逕自記成已生效，下一次查詢會用錯的標頭，而且不會再送 `ATSH`
去修正它。

這裡原本寫的是 `client.setHeader()`。`lib/` 全樹沒有這個名字 —— round 2 就換成
上面這條路徑，文件留在原地。維護者要查這段行為，第一個動作就是 grep 那個名字，
然後什麼都找不到。

`sendAddressed` 上游還有一道閘門，是 §3.3 寫成時還不存在的：`PollingEngine`
在 `!addressing.shouldTransmit(header) && !BusAddressing.isAppDefault(header)`
時把該 PID 直接標為錯誤，而**不是**改用預設標頭去問別的控制器。上面
`ATSH 7E0` 那一條說明了為什麼三個十六進位字元的標頭在非 11-bit CAN 上沒有
意義；這道閘門是同一個判斷在逐請求層級的執行點。從錯的 ECU 拿到的數字，跟從
對的 ECU 拿到的長得一模一樣。

### 3.4 連到非 ELM327 裝置時要快速失敗

實測把 App 連到一台 Galaxy Tab S（BLE）：連線成功、特徵值探索成功、握手開始，然後每一個 AT 指令逐一逾時 —— 15 步跑完要接近一分鐘，使用者只會覺得 App 壞了。

**處理**：`Elm327Client._runInitSequence()` 在第一個關鍵步驟失敗後即中止，其餘標記為「已中止」；`ObdSession._describeHandshakeFailure()` 依失敗的是哪一步給出不同訊息 —— 第 0 步（`ATZ`）失敗代表「這可能不是 ELM327」，中途失敗代表「轉接器沒問題，檢查電門」。

### 3.5 `0100` 探測必須排在讀協定之前

`ATSP0` 只是**武裝**自動搜尋，轉接器在第一個真正的 OBD 請求之前不會去試任何
匯流排協定。所以在它之前讀 `ATDP` / `ATDPN`，拿到的是 `AUTO` / `A0` ——
「還沒決定」—— 而下游每一件事都會建立在一個從未被決定的協定上。

更糟的是 `A0` 會被解析成 0，DTC decoder 把 0 讀成舊式匯流排，於是一台 CAN 車
的故障碼用錯誤的框架佈局解出來，**報出它根本沒有的故障碼**。這是整份文件裡
最嚴重的一種失效：一個看起來合理、可以照著去修車的錯數字。

`0100` 同時是整條序列裡唯一能證明「車在那裡」的一步。所有 AT 指令在電門關著
時都會愉快地回答，因為它們只跟轉接器說話；`0100` 不會。

**處理**：`Elm327Client.initSequence` 在 `ATRV` 之後插入 `0100`，標為 critical
並以 `_requireSupportMask` 驗證，`ATDP` / `ATDPN` 一律排在它後面。這是整條初始
化序列裡後果最重的一項排序決定，而筆記完全沒有提到它。

---

## 4. 這份文件的邊界

本 App 的 OBD2 實作在 `lib/obd/`。上面每一條偏離都是刻意的：筆記是起點，
SAE J1979 與 ELM327 datasheet 是裁決者，兩者衝突時以後者為準，而理由留在這裡
和程式碼註解兩個地方 —— 因為只留一處的那一半，就是會被下一輪「順手修好」的
那一半。

筆記另外附了一組跨語言的參考實作。它們照抄了筆記，包括上面判定為有害的那幾
條，而測試依然全綠，因為它們的 mock transport 對每一個 AT 指令都回 `OK`，不
模擬任何一種失敗。那組實作彼此鏡射的規則**不適用於本 App 的程式碼**：這裡修
正過的東西不會、也不應該被搬回去對齊。

---

## 5. BLE 套件：為什麼不是大家都在用的那一個

`flutter_blue_plus` 是 Flutter 生態裡事實上的標準 BLE 套件，這個 App 一開始也用它。
**2026-08-18 換成 [`universal_ble`](https://pub.dev/packages/universal_ble)（BSD-3-Clause）。**
會有人問為什麼捨標準取冷門，理由記在這裡，不要再換回去而不先讀完這段。

`flutter_blue_plus` 2.3.12 的 LICENSE 不是 BSD，是自訂的 source-available 授權。
Section 3 逐字寫著：

> Any use of FlutterBluePlus by or for a for-profit company or corporation —
> **including commercial use by individuals** — requires the purchase of a
> commercial license

Section 3.3 進一步把「開發、測試、評估」也算成商業使用。這個 App 在 Google Play 上是
US$4.99 的付費 App，所以程式碼裡原本宣告的 `License.nonprofit` 是**假的** —— 那不是
風格問題，是對授權條款的不實陳述。

另有一條較少被提到但對這個 App 特別刺眼的：Section 1.4 保留在 **build 時送出遙測**的
權利（package name、app name、版本、日期）。它發生在建置階段、不涉及使用者資料，因此
不影響隱私權政策的正確性 —— 但一個把「不收集任何資料」放在首頁的 App，依賴一個保留這種
權利的套件，至少該是被知情選擇的，而不是沒人讀過授權。

兩條路：買 Starter tier 商業授權，或換掉。選了換掉。`universal_ble` 是 BSD-3-Clause，
無商業條款、無遙測，平台覆蓋（Android / iOS / macOS）與此 App 的目標一致，
`minSdk 21` / iOS 13.1 / macOS 10.15 都在既有範圍內，合併後的 `AndroidManifest.xml`
權限集合**完全不變**（兩個套件宣告的都只有帶 `maxSdkVersion="30"` 的舊式
`BLUETOOTH` / `BLUETOOTH_ADMIN`）。

換的過程中有四個行為差異必須處理，都留了測試（`test/ble_transport_test.dart`）：

| 差異 | 若照抄舊寫法會怎樣 |
|---|---|
| notify 與 indicate 是**兩個**不同的 subscribe 呼叫，各自在特徵值缺對應 property 時 throw | 只叫 `notifications.subscribe()` 會把整個「只支援 indicate」的轉接器家族擋在門外 |
| `BleDevice.name` 在建構子裡就把非 ASCII 字元剝光 | 每一個中文命名的轉接器都顯示成「未命名裝置」 |
| `scanStream` 逐則廣告發射，不是累積後的清單 | 消費端若用 append 而非 by-id upsert，同一台會重複列出 |
| MTU 從 `connect()` 的參數變成連線後的獨立請求 | 舊寫法下協商失敗會讓**整條連線**失敗；現在只損失吞吐量 |

換套件本身沒有損失已驗證的覆蓋率：BLE 路徑從來沒有對真實 ELM327 硬體驗證過
（見 `docs/verification/device-verification.md`）。反而是這次換出的介面接縫（`UniversalBle.setInstance`）
讓 `BleTransport` 第一次有了單元測試 —— 以前那些只能寫在註解裡的宣稱，現在有東西釘住。
