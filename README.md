# mac-transcribe-anything

Mac で再生されている音声（Google Meet、Zoom、ブラウザなど）と自分のマイク音声を、端末内でリアルタイムに日本語で文字起こしする CLI。仮想オーディオドライバは不要で、音声もテキストも外部に送らない。

- システム音声は Core Audio Process Tap で、マイクは AVAudioEngine で取り込む
- 文字起こしは Speech framework の SpeechAnalyzer / SpeechTranscriber（`ja-JP`）で行う
- システム音声は `相手`、マイクは `自分` のラベルで出力する

## 動作環境

- macOS 26 以降、Apple シリコン
- ヘッドホン推奨。エコーキャンセルは使っていないので、スピーカーの音がマイクに回り込むと `自分` として二重に書き起こされる

## インストール

[mise](https://mise.jdx.dev/) の `github:` バックエンドで入れる。

```sh
mise use -g github:sters/mac-transcribe-anything
```

リポジトリが private のあいだは GitHub のトークンが要る。`GITHUB_TOKEN` か `MISE_GITHUB_TOKEN` に、このリポジトリを読めるトークンを設定する（例: `export GITHUB_TOKEN=$(gh auth token)`）。設定がないと GitHub API が 404 を返して失敗する。

手動で入れる場合は [Releases](https://github.com/sters/mac-transcribe-anything/releases) から `transcribe-<version>-darwin-arm64.tar.gz` を取得して展開する。バイナリは公証（notarization）していないので、ブラウザで取得した場合は隔離属性を外す。

```sh
tar -xzf transcribe-*-darwin-arm64.tar.gz
xattr -d com.apple.quarantine transcribe
```

ソースからビルドする場合は `swift build -c release` で `.build/release/transcribe` ができる。

## 使い方

```sh
transcribe                          # すべてのアプリの音声とマイク
transcribe --app us.zoom.xos        # 指定したアプリの音声だけ（複数指定可）
transcribe --output meeting.md      # 出力ファイルを指定
```

Ctrl-C で終了する。

- 標準出力: `[HH:MM:SS] 相手: ...` / `[HH:MM:SS] 自分: ...`。端末では確定前の結果を最下行に表示し、確定すると置き換える
- ファイル: 確定した結果だけを Markdown のリストで追記する。既定は `transcript-YYYYMMDD-HHMMSS.md`

初回は「システムオーディオ録音」と「マイク」の権限を求められる。日本語の音声モデルが未インストールならダウンロードする。
