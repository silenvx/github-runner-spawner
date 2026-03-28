# GitHub Runner Spawner

GitHub Actions self-hosted runner を Docker ephemeral コンテナで起動するツール。
各コンテナは1ジョブ実行後に自動破棄され、毎回クリーンな環境（コールドスタート）でジョブを実行する。

## 必要条件

- Docker (Docker Desktop / [OrbStack](https://orbstack.dev/) 推奨)
- [GitHub CLI (gh)](https://cli.github.com/) - 認証済み

```bash
brew install gh
gh auth login
```

## 使い方

```bash
./spawn-runners-docker.sh <repo> <count>
```

```bash
# 3台並行起動（同時に複数ジョブ処理可能）
./spawn-runners-docker.sh owner/repo 3

# URL形式でもOK
./spawn-runners-docker.sh https://github.com/owner/repo 3
```

起動後はログがリアルタイム表示されます：

```text
[a1b2c3d4-repo-runner-1] √ Connected to GitHub
[a1b2c3d4-repo-runner-1] Listening for Jobs
[a1b2c3d4-repo-runner-1] Running job: CI / ci
[a1b2c3d4-repo-runner-1] Job finished. Respawning...
[a1b2c3d4-repo-runner-1] √ Connected to GitHub
[a1b2c3d4-repo-runner-1] Listening for Jobs
```

**Ctrl+C** で全コンテナを停止・削除。

## ワークフロー側の設定

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, arm64, ephemeral]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running in ephemeral container"
```

## 動作の流れ

1. GitHub API から最新の runner バージョンを取得し、Docker イメージをビルド（同バージョンのイメージが存在すればスキップ）
2. 指定数のコンテナを起動（各コンテナが独立した runner）
3. 各 runner は `--ephemeral` で登録 → 1ジョブ実行 → コンテナ自動終了
4. 終了を検知 → 新しいトークンで新コンテナを再起動
5. 5分ごとに runner バージョンの更新をチェックし、新バージョンがあればイメージを再ビルド（次回 respawn から適用）
6. Ctrl+C で全コンテナを停止・削除

## 補助スクリプト

- `cleanup-runners.sh` - GitHub に残った offline ランナーの削除
