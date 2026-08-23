[English](README.md) | **繁體中文**

# Telltale

[![CI](https://github.com/ImL1s/telltale/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ImL1s/telltale/actions/workflows/ci.yml)
[![最新版本](https://img.shields.io/github/v/release/ImL1s/telltale?include_prereleases&sort=semver&label=latest%20release)](https://github.com/ImL1s/telltale/releases)
[![授權：GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Telltale 是開放原始碼 Flutter App，透過 ELM327 相容轉接器提供即時車輛遙測與
OBD2 故障診斷。它的設計原則是誠實呈現不確定性，不把格式錯誤、不完整或互相衝突
的回應包裝成看似可信的結果。

> **一個看起來合理的錯數字，比沒有數字更糟。**

## 下載與安裝

**[前往 GitHub Releases 下載 APK](https://github.com/ImL1s/telltale/releases)。**
打開最新的 prerelease，選擇其中的 `.apk` 檔；原始碼目錄不會保存 release 產物。

GitHub APK 使用社群簽章，無法更新 Google Play 版，也無法由 Play 版直接更新。
兩者互換時必須先解除安裝；解除安裝會刪除 App 本機資料，請先匯出需要保留的內容。

## 支援功能

- Bluetooth Classic（RFCOMM/SPP）
- Bluetooth LE（GATT UART service）
- Wi-Fi 轉接器的區域 TCP 連線
- 不需轉接器或車輛的內建 Demo ECU
- 即時 PID 儀表、故障碼、凍結幀、排放就緒、自訂 PID，以及由使用者主動匯出
  的診斷紀錄

Android 是裝置、UI 與 BLE rig 路徑的主要實體測試平台。iOS 與 macOS 目前只有
編譯閘門，不能視為具備同等的實體轉接器或實車證據。Bluetooth Classic 實務上
只支援 Android，因為 Apple
平台不向一般第三方 App 開放通用 RFCOMM/SPP 配件。

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
這證明該路徑上的實體 BLE 掃描、GATT 連線、UART 寫入與通知，但**不代表**已驗證
CAR25 等購入轉接器、其韌體或 profile、ECU/CAN 匯流排或任何實車。

驗證文件只描述有邊界的證據，不是認證或安全保證。請先閱讀
[測試證據](docs/verification/test-evidence.md)與
[裝置驗證](docs/verification/device-verification.md)。

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
