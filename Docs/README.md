# 深海潛艇：聲納盲航潛行 RTL

頂層是 `submarine_sonar_top`，語言為 Verilog-2001。此版本針對原始 VeriLite 第一代 Cyclone 遊戲，不是 DE1-SoC 移植版。

## 資料夾配置

- RTL/：四份可合成的 .v 設計來源。
- tb/：tb_sonar.v、tb_top.v、tb_lcd.v，僅供模擬。
- Docs/：README.md 與 PINOUT.md。
- Simulation/：run_sim.ps1 與 sim.do。
- Constraints/：clock_24MHz.sdc。

## 檔案與 Quartus 使用方式

只將以下四份加入 Quartus：

| 檔案 | 內容 |
|---|---|
| submarine_sonar_top.v | I/O、開機重置、旋鈕、羅盤、狀態燈、LCD 文字 |
| sonar_game_core.v | 遊戲 FSM、地圖生成、RAM 仲裁、移動、聲納、魚雷、洋流、動畫 |
| sonar_support.v | 單埠 RAM、消抖、tick、矩陣與七段掃描 |
| text_lcd_driver.v | Lecture 9 VeriInstrument LCDM 協定、獨立時序與畫面更新 |

`tb_sonar.v`、`tb_top.v`、`tb_lcd.v` 只供模擬，不加入 FPGA 合成。`sim.do`、`run_sim.ps1` 是測試腳本。沒有建立腳位 QSF，請依 PINOUT.md 自行配置。`Constraints/clock_24MHz.sdc` 為 24 MHz 的時脈約束範例，頻率確認後再加入並調整。

在學校選板上實際晶片與完整速度等級（EP1C6Q240 或 EP1C12Q240），設頂層為 `submarine_sonar_top`。舊工具若也遇到中文路徑問題，請把四份來源複製到英文路徑建立 Quartus 工程，例如 `C:\FPGA\sonar_game`。不要選 DE1-SoC 的晶片產生 VeriLite 燒錄檔。

## 已實作

- 64×64 隨機水雷地圖、起點 (52,52)、起終點 5×5 安全區。
- IDLE / GEN / PLAY / WIN / LOSE；開局 4096 個主時脈依序寫 RAM。
- 普通約 1/16、困難約 1/8 密度；安全區會降低實際雷數。
- 8 血、9 次聲納、一次魚雷。水雷碰撞扣血後清除；邊界阻擋移動。
- 8×8 相機、局部中心 (3,3) 5 Hz 閃爍、邊界牆與可見終點。
- 聲納 R=1..12，每 0.1 秒前進一級；掃過的水雷閃爍，掃描完成後再保留 1.2 秒。掃描尚未結束時重按不扣次數。
- 羅盤與曼哈頓距離 000..126；距離 ≤2 的水雷觸發警報。
- 魚雷以最後移動方向清除前方一格；預設朝北。按鍵或魚雷切換只在上升緣觸發。
- 洋流每 3 秒切換隨機一格雷的狀態，保護起終點安全區和當前潛艇格。
- 連走開啟時按住方向約每 0.1 秒走一格；同按方向優先順序北、南、西、東。
- Demo 顯示目前視窗全部水雷；所有撞擊／勝敗影格使用原規格常數。
- 撞擊動畫 0.5 秒，期間停止移動；勝敗六格動畫每格 0.2 秒。
- 勝敗後按 Start 直接產生新一局；結算期間也可旋轉選擇下一局區域。

## 規格未定部分採用的明確預設

- N 區：X=36..51、Y=4..19；W 區：X=4..19、Y=36..51；RD 區：X,Y=4..51。NW 維持 X,Y=4..19。RD 範圍保留安全邊距並避免終點貼近起點；不是均勻覆蓋完整 64×64。
- 旋鈕每四次合法相位轉換切換一區。input11=A、input12=B，input13 保留中心按壓腳，目前沒有定義動作。
- 難度在 Start 鎖定；洋流、連走、Demo 可即時切換。魚雷開關若開局前已 ON，須先 OFF 再 ON。
- 每次洋流僅切換一個格子。移動／魚雷優先於洋流與顯示讀取。
- 聲納相對目前潛艇位置繪製，移動會帶動波紋中心。曝光使用共用倒數，不是每個世界格獨立計時。
- 沒有額外外部 Reset 腳位。FPGA 上電初始化暫存器產生 POR，Start 負責遊戲重開。

