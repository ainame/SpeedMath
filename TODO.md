# SpeedMath リモコン実装計画

Presenter（子どもの画面）が出題・順序・進行・計時・記録を管理する。大人が QR または手入力コードで Remote を接続し、Presenter の承認後に答えを確認しながら前後に進める。既存の一人プレイはネットワークなしで動く。

[構成案の公開ページ](https://speedmath-remote-architecture.s-namai-09.chatgpt.site/) は計画作成時に HTTP 401 を返したため、公開用に保存していた HTML を参照した。Sites の管理情報では最新保存版は第 3 版で、手元の公開用ソースも第 3 版に対応する。ただし配信本文の直接取得はできなかった。以降のチェック項目は実装・検証の予定。

## 事前準備の状況（2026-11-14）

- Cloudflare アカウントは 1 件、`cf` と Cloudflare MCP はこの端末で認証済み。GitHub CLI も認証済み。Workers のサブドメインは `ainame-apps.workers.dev`。
- ステージング Worker `speedmath-staging` は作成済みで、未デプロイ・workers.dev 無効。公開後の候補 URL は `https://speedmath-staging.ainame-apps.workers.dev`。これは稼働確認済み URL ではない。
- 本番 Worker `speedmath` も同じ方法で作成済み（2026-11-14、未デプロイ・workers.dev 無効）。本番用 `CLOUDFLARE_API_TOKEN` は `speedmath` に限定した Workers Editor で作る。
- GitHub repository secret `CLOUDFLARE_ACCOUNT_ID` は設定済み。`CLOUDFLARE_STAGING_API_TOKEN` も登録済み（`speedmath-staging` に限定した Workers Editor）。Secret の存在のみ確認しており、デプロイによる権限検証は未実施。staging 専用 secret は現在の本番 workflow では使われないため、実装時に staging 用の job / Environment と接続する。本番用 `CLOUDFLARE_API_TOKEN` は別途必要。
- Workers 画面に requests 0 / 100,000 per day と表示されていたが、請求情報 API は権限不足のためプラン未確認。必要に応じて本人が Dashboard で確認する。

## 実装前に本人が済ませること

- [ ] Cloudflare Dashboard で対象アカウント、Workers の利用可否、利用プランを確認する。初回の `workers.dev` サブドメイン設定が必要なら済ませる。既存設定上の本番名は `speedmath`、ステージング名の候補は `speedmath-staging`。実装担当に使ってよいアカウントとステージング名を伝える。カスタムドメインは使う場合に設定する。
- [ ] Codex が使う環境に Cloudflare 認証を用意する。同一端末なら `pnpm exec cf auth login` でブラウザー承認し、`pnpm exec cf auth whoami` で対象アカウントを確認する。別の実行環境や CI では対象アカウントに制限したデプロイ権限のトークンを安全に設定する。新規 Worker と DO の作成が必要なら、その権限も対象アカウントで確認する。値はチャットやリポジトリに書かない。認証なしでローカル実装・テスト・dry run を進められる。[cf の認証](https://developers.cloudflare.com/cf/get-started/)・[CI での認証](https://developers.cloudflare.com/cf/ci/)
- [ ] GitHub Actions から公開する前に `CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を GitHub Secrets に登録する。現行の `.github/workflows/deploy.yml` はリポジトリ secrets を参照する。ステージングと本番の環境別 secrets を使う場合は、それぞれの Environment を参照するよう workflow も更新する。2026-11-14 時点で `CLOUDFLARE_ACCOUNT_ID` とステージング専用の `CLOUDFLARE_STAGING_API_TOKEN` は登録済み。対応する staging job が後者を読むようにし、本番用 token は別途設定する。
- [ ] 実機受け入れ用に iPhone と別端末を用意する。別回線での確認には Wi-Fi とモバイル回線を使う。旧 GitHub Pages URL の案内と停止時期を本番切替前に決める。ステージングへの公開範囲を共有し、本番公開・旧サイト停止はそれぞれ実行前に本人の指示を確認する。既存 localStorage のデータはオリジンに紐づくので、新 URL には自動移行されない。必要に応じて移行の要否を判断する。

### セットアップ確認コマンド

```sh
swift --version
swift sdk list
pnpm --version
pnpm install --frozen-lockfile
pnpm exec node --version
pnpm exec cf --version
pnpm exec cf auth whoami
gh auth status
```

`pnpm` は standalone 版 10.34.9 を用意する。Node.js 24.22.0 は `pnpm install` が lockfile に従って取得し、`pnpm exec` 配下で使う。Swift は 6.4.x と同一版の通常 Wasm / Embedded Wasm SDK が必要。新しい環境では [Swift の公式 SDK 手順](https://www.swift.org/documentation/articles/wasm-getting-started.html) と toolchain の配布元でバージョン・checksum を確認する。`wasm-opt` は最適化の比較に必要。CI の具体的な SDK URL・checksum は workflow で確認し、別 SDK を追加するときは公式値を照合する。Codex はブラウザー自動テストの方式を決め、必要な runner・ブラウザーの導入と実行コマンドをリポジトリで再現可能にする。カメラを実機操作できない環境では手入力経路と QR 画像の内容検証で自動化し、物理スキャンは実機受け入れに分ける。

認証済みかは実装開始時に改めて確認する。計画作成時には GitHub CLI、Cloudflare MCP と Cloudflare CLI が認証済みだったが、CI の secret は別に必要。個人端末の認証状態を CI や別環境でも有効とみなさない。

## 現行コードと構成案の差分

- 現行の調査起点は `52f327c`。Cloudflare への静的配信の構成と GitHub Actions はコミット済みで、作業開始時はローカル `main` が `origin/main` より 3 コミット先行していた。Cloudflare 本番が稼働しているかは未確認。調査時点で Worker の入口、DO、QR、通信、共有 reducer はない。
- `cloudflare.config.ts`、Vite、`cf@1.0.0-beta.32` と Cloudflare Vite plugin の固定版を使う。残っている `wrangler.jsonc` は README に記載された移行確認用。構成案の mise・Wrangler 前提を現行ツールで読み替え、Node.js は `package.json` の `devEngines.runtime`、pnpm は `packageManager` に従う。
- `Sources/WebApp/Pages.swift` の `PlaySession` がカードとタイマーを管理し、最終カードから進むと `TodayRecords` と `StampBook` を更新する。`AppRoutes.swift` は hash routing。`Browser.swift` のキー入力とタイマーの attach/detach、`DailyStorage.swift` の localStorage の経路を再利用する。
- [参照 Worker の固定コミット](https://github.com/elementary-swift/example-cloudflare-worker/tree/9be171bd664b70e4a8f347fcba066f2be8b14181) は Swift Wasm への HTTP 委譲の出発点。DO の WebSocket からの再入、hibernation、インスタンス分離を SpeedMath で検証する必要がある。

## Codex が進める実装

進捗（2026-11-14、`codex/remote-control`）：チェック済みは実装とローカル・ステージングでの自動検証が済んだ項目。結果と未確認事項は [REMOTE-VERIFICATION.md](REMOTE-VERIFICATION.md) に記録。Worker は 1.5 の「同期的な Swift 関数境界」を採用し、DO・WebSocket・JSON は JS host、メッセージ種別の中継可否は Embedded Swift の `can_relay`（`Sources/Worker`）が判断する。未チェックの 4 項目は、hibernation の実測、分散した無効コード照会の評価、ログ・メトリクスの記録、本番切替が残っている。

機能実装は作業ブランチで進める。現行の workflow は `main` への push と手動実行で本番に公開するため、ステージングの初回公開前に CI の対象を分ける。PR は認証なしの検証とし、ステージングは対象を選んだ専用ジョブでデプロイする。ステージングの認証待ちでも、ローカルと PR の検証は続ける。

### 1. ベースラインと Worker の PoC

- [x] `swift --version`、`swift sdk list`、`pnpm --version`、`pnpm exec cf --version` を記録し、`pnpm install --frozen-lockfile`、`pnpm run build`、`pnpm exec cf build` を通す。ローカル環境には Swift 6.4.0 と通常・Embedded Wasm SDK がある。CI の Swift 6.4.2 と SDK の組合せは workflow を正として確認し、必要なら Embedded 用 artifact の URL と checksum を検証して追加する。
- [x] `worker/` に JS host adapter、`Sources/Worker` に Swift Wasm ターゲットを追加し、`/api/*` を Worker に先に回す。assets と Worker の両 Wasm 成果物、API の JSON 404、Wasm の MIME、単純な Swift HTTP 応答、コールド起動のサイズと時間を確認する。参照例の experimental 依存は実際に必要なものだけ選び、バージョンを固定する。
- [x] `cloudflare.config.ts` の mode で別名 Worker を選び、JS entrypoint、`assets.runWorkerFirst`、SQLite の `worker.exports`、同じ環境を指す DO binding を追加する。固定 cf の型定義と生成物で確認する。環境から storage・binding の隔離を検証する。[cf 設定](https://developers.cloudflare.com/cf/projects/cloudflare-config/)・[DO の設定](https://developers.cloudflare.com/cf/wrangler/reference/)・[Static Assets](https://developers.cloudflare.com/workers/static-assets/binding/)
- [ ] 1 session に 1 `SessionObject` を割り当て、`ctx.acceptWebSocket`、socket attachment、SQLite、alarm を使った 2 接続の PoC を作る。ローカルで再初期化・復元をテストし、ステージングでアイドル後の実際の hibernation と再デプロイ後の再接続を別々に確認する。異なる 2 session を同時に動かし、Swift の非同期初期化・JS 境界・メモリーが混線しないことを確認する。コールド・ウォーム CPU、メモリー、成果物サイズを記録する。[WebSocket](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)・[Lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/)・[SQLite](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [x] Embedded で境界が成立しなければ、ホスト依存を減らした同期的な Swift 関数境界と、Worker 側のみ通常 Wasm を別々に評価する。いずれも同じ実行条件で検証し、Swift での判断を置き換える必要が出た場合は、成立しなかった条件と設計変更案を記録する。PoC で実証した構成を以降の実装に使う。

### 2. 共通モデルと Presenter の状態遷移

- [x] `Sources/ProtocolModels` と `Sources/SessionLogic` に wire 型・認可判断・純粋な reducer を置く。Swift は Foundation に依存せず、JSON の parse/stringify は JS adapter が担当する。バージョン付きメッセージ種別、長さ、列挙値、整数の範囲、組み合わせ、最大バイト数を定義し、両端で検証する。
- [x] `PlaySession` の状態を `ready → playing → finished` の順で扱う。Presenter のタップ・キーと Remote からの前後移動を同じ直列経路で処理する。シャッフル済みカードとタイマーの正本は Presenter に置き、完了への遷移時だけ記録・スタンプを 1 回反映する。最終カードの次へ、先頭の前へ、途中終了、再プレイ、route の切替、タイマーを隠す設定をテストする。
- [x] `deckVersion`、`epoch`、`stateVersion` と `commandID` を使う。権限・phase・epoch・baseVersion が合う操作だけ適用し、適用済み ID は同じ結果を返す。内容の異なる同一 ID は拒否する。Remote は同時に 1 操作を送信し、ACK を失ったときは同じ epoch と ID で上限付き再送する。履歴は再送窓以上保持し、履歴のない古い操作や stale version には再同期を要求する。スナップショットで経過時間を再校正し、タイマーの毎 tick は送信しない。

### 3. QR と手入力コードによるペアリング

- [x] Presenter に QR と、たとえば `XXXX-XXXX-XXXX` 形式の Crockford Base32 コードを表示する。暗号学的乱数で QR invite と手入力コードを独立生成し、手入力コードは区切り・大文字小文字を正規化する。Remote のトップから「コードでつなぐ」を開けるようにして、カメラなし・許可拒否・同一端末の別タブでも QR を経由せず接続できるようにする。
- [x] QR は長い invite を `/#/remote?invite=…` の fragment 内に置く。Remote が読み取ったら履歴の現在エントリから除去する。手入力コードと QR invite は TLS のリクエスト本文または WSS の初回メッセージで渡し、HTTP URL・アクセスログ・分析に含めない。
- [x] 手入力は正規化コードのハッシュから決まるシャードで session を引く。コード全体・QR invite・ペアリング世代を session DO で再検証する。シャードには照合値・session 参照・世代・期限だけを保存し、衝突時は条件付き予約で採用せず再生成する。異なる DO 間は単一トランザクションにできないので、期限・世代による検証を必須にし、予約だけ成功した場合も TTL と条件付き削除で回収する。予約と session 側の有効化の両方が成立してから表示する。
- [x] 初期値として招待 2 分、再接続猶予 10 分、session 最大 2 時間、Remote 1 台とする。招待を QR とコードで共有する 1 世代として扱い、承認時に両入口を原子的に消費する。拒否・再発行・期限切れで対応する保留要求を閉じ、古い lookup が残っても旧世代は拒否する。無効入力にはコードや session の存在を判別しにくい共通の応答を返す。
- [ ] コード照会・session 作成・接続・メッセージのサイズと頻度を別々に制限する。初期案は送信元ごとにコード照会 5 回/分、招待世代ごとに不正試行 5 回で再発行、保留要求は 1 件。送信元制限は分散するエッジでの補助とし、session 内の上限は DO で整合性を保つ。送信元が分散した場合の無効コード照会の上限・短い backoff・正規利用への影響を PoC で評価する。[Cloudflare Rate Limiting binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [x] 保留接続に承認要求 ID と双方に表示する照合表示を割り当てる。照合表示と接続要求の選択を Presenter に提示し、表示名は本人確認に使わない。コードを盗み見られた場合は身に覚えのない要求を拒否し、再発行できる。承認済み Remote も Presenter から失効できるようにする。
- [x] 承認を処理した session DO が、承認された接続だけに role/session に束縛した高エントロピーの専用 credential を発行する。招待値から credential を導出せず、サーバー側は照合用ハッシュだけを保存する。承認結果が失われたときは未承認の状態から招待を作り直せるようにし、消費済み招待を提示した別接続に credential を再交付しない。
- [x] HTTPS/WSS・Origin・role・session・失効・期限を認証境界で確認し、認証済み socket の各操作も再検証する。接続世代で古い socket からの操作・close による状態上書きを防ぐ。ペアリングの競合、承認と失効の競合、リロード時の credential 継承範囲をテストする。

### 4. 画面、同期、切断復帰

- [x] `AppRoutes.swift` に Remote 画面を追加し、`index.html` の既存テーマ・safe area・全画面レイアウトを使う。Presenter には招待と承認・拒否・失効、Remote にはコード入力、承認待ち、同期中、問題と答え、前後移動、切断・再接続を用意する。Presenter の DOM に答えを表示しない。配布物に含まれる QR ライブラリ等を追加したら、固定リストを持つ `Scripts/generate-licenses.py` に対象とライセンスを追加して `python3 Scripts/generate-licenses.py` を実行し、生成結果を確認する。
- [x] 承認後に Presenter から順序付き deck と snapshot を送る。Remote は同じ `deckVersion` と最新状態の受信確認後に操作可能にする。Presenter 不在時は最後の表示を読み取り専用にする。再接続では role credential を検証し、Presenter の最新の deck と snapshot を要求して、古いメッセージを無視する。
- [x] 同じ Presenter 文書の再接続は現行 epoch を使う。Presenter の文書リロードで進行を失った場合は新しい epoch として扱い、旧操作を再送しない。Remote の操作結果が判別できない場合は同期後に明示する。Safari の背景化から復帰したときは接続を再確認し、指数 backoff と上限、手動再接続を用意する。ルート切替・画面終了時にタイマー・イベント・socket を解放する。
- [x] DO は認証・失効・接続識別子等の最小メタデータだけを保存し、問題・答え・計時・記録を永続化しない。alarm で期限切れ session の socket を閉じて保存データを削除する。実行遅延・重複・再試行があっても各要求で失効を確認し、cleanup を再実行できるようにする。[Alarms](https://developers.cloudflare.com/durable-objects/api/alarms/)

### 5. CI、ステージング、本番切替

- [x] PR で単体・結合テスト、Embedded ビルド、生成物検査と dry run を実行する。Swift 6.4.2 コンテナ、SDK checksum、pnpm lockfile を使い、`swift-actions/setup-swift@v2` を使用しない。意味のある変更ごとにコミットし、バージョンタグは `v` を付けない。
- [x] `pnpm exec cf build --mode staging` の生成物 `.cloudflare/output/v0/config.json` で mode・Worker 名・assets・DO 設定を検査し、`pnpm exec cf deploy --prebuilt --mode staging --dry-run` を実行する。認証済みの対象でステージングに公開する際は同じ成果物・mode で `--dry-run` を外す。本番は対応する `production` 成果物を使う。[cf の mode と prebuilt](https://developers.cloudflare.com/cf/projects/)
- [ ] ステージングで Workers Logs と DO メトリクスを確認し、異常率、Wasm の起動時間、接続の往復時間、DO duration・request・storage を記録する。招待・コード・credential・問題や答えをログに残さない。想定同時利用と模擬上限超過時の挙動を測り、現行プランの上限と照合する。[DO の料金](https://developers.cloudflare.com/durable-objects/platform/pricing/)・[DO の上限](https://developers.cloudflare.com/durable-objects/platform/limits/)
- [ ] 本番公開と旧 GitHub Pages 停止はステージングの受け入れ後に行う。DO を初めて有効にするリリースでは、DO の class lifecycle を保ったままリモコンを止めて一人プレイを配信できる版を用意する。DO の構成変更をまたぐ rollback の制限、データが rollback で戻らない点、古いブラウザーと新 Worker の互換性をステージングで確認して切り戻し手順を記録する。[Cloudflare rollback](https://developers.cloudflare.com/workers/versions-and-deployments/rollbacks/)

## 受け入れ条件

| 検証層 | 合格条件 |
| --- | --- |
| Swift 単体 | 4 デッキの範囲・枚数・0 の扱い、順序、計時と完了、phase/role/epoch/version 判定、同一 ID の再送、ローカルと Remote の競合がテストで通る。完了した 1 プレイにつき記録とスタンプ更新は 1 回。 |
| ローカル workerd | HTTP・WSS と 2 session の隔離、2 つの Remote の同時 join、QR とコードの同時提示、期限・拒否・再発行・単回使用、コード衝突、照会上限、他 session や別 role の credential 拒否、不正な Origin・入力、alarm 再実行を自動テストする。承認前の接続に deck、答え、操作権限が届かない。 |
| ブラウザー自動化 | 同じブラウザーの独立タブまたは context で、手入力だけで Presenter の承認から前後移動・完了まで通る。カメラ拒否中もコード経路が使える。ACK 消失、順序逆転、切断、Presenter reload でカードを余分に進めない。 |
| レイアウト・既存動作 | 812×375、667×320、375×812、デスクトップでスクロールせず操作でき、safe area 内に必要な操作が収まる。左右タップ・矢印・Space・Esc、タイマー非表示、storage が利用できない場合、日付変更、履歴とスタンプを確認する。 |
| ステージング実機 | iPhone Safari と別端末を異なる回線から接続し、QR とコードを個別に通す。答えは Remote 画面に表示され、子どもの画面は問題表示。回転、背景化・復帰、通信断、再接続、期限切れ、手動失効、Presenter 不在中の読み取り専用状態を確認する。 |
| Cloudflare 実環境 | staging の WSS・SQLite 復元と hibernation、再デプロイ後の復帰、session と環境の隔離を確認する。staging 上で切り戻し手順を試し、日常利用の実測とプラン上限を比較する。dry run やローカル実行の結果は別に記録する。 |

各検証の結果にコミット、実行コマンド、対象環境、端末・ブラウザ、期待値と観測結果を残す。認証・実機・クラウドが必要で未実施の項目は、確認済みの項目と区別して記録する。

ステージングの公開先 URL と確認手順を共有する。Codex で操作できるブラウザーは自動検証に使い、実物のカメラ、別回線、iOS の画面ロック・背景化など、端末操作が必要な条件は実機担当者と確認する。認証のブラウザー承認、権限変更、GitHub Secrets の登録、旧サイトの切替判断は本人が行う。
