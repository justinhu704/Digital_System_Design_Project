# 交接說明（給接手修改程式的 Claude session）

最後更新：2026-11-26。這份文件整理目前的設計狀態、做過的修改和待辦事項。修改程式前請先讀完本文件、[README](../README.md)、[PINOUT](PINOUT.md)、[BOARD_TEST](BOARD_TEST.md)。

## 專案概要

- **內容**：FPGA 潛艇掃雷遊戲《深海潛艇：聲納盲航潛行》，數位系統設計實習期末專題。
- **語言與工具**：Verilog-2001。目標板 SMIMS VeriLite（第一代 Cyclone），用 Quartus II 編譯，透過 VeriComm／VeriInstrument 的虛擬 I/O 操作。
- **時脈**：主時脈 **500 Hz**（`CLK_FREQ = 500`，1 clock = 2 ms）。
- **頂層**：`submarine_sonar_top`，端口 `clk`、`inputs[13:0]`、`outputs[53:0]`、`led_board[7:0]`。編號與 VeriInstrument 的 inputN／outputN 一致。

## 必須遵守

- **`.v` 檔只能用英文、純 ASCII**（註解也一樣）。學校的 Quartus II 會把 UTF-8 中文變成 `???`。Markdown 文件可以用中文。
- **改 RTL 後要跑完三個 testbench 並全部通過**（見下方「模擬」）。
- **使用者自己 commit**，不要替他 commit 或 push，除非他明確要求。

## 檔案

| 檔案 | 內容 |
|---|---|
| `RTL/submarine_sonar_top.v` | 頂層：輸入極性、消抖、LCD 文字、LED、羅盤 |
| `RTL/sonar_game_core.v` | 遊戲核心：狀態機、地圖 RAM、亂數、移動、聲納、魚雷、洋流、矩陣畫面 |
| `RTL/sonar_support.v` | tick 產生器、按鍵消抖、8×8 矩陣掃描、雙位七段 |
| `RTL/text_lcd_driver.v` | VeriInstrument 2×16 LCD 驅動 |
| `tb/tb_sonar.v` | 核心單元測試 |
| `tb/tb_lcd.v` | LCD 腳位協定測試 |
| `tb/tb_game.v` | 以 500 Hz 只透過腳位玩完整局（BFS 自動駕駛），從輸出腳位解碼每個元件來比對 |
| `Simulation/run_sim.ps1`、`sim.do` | 跑三個 testbench（ModelSim） |
| `Simulation/Reports/` | 模擬報告 `SIM_2026-11-26.md`、遊戲過程紀錄 `game_log.txt` |
| `Constraints/clock_500Hz.sdc` | 時脈約束（2,000,000 ns） |

## 遊戲目前的規則

- **流程**：IDLE → PICK（隨機起點＋終點）→ GEN（64 clock 生成地圖）→ PLAY → WIN／LOSE。GO 在任何狀態（PICK、GEN 除外）都會重新開局。
- **地圖**：64×64，存在一塊 64×64-bit RAM（一個 word = 一列）。
  - 亂數用 64-bit xorshift，每個 clock 前進一步。
  - 水雷由 rng 位移 {0,7,19,42} 的位元做 AND 產生：普通取 4 bit（約 1/16），困難取 3 bit（約 1/8）。
  - 起點 5×5、終點 5×5 不放雷（終點範圍是參數 `GOAL_SAFE`，半徑 2；原本是 7×7，為了讓勝利畫面看得到水雷而縮小）。
- **難度開關**（開局時鎖定）：

| 難度 | 起點到終點（到十字最近一格的距離） | 水雷密度 | 魚雷 |
|---|---|---|---|
| 普通 | 24～48 | 1/16 | 6 發 |
| 困難 | ≥ 64 | 1/8 | 3 發 |

  起點和終點一起隨機產生，座標都在 3～60，方向不固定。
- **資源**：HP 8、聲納 9 次。
- **移動**：一次按壓走一格，按住不會連走。
- **撞雷**：HP −1，那顆雷清除，播 0.4 秒撞擊動畫，期間的按鍵會被忽略。
- **DIST**：到終點十字**最近一格**的步數（= 到中心的曼哈頓距離 − 1）。DIST 001 再走一步就勝利。難度的距離範圍也用同一個定義。
- **勝利**：碰到終點「+」五格中的任一格。
- **勝利畫面**：先顯示視窗內所有水雷 `WIN_HOLD` = 5 步（約 1 秒），接著一圈像聲納的環從視窗角落往潛艇收縮，每 0.2 秒一格，環外的水雷消失，最後只剩終點十字、潛艇和牆。
- **聲納**：
  - 波紋擴散約 1.2 秒，接著全視野曝光 2 秒（`SONAR_REVEAL` = 10 步 × 0.2 秒）。
  - 曝光期間以潛艇**目前位置**即時重畫，所以邊走邊看得到新區域的水雷。
- **魚雷**：
  - 按鈕 input9，Low active。沿船頭方向（最後一次移動的方向，開局預設朝北）飛行，畫成一個亮點。
  - 每格停留 `TORP_STEP_CLKS` = 30 clock，實測每格約 72 ms；最多 `TORP_RANGE` = 4 格。
  - 撞到第一顆雷時清除該雷，播放 `BOOM_CLKS` = 100 clock 的爆炸（先「+」字，再四個斜角）；碰到地圖邊緣停下。
  - 沒打中也會消耗；面向牆壁發射不消耗。一次只飛一發，飛行中可以移動。
