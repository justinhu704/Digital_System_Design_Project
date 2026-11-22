# Lecture 9 LCDM 接線與時序

依課堂 Lecture 9 第 8～10 頁的 VeriInstrument Text LCD Display。這是 2×16、High Active、12 個端子的虛擬元件。

| 端子 | VeriInstrument 通道 |
|---|---|
| DB0～DB7 | output16～23，按低位到高位依序 |
| RS | output24，0 命令，1 字元 |
| RW | output25，固定 0 |
| EN | output26，下降緣寫入 |
| RST | output52（PIN_75），高態清屏並回左上 |

將原本接 output52 的魚雷燈移除，通道改給 LCD 的 RST。遊玩中 LCD 第一行的 T:1／T:0 表示魚雷剩餘次數。此配置需要能在 LCD 屬性指定 RST 的通道，若學校版本要求十二條連號，需以其屬性視窗為準重新配置。

## 傳輸流程

文字仍在 RTL 以 ASCII 填寫。輸出時依課堂字元表換算成 ASCII 減 0x20，例如空格→0x00、0→0x10、A→0x21。每次重畫先拉高 RST，放開後以 RS=0 傳 0xFC 隱藏游標，再以 RS=1 送第一行 16 字元和第二行 16 字元。游標在寫完第一行後自動換行。

兩行有變動才觸發整屏重畫，未變時維持畫面。整屏重畫會先清屏再逐字寫入，以預設參數約 101 ms。若傳輸途中又有變動，本批送完後會抓取最新畫面。

## 頻率與模擬

CLK_FREQ 要等於實際送進 PIN_28 的主時脈。依序使用 40 ms 開機等待、2 ms RST 高態，以及各 1 ms 的資料準備、EN 高態和傳輸後等待。空閒每 20 ms 檢查畫面。這些是本專題的預設值。第 14～15 頁工具列顯示 100 Hz，簡報未標明它與 FPGA 輸入時脈的關係，也沒有指定本專題必須用該頻率。

由專案根目錄執行 Simulation\run_sim.ps1，Fast 檢查遊戲與 1 MHz LCD，Timing 檢查 24、50 MHz LCD。模擬檢查 RST、EN 邊緣、資料、整屏更新與穩定時不重寫。VeriInstrument 面板的實際通道選擇及畫面更新仍需上板驗證。
