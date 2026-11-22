# GitHub Runner Spawner

GitHub Actions のジョブが来たときだけ self-hosted runner を 1 ジョブ分起動するツール。
待機中のジョブが無いあいだは新しい runner を起動しない。ジョブを取らなかった runner は `idle_timeout` 秒後に止める。

runner は次の 2 種類のプールから起動する。

- `docker`: この Mac の Docker コンテナ。ジョブごとに新しいコンテナで実行し、終われば破棄する
- `windows`: ssh で接続した Windows 機。同時に 1 ジョブだけ実行し、ジョブの前後に作業フォルダ (`_work`) を削除する

## 動作の流れ

1. 設定した repo ごとに、`queued` と `in_progress` の workflow run のジョブを GitHub API で調べる (ETag 付きで、変化が無い応答は rate limit を消費しない)
2. `queued` のジョブの `runs-on` のラベルをすべて持ち、その repo を対象にするプールを、設定ファイルの順に探す
3. 見つかったプールの空きの範囲で、`POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` で 1 回限りの JIT 設定を作り、runner を 1 つ起動する
4. runner はジョブを 1 つ実行すると終了し、GitHub 側の登録も消える
5. `idle_timeout` 秒たってもジョブを取らなかった runner (ジョブが取り消された等) は、登録を消して止める

JIT 設定は runner の認証情報なので、ログ・コマンドライン引数・`docker inspect` に出さない。
ディスパッチャは JIT 設定を子プロセスの stdin に書き、受け側 (`pools/docker/entrypoint.sh`・`pools/windows/run-jit.ps1`) は環境変数 `ACTIONS_RUNNER_INPUT_JITCONFIG` に入れて runner を起動する。
runner はこの値をログでマスクし、ジョブの環境変数からは取り除く。

## 安全のための制限

- public の repo では runner を起動しない。起動時に設定の repo がすべて private であることを確かめ、実行中も毎回確かめる。public の repo に self-hosted runner を置くと、他人の pull request のコードがこの Mac や Windows 機で動くため
- プールごとに対象の repo を列挙する。`runs-on: self-hosted` だけのジョブは複数のプールに当てはまるが、そのジョブの repo を対象にしないプールには回らない
- 1 つの設定ファイルに対してディスパッチャは 1 つしか起動できない (同じジョブに runner を二重に起動しないため)

## 必要条件

- [uv](https://docs.astral.sh/uv/) (または Python 3.11 以上)
- [GitHub CLI (gh)](https://cli.github.com/) - 認証済み。対象 repo の admin 権限と `repo` scope が要る
- `docker` プール: Docker (Docker Desktop / [OrbStack](https://orbstack.dev/) 推奨)
- `windows` プール: 次の準備をした Windows 機
  - Mac から鍵認証で `ssh <host>` できる (OpenSSH Server)
  - [actions/runner](https://github.com/actions/runner/releases) の Windows 版 (`actions-runner-win-x64-*.zip`) を、絶対パスのフォルダに展開してある。パスには空白と `` " ' ` $ ; & | < > % ^ `` を含められない (ssh・scp・cmd.exe に渡すため)。`config.cmd` は実行しない
  - ジョブが使うツール (git 等) を入れてある。ジョブは ssh のセッションで動くため、デスクトップ (GUI) は使えない

## 使い方

```bash
cp config.example.toml config.toml
# config.toml を編集する
./dispatch.py
```

`./dispatch.py --config <path>` で別の設定ファイルを使える。`uv` が無い場合は `python3 dispatch.py` で起動する。

設定の項目は [config.example.toml](config.example.toml) を参照。

起動後はログがリアルタイム表示される:

```text
[2026-01-01 00:00:00 UTC] Watching owner/repo every 15s
[2026-01-01 00:00:10 UTC] [windows-repo-1a2b3c] Started for owner/repo (pool windows)
[2026-01-01 00:00:20 UTC] [windows-repo-1a2b3c] 2026-01-01 00:00:20Z: Running job: build
[2026-01-01 00:03:00 UTC] [windows-repo-1a2b3c] 2026-01-01 00:03:00Z: Job build completed with result: Succeeded
[2026-01-01 00:03:05 UTC] [windows-repo-1a2b3c] Exited (code 0)
```

**Ctrl+C** で新しい runner の起動を止め、ジョブを待っている runner を止める。ジョブを実行中の runner は終わるまで待つ。
もう一度 **Ctrl+C** を押すと、実行中の runner も止める。

## ワークフロー側の設定

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, ephemeral]
  release:
    runs-on: [self-hosted, windows]
```

`docker` プールの runner には、ホストのアーキテクチャのラベル (`X64` / `ARM64`) が自動で付く。
`windows` プールのラベルは設定に書いたものだけが付く。

## Docker イメージ

`docker` プールは起動時と 1 時間ごとに最新の runner のバージョンを調べ、`gh-runner-jit:<version>` をビルドする。
コンテナには repo ごとの named volume (npm cache・Playwright のブラウザ・hook test の slot) をマウントする。

## 補助スクリプト

- `cleanup-runners.sh` - GitHub に残った offline ランナーの削除と、`--volumes` で cache volume の削除

## テスト

```bash
python3 -m unittest
uvx ruff check . && uvx ruff format --check .
```
