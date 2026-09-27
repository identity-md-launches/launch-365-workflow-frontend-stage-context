# Attribution

The design and consolidated review used the task's pinned **Better Interface** reference: Jakub Krehel, MIT, commit `267330e1adfc66a718fb65fa6918c1f06d0a689e`, [upstream source](https://github.com/jakubkrehel/skills/tree/267330e1adfc66a718fb65fa6918c1f06d0a689e/skills/better-interface). The supplied reference was read locally rather than replaced by an upstream version.

The design-documentation method is adapted in that pinned reference from **Impeccable**, Paul Bakaus, Apache-2.0, commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`, [document reference](https://github.com/pbakaus/impeccable/blob/9d715cc4f5564a990ca8345abfdd5df6dc9b41c8/skill/reference/document.md). These works keep their respective MIT and Apache-2.0 licenses; this attribution does not relicense either. The frontend does not redistribute the reference manual or its source code.

`web/src/tickMath.ts` adapts `getSqrtRatioAtTick` from `@uniswap/v3-sdk` version 3.31.5 to native JavaScript bigint. Copyright (c) 2021 Uniswap Labs, MIT. Its complete notice and license are retained at `web/public/licenses/Uniswap-TickMath.txt` and exported at `dist/licenses/Uniswap-TickMath.txt`. Integer factors and rounding are unchanged. A one-time comparison against the SDK checked 29,582 inputs, covering all 60-spaced ticks plus boundary cases; 302 reference vectors are retained as repeatable tests.

React, React DOM, viem and build/test tools retain their upstream licenses. Installed packages and caches are excluded from the submission; their exact versions and resolutions are in `web/package-lock.json`. The favicon is a small original SVG letterform, not a downloaded asset. The site uses available system fonts and contains no external photo or illustration assets.
