# GitHub Runner Spawner

GitHub Actions self-hostedを複数まとめて起動

## 必要条件

- [GitHub CLI (gh)](https://cli.github.com/) - 認証済み
- jq, curl, tar

```bash
brew install gh jq
gh auth login
```

## 使い方

```bash
./spawn-runners.sh <repo> <count>
```

```bash
# 5台起動（Ctrl+C で停止+クリーンアップ）
./spawn-runners.sh owner/repo 5

# URL形式でもOK
./spawn-runners.sh https://github.com/owner/repo 5
```

起動後はログがリアルタイム表示されます：

```text
[a1b2c3d4-repo-runner-1] √ Connected to GitHub
[a1b2c3d4-repo-runner-1] 2025-12-31 12:00:00Z: Listening for Jobs
[a1b2c3d4-repo-runner-2] 2025-12-31 12:00:05Z: Running job: Build
[a1b2c3d4-repo-runner-2] 2025-12-31 12:01:00Z: Job Build completed with result: Succeeded
```

### マルチリポジトリ対応

複数リポジトリのランナーを同時に管理できます：

```bash
./spawn-runners.sh owner/repo-A 3
./spawn-runners.sh owner/repo-B 2

./status-runners.sh              # 全リポジトリ表示
./status-runners.sh owner/repo-A # 特定リポジトリのみ
```

### ステータス確認

```bash
./status-runners.sh
```

```text
=== GitHub Runner Status ===

Repository: owner/repo (2/2 online)

  NAME                           STATUS     BUSY   PID      LABELS
  ----                           ------     ----   ---      ------
  a1b2c3d4-repo-runner-1         online     no     12345    self-hosted, macOS, ARM64
  a1b2c3d4-repo-runner-2         online     yes    12346    self-hosted, macOS, ARM64
```

### offlineランナーの削除

GitHubに残っているofflineランナーを削除：

```bash
./cleanup-runners.sh owner/repo
```

## 環境変数

- `RUNNER_PREFIX`: ランナー名のprefix（デフォルト: マシン固有の8文字hash）

```bash
# カスタムprefixを指定
RUNNER_PREFIX=myserver ./spawn-runners.sh owner/repo 5
```

## 動作

1. プラットフォーム検出 (osx-arm64, linux-x64, etc.)
2. 最新ランナーをダウンロード（キャッシュ対応）
3. 登録トークン取得 (`gh api`)
4. 各ランナーを設定・起動（名前: `{prefix}-{repo}-runner-{N}`）
5. ログをリアルタイム表示
6. **Ctrl+C で自動クリーンアップ**（停止+GitHub登録解除+削除）

## ディレクトリ構成

```text
.runners/
├── .prefix                      # マシン固有のprefix (8文字hash)
├── .cache/                      # 共有キャッシュ
│   └── actions-runner-*.tar.gz
└── owner/
    ├── repo-A/                  # リポジトリごと
    │   ├── runner-1/
    │   └── runner-2/
    └── repo-B/
        └── runner-1/
```
