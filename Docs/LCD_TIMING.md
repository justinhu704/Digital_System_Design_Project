# Lecture 9 LCDM 接線與時序

依課堂 Lecture 9 第 8～10 頁的 VeriInstrument Text LCD Display。這是 2×16、High Active、12 個端子的虛擬元件。驅動程式是 `RTL/text_lcd_driver.v`。

| 端子 | VeriInstrument 通道 |
|---|---|
| DB0～DB7 | output16～23，按低位到高位依序 |
| RS | output24，本設計固定送 1（只寫字元） |
| RW | output25，固定 0 |
| EN | output26，下降緣寫入 |
| RST | output52（PIN_75），高態清屏並回左上 |

原本接 output52 的魚雷燈已移除，通道改給 LCD 的 RST。遊玩中 LCD 第一行的 `T:n` 表示魚雷剩餘發數。此配置需要能在 LCD 屬性指定 RST 的通道；若學校版本要求 12 條連號，需以屬性視窗為準重新配置。

## 傳輸流程

文字在 RTL 以 ASCII 填寫，每行 16 字元（`line1`、`line2` 各 128 bit，最左字元在最高位）。輸出時依課堂字元表換算成 ASCII 減 0x20，例如空格→0x00、0→0x10、A→0x21。

每次重畫的順序：

1. RST 拉高 1 個 clock：清屏並回到左上。
2. 每個字元用 2 個 clock 寫入：
   - 第 1 個 clock：放上資料、RS=1，EN 拉高。
   - 第 2 個 clock：EN 拉低，在下降緣寫入。
3. 連續寫 32 字元。寫完第一行 16 字後，LCD 自動換到第二行。

不送任何命令（RS=0），也不送 0xFC 隱藏游標的命令。

兩行文字有變動才重畫，沒變動時不寫入。若傳輸途中又有變動，本批送完後會立刻抓最新畫面再重畫一次。

## 頻率

整個設計以 VeriComm 送入的 **500 Hz** 主時脈運作（`CLK_FREQ = 500`），1 個 clock = 2 ms：

| 項目 | 時間 |
|---|---|
| RST 高態 | 2 ms |
| EN 高態（資料穩定） | 2 ms |
| 一個字元 | 4 ms |
| 整屏重畫（RST + 32 字元） | 約 130 ms |

這個驅動是為慢速時脈設計的。若改用 MHz 級時脈接實體 LCD，EN 脈寬會遠低於 HD44780 的需求，必須另外加延遲計數。

## 模擬

`tb/tb_lcd.v` 只觀察 LCD 腳位，用一個 LCD 模型（RST 清屏、EN 下降緣寫入）重建畫面，檢查：

- EN 高電位期間資料與 RS 不變
- 寫入時 RW、RST 為 0
- 32 字元內容正確
- 畫面不變時不寫入
- 傳輸中變動時，最後顯示的是最新畫面

`tb/tb_game.v` 也用同一個模型，在整局遊戲中比對每個畫面的 LCD 文字。VeriInstrument 面板的實際通道選擇與畫面更新仍需上板確認。
