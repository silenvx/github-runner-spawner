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

1. Docker イメージをビルド（キャッシュ利用）
2. 指定数のコンテナを起動（各コンテナが独立した runner）
3. 各 runner は `--ephemeral` で登録 → 1ジョブ実行 → コンテナ自動終了
4. 終了を検知 → 新しいトークンで新コンテナを再起動
5. Ctrl+C で全コンテナを停止・削除

## Docker イメージ

`docker/Dockerfile` でビルドされるイメージの構成：

- **ベース**: Ubuntu 24.04 (arm64)
- **プリインストール**: Node.js 22 (bootstrap用), git, curl, jq, build-essential, shellcheck, unzip 等
- **GitHub Actions Runner**: v2.331.0

`setup-node`, `setup-bun` 等の Actions はイメージのツールをブートストラップとして使い、
ワークフローで指定されたバージョンで上書きする。

### イメージの再ビルド

Runner バージョンを更新する場合：

```bash
docker build --build-arg RUNNER_VERSION=2.332.0 -t gh-runner docker/
```

## 補助スクリプト

- `cleanup-runners.sh` - GitHub に残った offline ランナーの削除
