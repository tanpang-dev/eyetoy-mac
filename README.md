# EyeToy Cam for Mac

PS2 の EyeToy（USB カメラ）を、Mac で普通の Web カメラとして使えるようにする Camera Extension です。FaceTime・Photo Booth・QuickTime・OBS などで「EyeToy」を選ぶと映ります。

- 640×480・20fps（既定）と、PS2 と同じ 320×240・60fps の 2 つの形式
- マイクは macOS 標準のドライバでそのまま使えます（入力に「Logitech EyeToy USB Camera」を選ぶ）
- 対応機種: `054c:0154`（Logitech EyeToy USB Camera）、`054c:0155`。中身は OV519 + OV7648

## 必要なもの

- Mac（Apple Silicon、macOS 13 以降。macOS 27 で確認）
- Xcode と [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- Apple Developer アカウント（System Extension の署名に必要）

## ビルドとインストール

```sh
DEVELOPMENT_TEAM=<あなたのチームID> xcodegen generate
xcodebuild -project EyeToyCam.xcodeproj -scheme EyeToyCam -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
ditto build/Build/Products/Debug/EyeToyCam.app /Applications/EyeToyCam.app
/Applications/EyeToyCam.app/Contents/MacOS/EyeToyCam activate
```

システム設定 → 一般 → ログイン項目と機能拡張 → カメラ拡張機能 で「EyeToy」をオンにします。外すときは `EyeToyCam deactivate` です。

版を上げて入れ替えた場合は、Mac を再起動するまで新しい版が起動しません（古い版が「再起動時にアンインストール」待ちで残るため）。

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
