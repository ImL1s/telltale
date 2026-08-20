# 發版程序

這份文件之前不存在。十份文件、兩千多行裡沒有任何一句寫下「怎麼把這個 App 送
上 Google Play」，而下一次上傳**必定會被拒絕**，理由沒有記在任何地方 —— 見
第 1 步。交接的時候第一個踩的就是它。

順序是有意義的：**第 1 步一定要在 build 之前**，第 5 節那道閘門一定要在上傳
之前。中間的步驟可以查著做，那兩個不行。

---

## 1. 先把 `pubspec.yaml` 的 `version:` 往上帶

**在任何 build 之前做這一步。**

`android/app/build.gradle.kts` 的 `versionCode = flutter.versionCode`，也就是說
Android 的 versionCode 完全由 `pubspec.yaml` 第 4 行的 `version: x.y.z+N` 那個
`+N` 決定。今天它是：

```
version: 1.0.0+1
```

而 **versionCode 1 已經被 Google Play 消耗掉了** —— 它已在內部測試軌道發布，
並掛在正式版草稿上。Play 不接受重複的 versionCode，上傳會直接被擋下，訊息是
`Version code 1 has already been used`。所以下一次發版的 `+N` **至少是 `+2`**，
而且只能往上，不能重用、不能倒退。

```bash
# 例：1.0.0+1 → 1.0.1+2
```

版本名（`+` 左邊）是給使用者看的，versionCode（`+` 右邊）是給 Play 排序用的，
兩者不必同步遞增，但 versionCode 必須嚴格遞增。

## 2. 準備簽章

release 簽章材料**依定義不在任何 clone 裡**：`android/.gitignore:12` 忽略
`key.properties`，`:14` 忽略 `**/*.jks`。所以這一步是每台新機器都要做一次的。

```bash
cp android/key.properties.example android/key.properties
```

把 `storeFile` 指向**備份的那個 keystore**（工作副本在 `android/torque-release.jks`，
權限 0600），填入 `storePassword` / `keyAlias` / `keyPassword`。

⚠️ `key.properties.example` 註解裡那條 `keytool -genkey` 指令是給**第一次建立**
keystore 用的。這個 App 已經有 keystore 了，重新產生一把等於斷掉 Play 的簽章
血緣，之後永遠無法更新既有安裝。不要跑它。

確認手上這把是對的：

```bash
keytool -list -v -keystore <你的 keystore 路徑> -alias torque
```

應該看到：

```
擁有者: CN=Torque OBD2, OU=Development, O=ImL1s, L=Taipei, C=TW
簽章演算法名稱: SHA384withRSA
主體公開金鑰演算法: 4096 位元的 RSA 金鑰
SHA256: 36:21:33:C0:04:BE:E5:E4:F4:58:F7:7D:4A:5D:19:99:48:A3:C5:CD:B9:F0:86:8B:E2:7D:6F:5D:91:09:A5:79
```

指紋對不上就是拿錯 keystore，**停下來**，不要「先試試看能不能 build」。

沒有 `android/key.properties` 時，`android/app/build.gradle.kts` 會對任何
release 打包任務丟 `GradleException` 而不是靜靜退回 debug 金鑰。那道閘門是刻意
的，它自己會在訊息裡印出逃生口 `-PallowUnsignedRelease=true` —— 那個逃生口是給
自己裝來用的建置，**產出物永遠不可能更新 Play 上的安裝**。不要為了讓 build 過
而用它。

## 3. Build

```bash
~/fvm/versions/3.47.0/bin/flutter build appbundle --release
```

（工具鏈是 Flutter 3.47.0 / Dart 3.13.0，`flutter` 不在 PATH。）

產物在 `build/app/outputs/bundle/release/app-release.aab`。Play 只收 AAB，
`--release` 的 APK 是給第 5 節那道閘門用的。

## 4. Play 上架身分

這幾個值不要在 console 裡憑記憶重打：

| | |
|---|---|
| applicationId | `com.cbstudio.telltale` |
| 隱私權政策 | `https://iml1s.github.io/telltale/privacy.html` |

隱私權政策那個網址是 **GitHub Pages**，不是 repo 裡的 `PRIVACY.md`。
**不要改成 `github.com/.../blob/...` 形式的網址** —— Play 的抓取端讀不到 GitHub
的 blob 頁，換過去會讓送審前檢查直接擋下，而錯誤訊息不會告訴你原因是這個。

## 4.5 送審之前：確認草稿上掛的是**置換後**的 bundle

**已於 2026-08-18 處理，這一節留著是因為它描述的陷阱會再發生。**

原本掛在正式版草稿上的 bundle 是 **versionCode 1，2026-08-17 建的** —— 那是 BLE 套件
置換**之前**。它裡面是 `flutter_blue_plus`，而該套件的授權 Section 3 明文禁止付費散布
（見 `SPEC_DEVIATIONS.md` §5）。原始碼修好了，那個已上傳的產物沒有：按下送審就會把整個
置換要避免的違規原封不動送出去，被一個按鈕原地復活。

**現況（2026-08-18）**：正式版的有效草稿已換成 **2 (1.0.1)**，由置換後的原始碼建置、
以 Play 上架金鑰（`CN=Torque OBD2`）簽署，讀 bundle 自己的資訊清單確認過是 versionCode 2。
舊的 1 (1.0.0) 仍列在版本清單裡，但不再是會被送出的那一份。

**這一節要留著的規則**，因為同一個陷阱在每次「先改程式碼、之後才送審」時都會重現：

> 修好原始碼**不等於**修好已經上傳的產物。送審前一定要確認草稿上那個 bundle 是從
> 哪一版原始碼建出來的。