- **洋流**：開關打開時，每 5 秒隨機選一個方向，把整張地圖的水雷往該方向移動一格（潛艇和終點不動）。
  - 從地圖邊緣移入的那一列／欄重新隨機放雷（同難度密度），終點安全區永遠保持無雷。
  - 水雷被推到潛艇所在格算撞雷：HP −1、那顆雷消失、播撞擊動畫。
  - 位移用 128 clock（約 0.26 秒，每列 2 clock），期間矩陣暫停更新、按鍵排隊等位移結束再執行。
  - LCD 第二行顯示 `CUR:N/S/W/E`（最近一次的方向，第一次位移前為 `CUR:-`）。
- **Demo 開關**：顯示視窗內所有水雷。
- **畫面**：8×8 視窗，潛艇固定在 view (3,3)；`pixels[y*8+x]` 對應 Row=y、Col=x；地圖外畫成牆。
- **警告**：曼哈頓距離 2 格內有雷時黃燈閃、LCD 第二行顯示 `WARN: MINE NEAR!`。
- **LCD**：
  - 遊玩中顯示 `HP:h SON:s T:t` / `DIST:ddd`；洋流開啟時第二行是 `DIST:ddd CUR:x`。
  - 待機時顯示 `LV:NORM|HARD CUR:ON|OFF` / `PRESS GO TO DIVE`。
  - 每字 2 clock，文字有變動才整屏重畫（約 124 ms）。

## 輸入與頂層參數

| 輸入 | 用途 |
|---|---|
| inputs[0..3] | 上下左右按鈕，High active |
| inputs[4] | 聲納按鈕，Low active |
| inputs[5] | 開始按鈕，Low active |
| inputs[6] | 難度開關 |
| inputs[7] | 洋流開關 |
| inputs[9] | 魚雷按鈕 |
| inputs[10] | Demo 開關 |
| inputs[8]、[11..13] | 未使用（原本的連走開關與旋鈕已移除） |

| 參數 | 預設 | 意義 |
|---|---|---|
| `SW_INV` | 1 | 開關撥 ON 時腳位讀到 0（bit 6、7、10） |
| `TORP_LOW_ACTIVE` | 1 | 魚雷按鈕為 Low active |
| `SEL_INV` | 1 | 七段選位為 Low active |
| `SEG_INV`、`MAT_ROW_INV`、`MAT_COL_INV` | 0 | 段碼、矩陣列、矩陣欄的反相 |

## 這次修正過的錯誤（避免改回去）

1. **矩陣掃描卡列**：`matrix_8x8_driver` 找下一列時，`(row + i) * 8` 被擴成 32-bit 而不會從第 7 列繞回第 0 列，會卡在同一列。現在用 3-bit 的 `cand` 繞回。
2. **水雷規則排列**：舊雜湊只看低 4 bit，每 16 欄重複一次，造成規則的格子狀分布。現在改用 xorshift 取位元做 AND。
3. **魚雷撥回 OFF 也會發射**：魚雷改成按鈕，用 `press[9]` 觸發。
4. **起點固定在 (52,52)**：讓終點幾乎總在左上。現在起點和終點一起隨機產生。
5. **小問題**：位寬截斷警告；`dist` 跟 SystemVerilog 保留字撞名，已改名為 `goal_dist`。
6. **testbench 迴圈變數**：`tb_game` 的 `k` 也被腳位解碼的 always 區塊使用，不能拿來當 initial 區塊裡長時間的迴圈變數。

## 模擬

```powershell
.\Simulation\run_sim.ps1
```

- **需要 ModelSim**：預設路徑 `C:\intelFPGA\20.1\modelsim_ase\win32aloem\vsim.exe`，可用 `-ModelSim` 參數指定。
- **非 ASCII 路徑**：腳本會把檔案複製到暫存的英文路徑再模擬，所以專案資料夾名稱有中文也沒關係。
- **目前結果**：三個 testbench 全部 PASS。
- **沒有 ModelSim 的環境**（例如雲端）：testbench 是一般 Verilog，可試用 Icarus Verilog（`iverilog -g2005`），但尚未驗證能編譯，若有語法差異需要調整。
- **Quartus 合成尚未驗證**：開發電腦上的 Quartus Prime Lite 25.1 缺 `ip-catalog.exe`，連原版程式都無法合成。請以學校的 Quartus II 為準。

## 待辦與未決事項

- **上板測試**：依 [BOARD_TEST.md](BOARD_TEST.md) 逐項確認，特別是：
  - 開關極性（`SW_INV`）
  - 魚雷按鈕極性（`TORP_LOW_ACTIVE`）
  - 矩陣方向：開 Demo，按右時水雷應往左移一格
  - 8 列全亮時的閃爍
  - 魚雷飛行速度的手感
- **使用者曾回報**「距離還有兩格，走一步卻爆炸」。主因應是舊 DIST 算到十字中心（DIST 002 走一步就勝利），已改成到最近一格；舊版連走功能也已移除。上板時仍要確認矩陣方向。
- **2026-11-26 使用者決定**：DIST 改到最近一格、勝利畫面改成顯示水雷再收縮、聲納曝光 3 → 2 秒、洋流改成整圖位移。聲納快照模式**不做**。
- **2026-11-26 後續**：終點安全區由 7×7 縮成 5×5（`GOAL_SAFE` = 2）。連走開關確定丟棄，input8 保持空著。
- **按鍵手感**：按鍵需要按住約 120 ms 以上才一定會被讀到（每 40 ms 取樣、連續 3 次相同才算數）。
