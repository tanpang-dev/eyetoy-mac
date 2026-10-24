# EyeToy Cam for Mac — first draft

最初に動いた版の仮想カメラを、記録として残したブランチです。普段使うなら [main](https://github.com/tanpang-dev/eyetoy-mac) を使ってください。

main との違い:

- 形式は 640×480・15fps の 1 つだけ
- OV519 のセンサークロック（レジスタ `0x59`）は Linux gspca と同じ既定値のまま。そのためセンサーは定格の半分の速さで動いている
- 320×240・60fps モード、レジスタ総当たりツール、fps 計測ツールはない
- ホストアプリは結果をログに出すだけ（ダイアログなし）

ビルド方法は main と同じです（`DEVELOPMENT_TEAM=<チームID> xcodegen generate` のあと `xcodebuild`）。ライセンスは GPL-2.0-or-later です。
