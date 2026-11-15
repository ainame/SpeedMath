# スピードけいさん (SpeedMath)

小学生向けのスピード計算（計算カード）アプリです。算数セットの計算カードと同じ 4 種類のデッキをシャッフルして 1 枚ずつ表示し、最後までの時間を計ります。

**▶ https://speedmath.ainame-apps.workers.dev**

Swift で書かれていて、WebAssembly としてブラウザで動きます。

## つかいかた

1. デッキを選ぶ
2. 枚数（45 まい / ぜんぶ）、タイマーの表示、0 の計算を入れるかを選ぶ
3. 「スタート！」→ カードの答えを口で言って、合っていたら次へ

| 操作 | キーボード | タッチ |
|---|---|---|
| つぎ | → / スペース | 画面の右半分をタップ |
| まえ | ← | 画面の左半分をタップ |

スマホは横向きで使う想定です。タイマーを「かくす」にしても時間は計っていて、最後に表示されます。

最後まで通すと、今日のスタンプカードにまだないスタンプがランダムで 1 つもらえます（6 種類、重複なし）。トップの「スタンプ」で今日のカード、「きろく」で今日の記録（時刻・計算の種類・枚数・0 あり/なし・かかった時間）を見られます。どちらもブラウザの localStorage に保存され、毎日 0 時にリセットされます。スタンプはこのリポジトリのオリジナル SVG（`public/stamps`）です。

## デッキ

| デッキ | 範囲 | 枚数（0 なし / 0 あり） |
|---|---|---|
| たしざん くりあがり なし | 1+1 〜 9+1（0 ありで 1+0 〜 9+0 も） | 45 / 54 |
| ひきざん くりさがり なし | 2−1 〜 10−9（0 ありで 1−1 〜 9−9 も） | 45 / 54 |
| たしざん くりあがり あり | 2+9 〜 9+9 | 36 |
| ひきざん くりさがり あり | 11−2 〜 18−9 | 36 |

## 開発

- [ElementaryUI](https://github.com/elementary-swift/elementary-ui)
- [elementary-router](https://github.com/ainame/elementary-router)（実験的なルーター、ハッシュルーティング）
- [Vite](https://vite.dev/) + [vite-plugin-swift-wasm](https://github.com/elementary-swift/vite-plugin-swift-wasm)

必要なもの: Swift 6.4 と同じバージョンの Swift SDK for WebAssembly、pnpm、（任意）wasm-opt

pnpm 10.34.9 をインストールしてください。`pnpm install` がプロジェクト用 Node.js を取得します。

```sh
pnpm install --frozen-lockfile
pnpm run dev      # 開発サーバー（Swift の変更でホットリロード）
pnpm exec cf build # Cloudflare 向けビルド（Embedded Swift）
```

Cloudflare CLI は beta です。`pnpm exec cf auth login` でログイン後、`pnpm exec cf deploy` で Worker をビルド・公開できます。`cf deploy --dry-run` はアップロードせずに検証します。設定は `cloudflare.config.ts` です。

`main` に push すると GitHub Actions がビルドとテストを行い、Cloudflare Workers（`speedmath`）に公開します。secrets は `CLOUDFLARE_API_TOKEN`（`speedmath` の Workers Editor）と `CLOUDFLARE_ACCOUNT_ID` です。旧 GitHub Pages 版（https://ainame.github.io/SpeedMath/）は最後のビルドのまま残っていますが、更新されません。

全体の構成（アプリ、リモコンの通信、Worker と Durable Object、ビルドと公開）は [docs/architecture.md](docs/architecture.md) にまとめています。

[elementary-swift/starter-vite](https://github.com/elementary-swift/starter-vite) テンプレートから作成しました。

## ライセンス

[MIT](LICENSE)

## リモコン

1. こどものがめんのトップで、タイトルの左の「リモコン」をおします。QR コードとコードが出ます。
2. おとなの スマホで QR コードを読みます（カメラがつかえないときは、リモコンの画面にコードを入れます）。
3. 両方の画面の文字が同じなら、こどものがめんで「つなぐ」をおします。こどものがめんはトップにもどり、「リモコン ✓」が出ます。
4. つながっているあいだは、カードえらび・スタート・はじめる・もういちど・えらびなおす（やめる）をリモコンでおこないます。こどものがめんでは えらべませんが、カードの「まえ」「つぎ」は どちらでも うごかせます。答えはリモコンだけに出ます。
5. はずすときは、こどものがめんのトップで「リモコン ✓」をおして「リモコンを はずす」をえらびます。

招待は 2 分、切断後の再接続の猶予は 10 分です。記録とスタンプはこどものがめんに残ります。リモコンには同じサイトの Worker が必要です。

### 検証とステージング

```sh
swift test
pnpm exec cf build --mode staging
pnpm exec node Scripts/check-build.mjs staging
pnpm exec cf deploy --prebuilt --mode staging --dry-run
pnpm run test:worker
pnpm exec playwright install chromium
pnpm exec playwright test
```

`pnpm run test:worker` は Durable Object を workerd なしで直接動かし、コード衝突と alarm の再実行を確かめます（`cf build` が作る `worker/generated/logic.wasm` が必要）。Worker を JavaScript のまま残している理由は [docs/decisions/0001-worker-without-async-await.md](docs/decisions/0001-worker-without-async-await.md) にあります。

作業ブランチと PR の CI はテストと dry run を行います。ステージングへの公開は `staging` ブランチだけが対象で、`CLOUDFLARE_STAGING_API_TOKEN` を使います。本番への公開は `main` だけが対象です。

ステージングでリモコンを止める場合は `cf build --mode staging-solo` で、SQLite のクラスを保持した一人プレイ用の成果物を作ります。 `node Scripts/check-build.mjs staging-solo` と `cf deploy --prebuilt --mode staging-solo --dry-run` で確認し、ステージングにだけ公開します。再開には `staging` 成果物を再公開します。旧サイトの停止や URL 切り替えは別の作業です。
