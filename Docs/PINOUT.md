# VeriLite / VeriInstrument 腳位對照

頂層：`submarine_sonar_top`。端口是 `clk`、`inputs[13:0]`、`outputs[53:0]`、`led_board[7:0]`。

**這是原規格中的 VeriLite Q240 腳位，不能套用到 DE1-SoC。** 以下只是對照，未產生腳位約束檔。Quartus Node Name 應使用程式中的 `inputs[n]` / `outputs[n]`，VeriInstrument 對應同號 `inputn` / `outputn`。範圍的腳位皆依編號遞增順序逐一對應。

## 主時脈與實體板載 LED

| Quartus Node Name | Location | 接到什麼 |
|---|---|---|
| clk | PIN_28 | VeriComm 送入的主時脈，預設 500 Hz（須與 `CLK_FREQ` 一致） |
| led_board[0] | PIN_122 | D0，HP 第1格 |
| led_board[1] | PIN_123 | D1，HP 第2格 |
| led_board[2] | PIN_124 | D2，HP 第3格 |
| led_board[3] | PIN_125 | D3，HP 第4格 |
| led_board[4] | PIN_126 | D4，HP 第5格 |
| led_board[5] | PIN_127 | D5，HP 第6格 |
| led_board[6] | PIN_128 | D6，HP 第7格 |
| led_board[7] | PIN_131 | D7，HP 第8格 |

板載 D0–D7 已在程式中做低態點亮處理，8血時八顆全亮。

## 虛擬輸入

| Node | VeriInstrument 元件／端子 | Location | 動作 |
|---|---|---|---|
| inputs[0] | Push Button 上 | PIN_226 | High active，Y−1 |
| inputs[1] | Push Button 下 | PIN_225 | High active，Y+1 |
| inputs[2] | Push Button 左 | PIN_224 | High active，X−1 |
| inputs[3] | Push Button 右 | PIN_223 | High active，X+1 |
| inputs[4] | Push Button LA 聲納 | PIN_222 | Low active，按下發射 |
| inputs[5] | Push Button LA 開始 | PIN_219 | Low active，開始／結算重開 |
| inputs[6] | 藍 Switch 難度 | PIN_218 | OFF普通、ON困難；開始時鎖定（決定終點距離與水雷密度） |
| inputs[7] | 藍 Switch 洋流 | PIN_217 | ON啟用 |
| inputs[8] | （未使用） | PIN_216 | 空出，可不接 |
| inputs[9] | Push Button LA 魚雷 | PIN_77 | Low active，按一下發射一次（按住不連發） |
| inputs[10] | Switch Red Demo | PIN_78 | ON顯示視窗全部水雷 |
| inputs[11] | （未使用） | PIN_79 | 空出，可不接（原旋鈕 A） |
| inputs[12] | （未使用） | PIN_82 | 空出，可不接（原旋鈕 B） |
| inputs[13] | （未使用） | PIN_83 | 空出，可不接（原旋鈕按壓） |

input4、input5、input9 在未按下時應為 1，其餘按鈕未按下時為 0。不要把 LA 再額外反相。

魚雷已從開關改成按鈕，預設 `TORP_LOW_ACTIVE = 1`，跟聲納、開始一樣是 Low active 的 LA 按鈕（未按下為 1）。若改用 High active 的按鈕元件，把這個參數改成 0。

開關（input6、7、10）預設 `SW_INV = 1`，也就是程式假設開關撥 ON 時腳位讀到 0。上板後在待機畫面撥難度、洋流開關，LCD 第一行應依序顯示 `LV:HARD`、`CUR:ON`；若顯示相反，把頂層參數 `SW_INV` 改成 0。

終點位置已改為每局隨機，不再使用旋鈕選區，所以 input8、input11～13 都空出來了。

## 矩陣與 LCD

| Node（依序） | Location（依序） | 接到什麼（依序） |
|---|---|---|
| outputs[0] .. outputs[7] | PIN_60, PIN_59, PIN_58, PIN_57, PIN_56, PIN_55, PIN_54, PIN_53 | Matrix LED Row0 .. Row7 |
| outputs[8] .. outputs[15] | PIN_50, PIN_49, PIN_48, PIN_47, PIN_46, PIN_45, PIN_44, PIN_43 | Matrix LED Col0 .. Col7 |
| outputs[16] .. outputs[23] | PIN_42, PIN_41, PIN_23, PIN_21, PIN_20, PIN_19, PIN_18, PIN_17 | Text LCD DB0 .. DB7 |
| outputs[24] | PIN_16 | Text LCD RS |
| outputs[25] | PIN_15 | Text LCD RW，程式固定0 |
| outputs[26] | PIN_14 | Text LCD EN，下降緣寫入 |
| outputs[52] | PIN_75 | Text LCD 第12端子 RST，高態清屏並回左上 |

預設 Row/Col 都是 high active。`pixels[y*8+x]` 對應 Row=y、Col=x。若矩陣全暗／反亮，先依模擬元件規格調整 MAT_ROW_INV、MAT_COL_INV；上下左右是否反轉也需現場確認。

LCD 請使用講義的 Text LCD Display (2×16, High Active)。RST 接 output52，原本的魚雷 LED 改由 LCD 第一行 `T:n`（剩餘發數）顯示。

## 雙位七段座標

| Node（依序） | Location（依序） | 接到什麼（依序） |
|---|---|---|
| outputs[27] .. outputs[33] | PIN_13, PIN_12, PIN_11, PIN_8, PIN_7, PIN_6, PIN_5 | X 七段 a,b,c,d,e,f,g |
| outputs[34] | PIN_4 | X SEL0，十位 |
| outputs[35] | PIN_61 | X SEL1，個位 |
| outputs[36] .. outputs[42] | PIN_62, PIN_63, PIN_64, PIN_65, PIN_66, PIN_67, PIN_68 | Y 七段 a,b,c,d,e,f,g |
| outputs[43] | PIN_73 | Y SEL0，十位 |
| outputs[44] | PIN_2 | Y SEL1，個位 |

使用兩個 Seven Segment Select Mode 元件，不接 dp。段碼 a..g 為 high active（`SEG_INV = 0`）；選位預設 `SEL_INV = 1`，也就是 **low active**（亮哪一位，該 SEL 腳就輸出 0）。SEG_INV 只反相 a..g，SEL_INV 只反相選位。

## 羅盤與狀態指示燈

| Node | Location | 元件與意義 |
|---|---|---|
| outputs[45] | PIN_238 | SMD LED 北；goal_y < sub_y |
| outputs[46] | PIN_237 | SMD LED 南；goal_y > sub_y |
| outputs[47] | PIN_236 | SMD LED 西；goal_x < sub_x |
| outputs[48] | PIN_235 | SMD LED 東；goal_x > sub_x |
| outputs[49] | PIN_234 | Green LED：安全航行或勝利 |
| outputs[50] | PIN_233 | Yellow LED：附近≤2格有水雷時閃爍 |
| outputs[51] | PIN_74 | Red LED：撞擊閃爍或失敗恆亮 |
| outputs[53] | PIN_76 | LED：聲納掃描／曝光進行中 |

這些虛擬 LED 預設 high active。總共使用 54 個虛擬輸出與 10 個虛擬輸入（input0～7、9、10；input8、11～13 空出），另有 8 個板載 LED 與主時脈。
