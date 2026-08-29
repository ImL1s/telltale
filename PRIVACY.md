# Telltale 隱私權政策

最後更新：2026 年 8 月 29 日

## 一句話版本

**Telltale 本身不收集資料，也不會主動上傳資料。** 沒有帳號、沒有廣告、沒有分析、
沒有當機回報服務。App 唯一主動建立的連線是你設定的 ELM327 轉接器。

---

## 我們收集哪些資料

**沒有。**

Telltale 不會收集個人資料，也不會把任何資料傳送到我們或第三方的伺服器。
我們沒有伺服器。

## App 在你裝置上儲存哪些東西

以下內容會寫入 App 的私有儲存空間，不會傳送到我們的伺服器：

| 內容 | 為什麼 |
|---|---|
| 你的車輛設定（排氣量、車重、風阻係數與逐欄來源等） | 推算馬力與油耗需要；來源資訊用來避免把預設值說成官方規格 |
| 你自訂的 PID 定義 | 這是你寫的東西 |
| 上次使用的轉接器與 Wi-Fi 位址 | 下次不用再找一遍 |
| 介面設定（深色／淺色、儀表樣式） | 記住你的選擇 |
| 診斷紀錄（最後一次連線） | 連不上時可以匯出給人看 |

**診斷紀錄**值得特別說明：它記錄 App 與轉接器之間往返的原始位元組，包括車輛
回報的 VIN 與故障碼。App 不會自行上傳；只有你按下「匯出」時，才會交給你選擇的
其他 App。

Android、iOS 或 macOS 的作業系統備份可能依你的裝置與雲端備份設定，複製 App 的
私有資料。解除安裝會移除裝置上的本機副本，但不一定會刪除作業系統先前建立的備份。
若不希望備份這些資料，請在裝置設定中停用 Telltale 或整台裝置的備份。

## 網路連線

Telltale 需要 `INTERNET` 權限，但**不用來連上網際網路**。它只用來對 Wi-Fi 型
ELM327 轉接器開啟一條 TCP 連線 —— 那是一個區域位址（通常是
`192.168.0.10:35000`），Android 沒有更精確的權限可以表達「只連本地」。

App 不會發出任何其他網路要求。你可以在飛航模式下（開著藍牙）完整使用它。
官方車型目錄與來源 manifest 已包在 App 內；只有維護者更新原始碼快照的工具會下載
官方公開資料，安裝在手機上的 App 不會送出 VIN 或車型搜尋。

## 權限說明

| 權限 | 用途 |
|---|---|
| `BLUETOOTH_CONNECT` | 連線到已配對的 ELM327 轉接器 |
| `BLUETOOTH_SCAN` | 搜尋尚未配對的 BLE 轉接器（宣告 `neverForLocation`） |
| `BLUETOOTH` / `BLUETOOTH_ADMIN` | Android 11 以下的等效權限 |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | **僅限 Android 11 以下**（`maxSdkVersion="30"`）。舊版 Android 把 BLE 掃描歸在位置權限底下，這是系統規定，不是我們要你的位置。App 不讀取、不儲存、不傳送任何位置資訊 |
| `INTERNET` / `ACCESS_NETWORK_STATE` | 連線 Wi-Fi 型轉接器（見上） |

`BLUETOOTH_ADVERTISE` 在本 App 的資訊清單中以 `tools:node="remove"` 明確移除。這個 App
只當客戶端 —— 它連到轉接器，從不讓手機自己變成可被發現的裝置。移除而非單純不寫，是因為
Android 的資訊清單以聯集合併：只要任何一個相依套件宣告了它，不寫就等於預設帶上。
（2026-08-18 實測合併後的資訊清單：目前沒有任何相依套件宣告它，所以這是保險而不是修正。）

## 第三方服務

