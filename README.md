# TLKonjck — ローカルLLM 画面オーバーレイ翻訳 (Windows)

常に最前面に表示される半透明の枠を置き、その下にあるアプリ（ブラウザ、Outlook など）の文字を読み取って、ローカルLLMで翻訳して表示するアプリです。翻訳はすべてローカルで行い、外部の API やクラウドには送信しません。

## 現在の段階: Step 0（環境調査）

アプリ本体はまだありません。まず実機の環境を調べるため、調査スクリプト `tools/env-survey.ps1` を用意しています。

### 実行方法

PowerShell を開き、このリポジトリのフォルダで次を実行します（管理者権限は不要）。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\env-survey.ps1
```

終了すると、カレントフォルダに `env-report-YYYYMMDD-HHMMSS.md` が出力されます。所要時間は、LLM モデル1つあたり 1〜3 分程度です。

- 読み取り専用です。何もインストールせず、設定も変更しません。通信先は `127.0.0.1` だけです。
- Windows の OCR 言語パック一覧（`Get-WindowsCapability`）を見るには管理者権限が必要です。管理者でない場合はその項目だけ省略し、代わりに WinRT OCR で実際に使える言語を調べます。
- レポートにはユーザー名を含むパス（例: `C:\Users\<名前>\...`）が入ることがあります。共有する前に確認してください。

### 主なオプション

| オプション | 説明 |
|---|---|
| `-Only System\|Llm\|Dev\|Ocr` | 指定した項目だけを調べる |
| `-Models qwen2.5:7b,gemma3:4b` | ベンチマークするモデルを指定する（省略時は小さいモデルから最大4つ） |
| `-MaxModels 4` | 自動選択するモデル数の上限 |
| `-WarmRuns 3` | ウォーム状態での計測回数 |
| `-TargetLanguage Japanese` | 翻訳先の言語 |
| `-Ports 11434,1234,...` | 調べるポート（既定: 11434, 1234, 8080, 5000, 8000, 5001, 1337） |
| `-SkipBenchmark` | モデルの検出だけ行い、翻訳テストはしない |

### 調査内容

1. OS のバージョン・ビルド。`WDA_EXCLUDEFROMCAPTURE` に対応しているか。ディスプレイの台数・解像度・DPI スケーリング（Per-Monitor DPI で取得）
2. CPU、RAM、GPU と VRAM（`nvidia-smi` があれば実行）
3. ローカルLLM の実行環境
   - Ollama の CLI（`--version` / `list` / `ps`）と環境変数
   - LM Studio の `lms`
   - 各ポートの `/api/tags`、`/v1/models`、`/api/v0/models`、`/props`
   - 見つかったモデルの量子化とコンテキスト長
4. Python（`py -0p`）、pip、.NET SDK、Node.js、Git、Visual Studio / Build Tools
5. Windows OCR で使える言語と、合成画像での OCR 速度。Tesseract の有無
6. 英語から日本語への翻訳ベンチマーク
   - 計測値: 初回トークンまでの時間（TTFT）、総時間、トークン/秒、3文を並列で送った場合と順に送った場合の比較、GPU オフロード率
   - 訳文もレポートに出力します
