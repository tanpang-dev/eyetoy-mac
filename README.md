# EyeToy Cam for Mac

PS2 の EyeToy（USB カメラ）を、Mac で普通の Web カメラとして使えるようにする Camera Extension です。FaceTime・Photo Booth・QuickTime・OBS などで「EyeToy」を選ぶと映ります。

- 640×480・20fps（既定）と、PS2 と同じ 320×240・60fps の 2 つの形式
- マイクは macOS 標準のドライバでそのまま使えます（入力に「Logitech EyeToy USB Camera」を選ぶ）
- 対応機種: `054c:0154`（Logitech EyeToy USB Camera）、`054c:0155`。中身は OV519 + OV7648

## 必要なもの

- Mac（Apple Silicon、macOS 13 以降。macOS 27 で確認）
- ソースからビルドする場合: Xcode と [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- ソースからビルドする場合: Apple Developer アカウント（System Extension の署名に必要）

## インストール（ダウンロード版）

1. [Releases](https://github.com/tanpang-dev/eyetoy-mac/releases/latest) から `EyeToyCam-x.y.z.zip` をダウンロードして開きます。
2. 出てきた `EyeToyCam.app` を「アプリケーション」フォルダに移します。
3. `EyeToyCam.app` をダブルクリックします。
4. 案内が出たら、システム設定 → 一般 → ログイン項目と機能拡張 → カメラ拡張機能 で「EyeToy」をオンにします。
5. EyeToy を挿して、カメラアプリで「EyeToy」を選べば映ります。

アプリは Apple の公証（notarization）済みです。外すときは、ターミナルで `/Applications/EyeToyCam.app/Contents/MacOS/EyeToyCam deactivate` を実行します。新しい版に入れ替えたときは、Mac を再起動すると切り替わります。

## ビルドとインストール（ソースから）

自分で手を入れたいときは、自分の Apple Developer アカウントで署名してビルドしてください。

### 1. 準備

1. Xcode を App Store から入れて一度起動し、Xcode → Settings → Accounts で Apple ID（Developer アカウント）にサインインします。
2. XcodeGen を入れます。

   ```sh
   brew install xcodegen
   ```

3. 自分のチーム ID（英数字 10 文字）を調べます。[developer.apple.com/account](https://developer.apple.com/account) の「メンバーシップの詳細」に載っています。次のコマンドで出てくる括弧内の値でもかまいません。

   ```sh
   security find-identity -v -p codesigning
   ```

### 2. ビルドしてインストール

```sh
git clone https://github.com/tanpang-dev/eyetoy-mac.git
cd eyetoy-mac
export DEVELOPMENT_TEAM=XXXXXXXXXX   # 自分のチーム ID に置き換える

xcodegen generate
xcodebuild -project EyeToyCam.xcodeproj -scheme EyeToyCam -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
ditto build/Build/Products/Debug/EyeToyCam.app /Applications/EyeToyCam.app
/Applications/EyeToyCam.app/Contents/MacOS/EyeToyCam activate
```

`-allowProvisioningDeviceRegistration` は、使っている Mac を Developer アカウントに自動で登録します（開発用の署名で拡張機能を動かすのに必要です）。

### 3. 許可する

システム設定 → 一般 → ログイン項目と機能拡張 → カメラ拡張機能 で「EyeToy」をオンにします。EyeToy を挿して、カメラアプリで「EyeToy」を選べば映ります。

- 外すとき: `/Applications/EyeToyCam.app/Contents/MacOS/EyeToyCam deactivate`
- 版を上げて入れ替えた場合は、Mac を再起動するまで新しい版が起動しません（古い版が「再起動時にアンインストール」待ちで残るため）。

### よくあるエラー

| エラー | 対処 |
|---|---|
| `PLA Update available` | developer.apple.com にサインインして、新しい規約に同意する |
| `isn't registered in your developer account` | `-allowProvisioningDeviceRegistration` を付けてビルドし直す |
| `No Account for Team` | Xcode の Settings → Accounts でサインインし直す。`DEVELOPMENT_TEAM` の値も確認する |
| `does not appear to belong to any extension categories` | `xcodegen generate` からやり直す（Info.plist が古い） |

### AI に頼む場合

コマンドに慣れていなければ、Claude Code や Codex などのターミナルで動く AI に、次の文をそのまま貼り付けて頼めます。`<チームID>` が分からなければ空のままで大丈夫です（AI が調べ方を案内します）。

```text
https://github.com/tanpang-dev/eyetoy-mac をビルドして、この Mac にインストールしてください。
PS2 の EyeToy を Mac の Web カメラとして使うための Camera Extension です。

私の Apple Developer のチーム ID: <チームID>

進め方:
1. README.md の「ビルドとインストール」に従ってください。
2. 足りないもの（Xcode のサインイン、XcodeGen など）があれば、入れ方を教えてから進めてください。
3. チーム ID が空なら、`security find-identity -v -p codesigning` などで候補を調べて、どれを使うか私に確認してください。
4. Mac を Developer アカウントに登録する操作、/Applications へのコピー、拡張機能の有効化は、それぞれ実行前に私に確認してください。
5. 有効化したら、システム設定で私が許可する場所を案内してください。
6. エラーが出たら README の「よくあるエラー」を見て、原因と対処を説明してください。

注意: EyeToy との通信に libusb は使わないでください（macOS でカーネルパニックを起こします）。
```

## 形式の選び方

形式を指定しないアプリでは 640×480 になります。OBS では映像キャプチャデバイスのプロパティで 320×240・60fps を選べます。

## しくみ

- `ov519_cam.c` … OV519 ブリッジと OV76xx センサーの制御。Linux の gspca `ov519` ドライバからの移植
- `eyetoy_usb.m` … IOUSBHost.framework による isochronous 転送と JPEG フレームの組み立て
- `Extension/` … Camera Extension 本体（Xcode の Camera Extension テンプレートがベース）
- `App/` … 拡張機能を有効化／無効化するだけのアプリ
- `eyetoy_host.m` … デバッグ用のコマンドライン取り込み（`frame_NN.jpg` に保存）
- `eyetoy_sweep.m` … OV519 レジスタの総当たり（結果は `sweep.log`）
- `tools/count.swift` … AVFoundation で実際の fps を測る（ffmpeg の avfoundation 入力は 33fps 前後で頭打ちになるため）

コマンドライン版のビルド:

```sh
clang -fobjc-arc -framework Foundation -framework IOUSBHost -framework IOKit \
  -o eyetoy_host eyetoy_host.m eyetoy_usb.m ov519_cam.c
./eyetoy_host 30          # 640x480 を 30 枚
./eyetoy_host 60 0 30 1   # 320x240 を 60 枚
```

## 開発中にわかったこと

- **libusb は使わないでください。** macOS 27 では、libusb がインターフェースを確保するときに、alt 0 の帯域ゼロ（wMaxPacketSize 0）のエンドポイントを問い合わせて、カーネルパニックを起こしました。IOUSBHost で開いてすぐ alt 4 に切り替え、alt 0 のパイプに触れなければ安定します。
- **OV519 のレジスタ `0x59` はセンサーのクロック分周です**（fps ≈ 120 ÷ 値）。Linux ドライバなどが使っている 4 だと、センサーに 12MHz しか入らず、OV7648 の定格（24MHz で VGA 30fps / QVGA 60fps）の半分の速さになります。2 で 320×240・60fps、3 で 640×480・20fps が出ます。640×480 で 2 にすると映像が来ません。
- 320×240 で 60fps を出すには、センサーをインターレース（`0x28` bit5 = 0）にします。
- 画質が粗く見えるときは、レンズ周りのリングでピントを合わせ、部屋を明るくしてください。

## 参考にしたもの

- Linux gspca `ov519` ドライバ（初期化手順とレジスタ値）
- [macam](https://github.com/smokris/macam64)（旧 Mac 用ドライバ。OV7648 のレジスタ名）
- [PCSX2](https://github.com/PCSX2/pcsx2) の EyeToy エミュレーション（電源投入時のレジスタ値）
- OmniVision OV7640/OV7141 データシート

## ライセンス

GPL-2.0-or-later（Linux カーネルのドライバから移植したコードを含むため）。[LICENSE](LICENSE) を参照してください。
