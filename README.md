# スピードけいさん (SpeedMath)

小学生向けのスピード計算（計算カード）アプリです。算数セットの計算カードと同じ 4 種類のデッキをシャッフルして 1 枚ずつ表示し、最後までの時間を計ります。

**▶ https://ainame.github.io/SpeedMath/**

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

Cloudflare CLI は beta です。`pnpm exec cf auth login` でログイン後、`pnpm exec cf deploy` で Worker をビルド・公開できます。`cf deploy --dry-run` はアップロードせずに検証します。`wrangler.jsonc` は移行確認のため残していますが、`cf` は `cloudflare.config.ts` を使用します。

`main` に push すると GitHub Actions が Cloudflare Workers Static Assets にデプロイします。GitHub Actions の secrets に `CLOUDFLARE_API_TOKEN`（Workers のデプロイ権限）と `CLOUDFLARE_ACCOUNT_ID` を設定してください。Cloudflare への移行完了までは、上記の GitHub Pages 版を利用できます。

[elementary-swift/starter-vite](https://github.com/elementary-swift/starter-vite) テンプレートから作成しました。

## ライセンス

[MIT](LICENSE)