送審前的順序：

1. 確認 `grep -n universal_ble pubspec.yaml` 有命中，而 `flutter_blue_plus` 只出現在
   解釋為什麼不用它的註解裡
2. 依第 1 節把 `version:` bump（versionCode 只能往上，1 與 2 都已消耗）
3. 重新 `flutter build appbundle --release`
4. 上傳新 AAB 並確認軌道頁顯示的「有效草稿版本」就是它
5. 走第 5 節的實機閘門，才輪到送審

## 5. 上傳之前：實機走一遍（硬性閘門，不可跳過）

**單元測試全綠 + `flutter analyze` 乾淨 + review 通過，三者加起來也不能取代
這一步。**

release rollout 是不可逆的：按下去那一秒使用者就看到 bug 了。而這個 App 的
測試套件從來沒有連過真的 ELM327、也沒有連過車（見 `TEST_EVIDENCE.md`），所以
「綠燈」能保證的範圍比直覺小得多。

```bash
~/fvm/versions/3.47.0/bin/flutter build apk --release
ADB=~/Library/Android/sdk/platform-tools/adb
$ADB install -r -g build/app/outputs/flutter-apk/app-release.apk
```

裝的必須是 **release** 建置，不是 debug —— 簽章、以及那道會在缺 keystore 時
擋下打包的閘門，都只在 release 才發生。debug build 走的是完全不同的簽章路徑，
它跑得起來不代表你要送上去的那個產物跑得起來。

然後**把 changelog 裡每一條 user-facing 的流程實際走一遍**，確認沒有 crash、
沒有白畫面、沒有視覺 regression。七個畫面至少各進去一次：連線（含 Demo 模擬器）
→ 儀表板 → 效能 → 故障碼（含凍結幀）→ PID 管理 → PID 編輯 → 設定，深淺兩個
主題各一輪。

只有使用者當下明講「這次跳過實機驗證」才能跳過這一節。

## 5.5 你裝的那個 APK，不是使用者會拿到的那個

第 5 節那條 `flutter build apk --release` 產出的東西，**跟 Play 發給測試人員的
產物是兩個不同的檔案**，差在兩個地方，兩個都可能自己壞掉：

**一、簽章。** 這個 App 開了 **Play App Signing**，所以有兩把金鑰：

| | 憑證 | 誰持有 | 用在哪 |
|---|---|---|---|
| 上架金鑰 | `CN=Torque OBD2`，SHA-256 `36:21:33:C0:…:A5:79` | `android/torque-release.jks`，本機 | 簽署**上傳**的 AAB，以及本機 build 的 APK |
| 應用程式簽署金鑰 | 另一組，見 Play Console → 設定 → 應用程式完整性 | Google | 簽署**發下去**的 APK |

對 Android 來說，這兩把金鑰簽出來的是**兩個不同的應用程式**。手機上裝著本機
build（`installerPackageName=null`）時，從內部測試軌道更新會被以簽章不符拒絕；
反過來也一樣。唯一的路是先 `adb uninstall`，而那會連 App 資料一起帶走 ——
自訂 PID、儀表板配置、車輛設定。**這個代價要使用者自己決定，不要替他按下去。**

**二、封裝。** 本機出的是一個 universal APK；Play 收的是 AAB，再由 Play 依裝置
切成 split APK 發下去。ABI 拆分、密度拆分、資源縮減都只發生在後者。所以本機
那顆 APK 能跑，證明的是程式碼會跑，**不是**使用者下載到的那組 split 會跑。

實務上的取捨：日常迭代裝本機 release APK（不掉資料、快），但**正式送審之前，
至少要從內部測試軌道實際安裝一次走過第 5 節的流程** —— 那是唯一一次你摸到的
是使用者真正會拿到的產物。那一次的 uninstall 成本，換的是整批 split 封裝的
唯一一次驗證。

## 6. 兩個 repo：公開那邊已經無法用 `git subtree push` 同步

這個工作區是私有 repo；公開的 `ImL1s/telltale` 只有 `app/` 的內容，放在它的
根目錄。**公開 repo 是衍生物，永遠不要在那邊改程式碼再往回搬。**

而 `git subtree push` **已經不能用了**：telltale 的歷史 SHA 已經跟重新
`git subtree split --prefix=app` 的結果分岔，push 會被 non-fast-forward 拒絕。
唯一能讓它過的是 force-push 一個已經公開、可能已被 clone 的 repo。

實際同步方式是**內容層級的 rsync**，指令記在私有 repo 的維護說明裡。發版前
先確認公開那邊已經同步到位，不要在上架途中才發現這件事 —— 那是最不想分心處理
它的時刻。

---

## 唯一不可復原的資產

**keystore。** 其他每一樣東西都能重建：程式碼在 git 裡、商店素材可以重做、
憑證可以重簽。keystore 不行 —— 弄丟它，這個 `applicationId` 就再也發不出一次
更新，只能改用新的 applicationId 重新上架，既有安裝與評價全部留在原地。

已知的事實：

- 工作副本在 `android/torque-release.jks`（PKCS12、alias `torque`、0600），
  被 `android/.gitignore:14` 忽略，因此**不存在於任何 clone**。
- 憑證有效期到 2056-08-07。
- 身分與指紋見第 2 步。

**尚未記錄的事實：這把 keystore 的離線備份在哪裡。** 整個 repo 裡沒有任何一份
文件寫下來過（`android/key.properties` 本身也不在 clone 裡，所以它不算數）。
擁有者請把備份位置補在這一行下面 —— 一份只存在於一台筆電上的 keystore，跟沒有
備份是同一件事，而發現的時機通常是筆電已經壞掉之後。

> 備份位置：（待填）
