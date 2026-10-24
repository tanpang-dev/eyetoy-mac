# EyeToy Cam for Mac

PS2 の EyeToy（USB カメラ）を、Mac で普通の Web カメラとして使えるようにする拡張機能です。

- 640×480・20fps（既定）と、PS2 と同じ 320×240・60fps の 2 つの形式
- マイクは macOS 標準のドライバでそのまま使えます（入力に「Logitech EyeToy USB Camera」を選ぶ）
- 対応機種: `054c:0154`（Logitech EyeToy USB Camera）、`054c:0155`。中身は OV519 + OV7648

## 必要なもの

- Mac（Apple Silicon、macOS 13 以降。macOS 27 で確認）
- EyeToy 本体（USB-A 端子なので、USB-C しかない Mac では変換アダプタが要ります）

## インストール

1. [Releases](https://github.com/tanpang-dev/eyetoy-mac/releases/latest) から `EyeToyCam-x.y.z.zip` をダウンロードして開きます。
2. 出てきた `EyeToyCam.app` を「アプリケーション」フォルダに移します。
3. `EyeToyCam.app` をダブルクリックします。
4. 案内が出たら、システム設定 → 一般 → ログイン項目と機能拡張 → カメラ拡張機能 で「EyeToy」をオンにします。
5. EyeToy を挿して、カメラアプリで「EyeToy」を選べば映ります。

アプリは Apple の公証（notarization）済みです。外すときは、ターミナルで `/Applications/EyeToyCam.app/Contents/MacOS/EyeToyCam deactivate` を実行します。新しい版に入れ替えたときは、Mac を再起動すると切り替わります。

## 形式の選び方

形式を指定しないアプリでは 640×480 になります。OBS では映像キャプチャデバイスのプロパティで 320×240・60fps を選べます。

## しくみ（開発者向け）

- `ov519_cam.c` … OV519 ブリッジと OV76xx センサーの制御。Linux の gspca `ov519` ドライバからの移植
- `eyetoy_usb.m` … IOUSBHost.framework による isochronous 転送と JPEG フレームの組み立て
- `Extension/` … Camera Extension 本体（Xcode の Camera Extension テンプレートがベース）
- `App/` … 拡張機能を有効化／無効化するだけのアプリ
- `eyetoy_host.m` … デバッグ用のコマンドライン取り込み（`frame_NN.jpg` に保存）
- `eyetoy_sweep.m` … OV519 レジスタの総当たり（結果は `sweep.log`）
- `tools/count.swift` … AVFoundation で実際の fps を測る（ffmpeg の avfoundation 入力は 33fps 前後で頭打ちになるため）

アプリのビルドには Xcode・[XcodeGen](https://github.com/yonaskolb/XcodeGen)・Apple Developer アカウントが要ります（System Extension の署名のため）:

```sh
DEVELOPMENT_TEAM=<チームID> xcodegen generate
xcodebuild -project EyeToyCam.xcodeproj -scheme EyeToyCam -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

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


## ライセンス

GPL-2.0-or-later（Linux カーネルのドライバから移植したコードを含むため）。[LICENSE](LICENSE) を参照してください。