**沒有。** App 沒有整合任何分析、廣告、當機回報或行銷 SDK。你可以在
[原始碼](https://github.com/ImL1s/telltale) 的 `pubspec.yaml` 裡自行確認相依套件清單。

## 兒童

本 App 不針對兒童設計，也不會在知情的情況下收集兒童資料 —— 事實上它不收集
任何人的資料。

## 付費與退款

Google Play 處理所有付款。我們看不到你的付款資訊。退款依 Google Play 的政策辦理。

## 開放原始碼

Telltale 以 GPL-3.0 授權開放原始碼。本政策所述的每一項，你都可以在
[原始碼](https://github.com/ImL1s/telltale) 中自行驗證 —— 這比任何一份隱私權
政策的文字都更值得相信。

## 變更

本政策若有變更，會更新本頁的日期並在 GitHub 的版本紀錄中留下完整差異。

## 聯絡

有疑問請開 issue：https://github.com/ImL1s/telltale/issues

---

# Telltale Privacy Policy

Last updated: 29 August 2026

## In one sentence

**Telltale itself collects nothing and proactively uploads nothing.** There are
no accounts, ads, analytics, or crash reporting. The only connection the app
initiates is to the ELM327 adapter you configure.

## What we collect

**Nothing.** We have no servers.

## What the app stores on your device

Vehicle profile and its per-field source references, your custom PID
definitions, the last adapter used, interface preferences, and a diagnostic
transcript of the most recent session. These are written to the app's private
storage and are not sent to our servers.

The **diagnostic transcript** records the raw bytes exchanged with the adapter,
including the VIN and fault codes the vehicle reports. The app never uploads it
on its own; pressing Export hands it to another app that you choose.

Android, iOS, or macOS system backup may copy the app's private data according
to your device and cloud-backup settings. Uninstalling removes the local copy
from the device, but may not erase a backup the operating system already made.
Disable backup for Telltale or the device if you do not want this data backed up.

## Network access

The `INTERNET` permission is not used to reach the internet. It opens a TCP
connection to a Wi-Fi ELM327 adapter on a local address — Android has no
narrower permission for "local network only". The app makes no other network
requests and works fully in aeroplane mode with Bluetooth on.

The official vehicle catalog and its source manifest are bundled with the app.
Only the maintainer's source-update tool downloads the public official data;
the installed app does not transmit a VIN or vehicle search.

## Permissions

| Permission | What it is for |
|---|---|
| `BLUETOOTH_CONNECT` | Connecting to a paired ELM327 adapter |
| `BLUETOOTH_SCAN` | Finding an unpaired BLE adapter (declared `neverForLocation`) |
| `BLUETOOTH` / `BLUETOOTH_ADMIN` | The equivalents on Android 11 and below |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | **Android 11 and below only** (`maxSdkVersion="30"`). Older Android files BLE scanning under the location permission. That is the system's rule, not us asking where you are: the app never reads, stores or transmits any location |
| `INTERNET` / `ACCESS_NETWORK_STATE` | Reaching a Wi-Fi adapter (see above) |

`BLUETOOTH_ADVERTISE` is explicitly removed from this app's manifest with
`tools:node="remove"`. This app is a client — it connects to an adapter and never
makes your phone discoverable. Removed rather than merely omitted, because Android
merges manifests by union: one dependency declaring it would be enough to ship it.
(Checked against the merged manifest on 2026-08-18: no current dependency declares
it, so this is insurance rather than a correction.)

## Third-party services

None. No analytics, advertising, crash reporting or marketing SDKs. You can
verify this yourself in `pubspec.yaml` in the [source](https://github.com/ImL1s/telltale).

## Children

This app is not directed at children and does not knowingly collect data from
them — in fact it collects data from no one.

## Payment and refunds

Google Play handles all payments. We never see your payment details. Refunds
follow Google Play's policy.

## Open source

Telltale is GPL-3.0. Every claim in this policy is verifiable in the source,
which is worth more than the policy text.

## Changes

If this policy changes, the date on this page changes with it and the full diff
stays in the GitHub history.

## Contact

https://github.com/ImL1s/telltale/issues
