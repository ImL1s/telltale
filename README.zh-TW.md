[English](README.md) | **繁體中文**

# Telltale

[![CI](https://github.com/ImL1s/telltale/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ImL1s/telltale/actions/workflows/ci.yml)
[![最新版本](https://img.shields.io/github/v/release/ImL1s/telltale?include_prereleases&sort=semver&label=latest%20release)](https://github.com/ImL1s/telltale/releases)
[![授權：GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Telltale 是開放原始碼 Flutter App，透過 ELM327 相容轉接器提供即時車輛遙測與
OBD2 故障診斷。它的設計原則是誠實呈現不確定性，不把格式錯誤、不完整或互相衝突
的回應包裝成看似可信的結果。

> **一個看起來合理的錯數字，比沒有數字更糟。**

## App 截圖與實車示範

<p align="center">
  <img src="https://raw.githubusercontent.com/ImL1s/telltale/main/store/01-connect.png" width="30%" alt="Telltale 連線方式畫面">
  <img src="https://raw.githubusercontent.com/ImL1s/telltale/main/store/02-dashboard.png" width="30%" alt="Telltale 即時遙測儀表板">
  <img src="https://raw.githubusercontent.com/ImL1s/telltale/main/store/03-dtc-freeze.png" width="30%" alt="Telltale Demo ECU 故障碼與凍結幀畫面">
</p>

[![觀看 Toyota GT86 與 BLE ELM327 隱私遮蔽示範](https://raw.githubusercontent.com/ImL1s/telltale/main/store/feature-1024x500.png)](https://youtu.be/Ugyg4RXhjVQ)

**[在 YouTube 觀看 Toyota GT86 與 BLE ELM327 實車示範](https://youtu.be/Ugyg4RXhjVQ)。**
影片記錄一組 Samsung 手機、轉接器與車輛的實際連線，實車 VIN 已遮蔽；這是該組合
的實測證據，不代表所有手機、轉接器或車輛都相容。

## 下載與安裝

**[前往 GitHub Releases 下載 APK](https://github.com/ImL1s/telltale/releases)。**
打開最新版本，選擇其中的 `.apk` 檔；原始碼目錄不會保存 release 產物。

GitHub APK 使用社群簽章，無法更新 Google Play 版，也無法由 Play 版直接更新。
兩者互換時必須先解除安裝；解除安裝會刪除 App 本機資料，請先匯出需要保留的內容。

## 支援功能

- Bluetooth Classic（RFCOMM/SPP）
- Bluetooth LE（GATT UART service）
- Wi-Fi 轉接器的區域 TCP 連線
- 不需轉接器或車輛的內建 Demo ECU
- 即時 PID 儀表、故障碼、凍結幀、排放就緒、自訂 PID，以及由使用者主動匯出
  的診斷紀錄
- 每組車輛設定都套用安全確認流程：未確認車重、VE、風阻與驅動方式前，
  車輛有回覆的 OBD 實測值仍可顯示，但不會用通用預設值冒充實車的馬力、扭力或油耗；
  每次重新連線都會自動失效，避免把上一台車的設定套到下一台

Android 是裝置、UI 與 BLE rig 路徑的主要實體測試平台。iOS 與 macOS 目前只有
編譯閘門，不能視為具備同等的實體轉接器或實車證據。Bluetooth Classic 實務上
只支援 Android，因為 Apple
平台不向一般第三方 App 開放通用 RFCOMM/SPP 配件。

## 已實車連線的轉接器

維護者已用 **CARLZS LAB CL-OBDII-M25B**（`OBDBLE`、NCC
`CCAH22LP5300T8`）透過 Bluetooth LE 讓 Telltale 連接 Toyota GT86。同一支
Samsung `SM-S9280` 目前仍保留一份日期為 2026-08-27、大小 418,028 bytes 的
Telltale 復原工作階段紀錄。

**[在蝦皮查看這支轉接器](https://s.shopee.tw/3LQPiOY7uv)** —— 這是維護者的推廣
分潤連結；符合條件的購買可能讓維護者取得佣金，你也可以自行搜尋或向其他通路購買
同型號。

這只代表一組轉接器、手機與車輛的實際觀察，不是認證，也不保證同一賣場的所有
版本、所有手機、車輛、PID 或韌體行為相同。購買前請核對完整型號與 NCC 號碼；
證據邊界見[硬體相容性說明](docs/hardware-compatibility.md)。

## 建置與測試

使用固定的 Flutter 3.47.0 工具鏈：

```bash
git clone https://github.com/ImL1s/telltale.git
cd telltale
FLUTTER="$HOME/fvm/versions/3.47.0/bin/flutter"
"$FLUTTER" pub get
"$FLUTTER" analyze
"$FLUTTER" test
"$FLUTTER" build apk --debug --flavor field
```

若要建立自行簽章的 release，請依照
[維護者 release 指南](docs/maintainers/release.md)。`field` flavor 才是實際使用的
App；隔離的 `rig` flavor 是測試基礎設施。

## 驗證邊界

Samsung 實體手機到 Mac 的 BLE GATT 無線路徑，已搭配模擬 ELM327 peripheral 通過。
這證明該路徑上的實體 BLE 掃描、GATT 連線、UART 寫入與通知。上面的實車觀察則
另外證明一組購入的 CL-OBDII-M25B 曾讓 Telltale 連上 Toyota GT86，並留下足量的
工作階段紀錄。原始實車紀錄可能含 VIN 與裝置識別資訊，因此未公開，只在本機做過
去識別化分析。分析確認該次工作階段使用 CAN 11-bit/500 kbit/s，且保留的閒置輪詢
沒有 `NO DATA`、CAN/BUS error、逾時或格式錯誤；但中段紀錄因容量上限大量捨棄，
所以這項觀察**不代表**已認證轉接器韌體、PID 準確度、DTC 涵蓋率、道路負載行為
或所有 GT86。

驗證文件只描述有邊界的證據，不是認證或安全保證。請先閱讀
[測試證據](docs/verification/test-evidence.md)、
[裝置驗證](docs/verification/device-verification.md)，以及逐層列出可重現與商用測試設備
的[驗證馬具矩陣](docs/verification/rig-matrix.md)。

## 專案目錄

| 路徑 | 用途 |
| --- | --- |
| `lib/` | App、狀態、UI、ELM327 協定與 transports |
| `test/` | 單元、契約、parser 與 widget 測試 |
| `integration_test/` | 裝置與隔離 rig 流程 |
| `tool/` | 可重現的模擬器與驗證工具 |
| `android/`、`ios/`、`macos/` | 平台整合 |
| `assets/` | 內附字型與圖示 |

## 文件

| 文件 | 用途 |
| --- | --- |
| [文件索引](docs/README.md) | 所有使用、證據與維護者文件 |
| [實車指南](docs/field-guide.zh-TW.md) | 安全的實車流程與故障排除 |
| [協定差異](docs/protocol-deviations.zh-TW.md) | 標準查證與硬體行為註記 |
| [版本紀錄](CHANGELOG.md) | 各版本可見變更 |
| [貢獻指南](CONTRIBUTING.md) | 開發與 pull request 要求 |

## 隱私與安全使用

Telltale 不會主動上傳資料。本機診斷匯出可能含 VIN、裝置、轉接器與故障識別資訊；
匯出與分享由你主動控制，作業系統備份也可能依裝置設定複製 App 私有資料。請閱讀
[專案內政策](PRIVACY.md)或
[已發布的隱私權政策](https://iml1s.github.io/telltale/privacy.html)。

請只在停妥時操作，或交由乘客操作。清除 DTC 前先保存診斷證據，也不要以本 App
取代專業檢查。安全漏洞請依 [SECURITY.md](SECURITY.md) 私下回報；社群互動規範見
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 授權與聲明

歡迎依[貢獻指南](CONTRIBUTING.md)參與。Telltale 採
[GPL-3.0](LICENSE) 授權，與 Ian Hawkins 的 Torque / Torque Pro 無關，也不是其
官方或衍生版本。請自行承擔使用風險；任何診斷結果都不保證車輛可安全行駛。
