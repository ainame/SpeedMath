# リモコン検証記録

> **記録（2026-11-14 時点）** — 当時の検証結果です。現在のテストと手順は [docs/architecture.md](../architecture.md) の「Build, test and deploy」を参照してください。ここに挙げた未確認事項のうち、iPhone 実機での確認と DO の退避・復元の実測は、まだ行っていません。

2026-11-14、対象アプリは `d5a7ebb`（トップのボタンをタイトル左側に配置）。公開先は [speedmath-staging](https://speedmath-staging.ainame-apps.workers.dev/)。

| 検証 | コマンドと結果 |
| --- | --- |
| Swift 単体 | macOS / Swift 6.4.0 の `swift test`。reducer 2 件と、4 デッキをそれぞれ調べるデッキテストが合格。 |
| Embedded Swift と生成物 | `pnpm run build --mode staging`、`pnpm exec node Scripts/check-build.mjs staging`、`pnpm exec cf deploy --prebuilt --mode staging --dry-run`。Worker Wasm 290 B（import なし）、WebApp Wasm 1,223,707 B。公開先では WebApp を `application/wasm` で取得できた。 |
| ローカル workerd | `pnpm exec playwright test`。Chromium 149、7 件合格。2 セッション分離、別セッション・別 role の鍵の拒否、承認前の非開示、QR と手入力の競合、拒否・再発行・単回使用・失効を確認。 |
| ステージング | `SPEEDMATH_TEST_URL=https://speedmath-staging.ainame-apps.workers.dev pnpm exec playwright test`。同じ 7 件合格。手入力と QR、ACK 1 件消失、通信断後の再同期、Presenter リロード、解除、4 サイズでの操作を実際の WSS で確認。追加のストレージ拒否・日付変更テストもステージングで合格。 |
| アイドル・再デプロイ | `SPEEDMATH_TEST_URL=… pnpm exec node Tests/browser/live-smoke.mjs` に相当する接続テストで、45 秒アイドル後の操作が両画面に反映されるまで 101 ms。 `--redeploy` 相当の試験で、接続中に同じ成果物を再デプロイした後も操作が 1 回だけ反映された。Cloudflare が実際に DO を退避したことや、ソケットの再確立が発生したことは、この観測だけでは断定できない。 |
| DO 単体（`15ff87b`） | `pnpm run test:worker`（Node 24 の node:test と node:sqlite で `CodeShard` / `SessionObject` を直接実行）、9 件合格。コード衝突時の再生成と 5 回衝突で招待なし、敗者の release が勝者の行を消さないこと、招待期限・未認証 socket・Remote 再接続猶予・session 期限の alarm を 2 回続けて実行しても結果が 1 回分であることを確認。`deleteAll` が SQLite のテーブルも消すため、同じインスタンスへの重複 alarm・遅れた lookup・再接続が `no such table` で失敗する不具合を見つけて修正（修正前は 2 件失敗）。修正版をステージング（version `9008f7dc-56be-40de-a382-ae91c96dfa2b`）に公開し、Playwright 8 件が合格。 |
| Cloudflare | ステージングの `CodeShard` と `SessionObject` の `use_sqlite: true` を確認。CLI の報告した Worker 起動時間は 2 ms。Workers Logs の集計で検証中の `ok` と `canceled` を確認。リクエストの個別内容は採取していない。 |
| 切り戻し | `staging-solo` を dry run の後に公開。ペアリング API が 404 を返し、一人プレイが最後まで動作した。 `cf workers deployments create` でリモコン付きバージョン `80749b3d-3877-4d01-9194-4d5330e6796e` を 100% に戻し、QR 接続から失効まで再確認。 |

未確認：DO の退避と復元を示す実測、再デプロイ時のソケット再認証の発生、実 workerd 上での alarm 発火の試験（上記の DO 単体は偽のホストで実行）、分散負荷・DO メモリー等の測定、iPhone 実機。デプロイはローカル認証で行った。作業ブランチの GitHub Actions は検証のみで、CI 専用ステージングトークンでは未公開。

実機で確認する際は、iPhone の Safari をモバイル回線、もう一台を Wi-Fi につなぐ。両方でステージングを開き、QR と手入力を別々に承認する。問題は Presenter、答えは Remote に出ることを確認し、iPhone を回転・ロックしてから復帰させ、再接続後も 1 操作で 1 枚だけ進むことを確認する。最後に Presenter 側で「リモコンを はずす」を押す。