## 實機參數

頂層參數：`CLK_FREQ=24000000`、`MAT_ROW_INV=0`、`MAT_COL_INV=0`、`SEG_INV=0`、`SEL_INV=0`、`ROT_SWAP=0`、`ROT_INV=0`、`POR_CYCLES=1024`。

請先確認 VeriComm/.dkp 主時脈，再修改 CLK_FREQ 與 SDC。矩陣、七段段碼及選位反相可獨立調整；旋鈕逆向可設 ROT_SWAP=1，A/B 低態拉起需求可依實測調整 ROT_INV。LCD 固定 RW=0 寫入，不讀 Busy Flag；各等待時間均獨立設定，預設保留毫秒級傳輸。LCD 依講義使用 output52 作 RST，文字改變時清屏回左上並依序寫滿兩行。T:1／T:0 表示魚雷剩餘次數。詳細參數見 LCD_TIMING.md。

RAM 沒有非同步清除或逐格平行重置。只有一組地址與寫入使能，讀取、等待、套用分成不同週期，確保同步 RAM 延遲。地圖初值由 GEN 全面覆寫。顯示使用 64-bit 畫面快取，不是 4096-bit 暫存器地圖。

## 模擬

在專案根目錄開 PowerShell 執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Simulation\run_sim.ps1
```

腳本會從相鄰 RTL 與 tb 資料夾讀取來源，再連同 sim.do 複製到 `%TEMP%\sonar_sim_<隨機名稱>`，不移動或刪除原檔。若 ModelSim 在其他位置，使用 `-ModelSim '完整的vsim.exe路徑'`。輸出保留在腳本列出的暫存目錄，可自行清理。

預設 Fast 模式預期三組 PASS：遊戲核心、1 MHz 頂層整合、1 MHz LCD 真實時間與畫面更新測試。`-Mode Timing` 執行 24 MHz 與 50 MHz 的獨立 LCD 時序測試；`-Mode All` 執行全部五組。所有有除頻計時的 testbench，實際時脈與 CLK_FREQ 都一致；不再藉由兩者不一致來縮短時間。若要看波形，在英文暫存路徑開 ModelSim，編譯後執行 `vsim work.tb_sonar`、`add wave -r sim:/tb_sonar/*`、`run -all`。

## 驗證與限制

2026-11-16 已用本機 ModelSim Intel FPGA Starter 2020.1 執行核心及頂層/LCD 測試。涵蓋地圖初始化、安全區、難度、四種目標區域、單步、邊界、距離126、警報、扣血清雷、魚雷耗盡、聲納倒數、勝敗與重開；當時頂層測試採用時間壓縮，只確認消抖邏輯、LCD 字元及初始化順序，不能作為真實 LCD 時序通過的證據。2026-11-18 已改用符合 CLK_FREQ 的時脈並新增獨立匯流排時間檢查器；見 LCD_TIMING.md。

測試部分使用階層方式放置特定水雷／座標，讓撞擊與勝敗可重現。不是窮舉所有隨機種子，也不是實體板子驗證。

Quartus Lite 25.1 對 Cyclone V 的 Analysis & Synthesis 通過；同步地圖辨識為 RAM。因新晶片沒有 M4K，工具會警告後改用可用的記憶體資源。這個結果不能拿來宣稱 EP1C6 已通過編譯、符合 LE 容量或時序。學校舊版 Quartus 仍須檢查單個 M4K、資源用量、Fitter 與 Timing Analyzer，最後用 VeriInstrument 實測極性、掃描方向與 LCD。

### 提交開發者確認的原規格問題

1. LFSR 擷取的終點可能重複，無法保證「每次皆不相同」。此版不增加歷史排除邏輯。
2. 兩個 5×5 安全區不保證整張地圖有連通路徑；此版不強制挖通道或做尋路。
3. RD/N/W 範圍、洋流一次變動數量、連走速度、聲納移動中心與曝光起算方式未完全定義，以上列出實作預設供確認。
4. 旋鈕極性、矩陣 Row/Col、七段選位極性與時脈頻率仍須實測。
5. 普通地圖測試只涵蓋測試當下的 LFSR 種子；不代表所有隨機地圖一定可通關。
