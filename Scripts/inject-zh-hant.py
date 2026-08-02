#!/usr/bin/env python3
"""Inject Traditional Chinese translations into Localizable.xcstrings.

Run from the repo root:  python3 Scripts/inject-zh-hant.py

Idempotent. Keys are the English source strings, exactly as extracted by
`xcstringstool sync`, so this script must be re-run after adding new UI strings
(the build will otherwise ship them untranslated, which is the intended
fallback rather than a failure).

Placeholders must match the source unit's specifiers, including positional
form (%1$lld) wherever the English value uses it — the catalog compiler
validates this and a mismatch fails the build.
"""

import json
import pathlib
import subprocess
import sys

CATALOG = pathlib.Path("Contact SyncMate/Localizable.xcstrings")

T = {
    # ── Numeric / format fragments ──────────────────────────────────────
    "%@ %lld": "%1$@ %2$lld",
    "%@ • %@": "%1$@ • %2$@",
    "%@: %@": "%1$@：%2$@",
    "%lld / %lld": "%1$lld / %2$lld",
    "%lld Google": "Google %lld 筆",
    "%lld Mac": "Mac %lld 筆",
    "%lld account%@ available": "有 %1$lld 個帳號可用%2$@",
    "%lld backups": "%lld 份備份",
    "%lld change%@ pending": "%1$lld 項待處理變更%2$@",
    "%lld conflict%@": "%1$lld 個衝突%2$@",
    "%lld conflict%@ need review — tap Details on each highlighted row.":
        "有 %1$lld 個衝突需要檢視%2$@ — 請點選標示列的「詳細資料」。",
    "%lld contact%@": "%1$lld 位聯絡人%2$@",
    "%lld contacts": "%lld 位聯絡人",
    "%lld group%@ found": "找到 %1$lld 個群組%2$@",
    "%lld of %lld": "%1$lld / %2$lld",
    "%lld of %lld conflict%@": "%1$lld / %2$lld 個衝突%3$@",
    "%lld of %lld decided": "已決定 %1$lld / %2$lld",
    "%lld percent": "百分之 %lld",
    "%lld selected": "已選取 %lld 項",
    "%lld skipped": "已略過 %lld 項",
    "%lld%%": "%lld%%",
    "+ %lld more": "還有 %lld 項",
    "+%lld": "+%lld",
    "14 days": "14 天",
    "30 days": "30 天",
    "7 days": "7 天",
    "90 days": "90 天",

    # ── Sync modes & direction ─────────────────────────────────────────
    "2-Way": "雙向",
    "2-Way Sync": "雙向同步",
    "Google → Mac": "Google → Mac",
    "Mac → Google": "Mac → Google",
    "Sync Mode": "同步模式",
    "Sync Direction": "同步方向",
    "Sync direction": "同步方向",
    "Direction": "方向",
    "Choose Your Sync Direction": "選擇同步方向",
    "Direction: %@. You can turn off this confirmation in Settings → General → Confirmations.":
        "方向：%@。你可以在「設定 → 一般 → 確認提示」中關閉此確認。",

    # ── Core actions ───────────────────────────────────────────────────
    "Sync": "同步",
    "Sync Now": "立即同步",
    "Sync Contacts Now": "立即同步聯絡人",
    "Sync Status": "同步狀態",
    "Sync status": "同步狀態",
    "Sync progress": "同步進度",
    "Sync Preview": "同步預覽",
    "Sync Failed": "同步失敗",
    "Sync completed": "同步完成",
    "Sync finished.": "同步已結束。",
    "Sync History": "同步記錄",
    "Sync History & Backups": "同步記錄與備份",
    "Sync Configuration": "同步設定",
    "Syncing Contacts": "正在同步聯絡人",
    "Start sync now?": "要立即開始同步嗎？",
    "Start syncing contacts": "開始同步聯絡人",
    "A sync is already in progress.": "已有同步作業正在進行。",
    "Run a sync now using the mode selected below": "以下方選取的模式立即執行同步",
    "Run your first sync to see activity here.": "執行第一次同步後,這裡就會顯示紀錄。",
    "Cancel": "取消",
    "Close": "關閉",
    "Done": "完成",
    "Continue": "繼續",
    "Back": "上一步",
    "Next": "下一步",
    "Previous": "上一個",
    "Skip": "略過",
    "Select": "選取",
    "Selected": "已選取",
    "Change": "變更",
    "Clear": "清除",
    "View": "檢視",
    "Help": "說明",
    "Match": "配對",
    "Field": "欄位",
    "Details": "詳細資料",
    "Resolution": "解決方式",
    "Conflict": "衝突",
    "Timeline": "時間軸",
    "Stats": "統計",
    "Filters": "篩選",
    "Schedule": "排程",
    "Interval": "間隔",
    "Convention": "慣例",
    "Model": "模型",
    "Safety": "安全",
    "Performance": "效能",
    "Permissions": "權限",
    "Automation": "自動化",
    "Advanced": "進階",
    "Important": "重要",
    "Recommendations": "建議",
    "more": "更多",
    "and %lld more…": "還有 %lld 項…",

    # ── Accounts ───────────────────────────────────────────────────────
    "Google": "Google",
    "Mac": "Mac",
    "Google Account": "Google 帳號",
    "Google Account:": "Google 帳號：",
    "Google Contacts": "Google 聯絡人",
    "Google Account not connected": "尚未連接 Google 帳號",
    "Mac Contacts": "Mac 聯絡人",
    "Mac Contacts Access": "Mac 聯絡人取用權限",
    "Connect": "連接",
    "Connected": "已連接",
    "Connecting…": "正在連接…",
    "Not connected": "尚未連接",
    "Connect Google Account": "連接 Google 帳號",
    "Connect both accounts to sync": "請連接兩邊帳號才能同步",
    "Connect a Google account and grant Contacts access first":
        "請先連接 Google 帳號並授予聯絡人取用權限",
    "Connect your Google account and grant Contacts access to start syncing.":
        "連接你的 Google 帳號並授予聯絡人取用權限即可開始同步。",
    "Sign In with Google…": "使用 Google 登入…",
    "Sign Out": "登出",
    "Sign in so Contact SyncMate can access your Google Contacts.":
        "登入後 Contact SyncMate 才能取用你的 Google 聯絡人。",
    "Sign-in failed: %@": "登入失敗：%@",
    "Authenticating…": "正在驗證…",
    "Manage": "管理",
    "Account mode:": "帳號模式：",
    "Selected Account:": "已選帳號：",
    "No account selected": "尚未選擇帳號",
    "Select Account…": "選擇帳號…",
    "Select a Contacts Account": "選擇聯絡人帳號",
    "No Contacts Accounts Found": "找不到聯絡人帳號",
    "Your Mac doesn't have any contacts accounts configured":
        "你的 Mac 尚未設定任何聯絡人帳號",
    "Loading accounts…": "正在載入帳號…",
    "Choose which Mac Contacts account to use for syncing with Google":
        "選擇要與 Google 同步的 Mac 聯絡人帳號",
    "Refresh contact count": "重新整理聯絡人數量",
    "Test Connection": "測試連線",
    "Verify connection to Google Contacts API": "驗證與 Google 聯絡人 API 的連線",
    "Verify access to Mac Contacts": "驗證 Mac 聯絡人的取用權限",
    "Required for syncing contacts with Google Contacts via the People API.":
        "透過 People API 與 Google 聯絡人同步時必須具備。",
    "Google account is not connected. Open Contact SyncMate → Settings → Accounts to sign in.":
        "尚未連接 Google 帳號。請開啟 Contact SyncMate → 設定 → 帳號 進行登入。",
    "Google account not connected — open Settings → Accounts to sign in.":
        "尚未連接 Google 帳號 — 請開啟「設定 → 帳號」登入。",
    "Mac Contacts access not granted — open Settings → Accounts to authorize.":
        "尚未取得 Mac 聯絡人權限 — 請開啟「設定 → 帳號」授權。",
    "Sign in to Google (Accounts tab) to export Google contacts.":
        "請先登入 Google(帳號頁籤)才能匯出 Google 聯絡人。",
    "Grant Contacts access (Accounts tab) to export Mac contacts.":
        "請先授予聯絡人權限(帳號頁籤)才能匯出 Mac 聯絡人。",

    # ── Permissions ────────────────────────────────────────────────────
    "Access required": "需要取用權限",
    "Access granted": "已授予權限",
    "Access denied": "已拒絕權限",
    "Granted": "已授權",
    "Allow Access": "允許取用",
    "Allow Contacts Access": "允許取用聯絡人",
    "Grant Access": "授予權限",
    "Requesting…": "正在請求…",
    "Setup Required": "需要設定",
    "Contact SyncMate needs access to your Mac contacts to sync them.":
        "Contact SyncMate 需要取用你的 Mac 聯絡人才能進行同步。",
    "Contact SyncMate needs permission to read and write your Mac contacts.":
        "Contact SyncMate 需要讀取及寫入你的 Mac 聯絡人的權限。",
    "Open System Settings → Privacy & Security → Contacts and enable Contact SyncMate.":
        "請開啟「系統設定 → 隱私權與安全性 → 聯絡人」並啟用 Contact SyncMate。",
    "Open Accounts Settings": "開啟帳號設定",
    "Open Settings": "開啟設定",
    "Open System Settings": "開啟系統設定",

    # ── Onboarding ─────────────────────────────────────────────────────
    "Welcome to Contact SyncMate": "歡迎使用 Contact SyncMate",
    "Contact SyncMate": "Contact SyncMate",
    "Keep your Google and Mac contacts in perfect sync — privately, on your device.":
        "讓你的 Google 與 Mac 聯絡人保持一致 — 全程在你的裝置上進行,不外傳。",
    "Get Started": "開始使用",
    "Resume Setup": "繼續設定",
    "Skip setup": "略過設定",
    "Finish setting up Contact SyncMate": "完成 Contact SyncMate 設定",
    "Step %lld of %lld": "步驟 %1$lld / %2$lld",
    "Step %lld. %@": "步驟 %1$lld。%2$@",
    "What will happen": "接下來會發生什麼",
    "You can always change this later in Preferences.": "你隨時可以在「設定」中更改。",
    "Your contacts stay on your device. No third-party servers are involved.":
        "你的聯絡人只留在你的裝置上,不經過任何第三方伺服器。",

    # ── Fields to sync ─────────────────────────────────────────────────
    "Fields to Sync": "要同步的欄位",
    "Deselected fields are left untouched on both sides during every sync.":
        "未選取的欄位在每次同步時,兩邊都不會被變更。",
    "Notes": "備註",
    "Notes sync is unavailable in this build — Apple restricts the Contacts note field to apps with an approved entitlement.":
        "此版本無法同步備註欄位 — Apple 限制只有取得核准權限的 App 才能存取聯絡人備註。",

    # ── Name formatting ────────────────────────────────────────────────
    "Name Formatting": "姓名格式",
    "Normalise name formatting during sync": "同步時標準化姓名格式",
    "Apply a consistent casing convention to names as they are written":
        "寫入姓名時套用一致的大小寫慣例",
    "Normalise postal country codes": "標準化郵遞國碼",
    "Standardise country codes in postal addresses during sync":
        "同步時統一地址中的國碼格式",
    "Off by default — your names are never rewritten unless you opt in. Chinese, Japanese, and Korean names are always left unchanged. Title Case handles \"van der Berg\", \"McDonald\", and \"O'Brien\" correctly.":
        "預設關閉 — 除非你主動開啟,姓名不會被改寫。中文、日文、韓文姓名一律保持原樣。首字母大寫模式能正確處理「van der Berg」、「McDonald」與「O'Brien」。",

    # ── Duplicates / AI matching ────────────────────────────────────────
    "AI Matching": "AI 配對",
    "AI-Powered Matching": "AI 智慧配對",
    "AI Analysis": "AI 分析",
    "AI Score": "AI 評分",
    "AI: %@": "AI：%@",
    "AI adjusted score: %lld → %lld": "AI 調整後評分：%1$lld → %2$lld",
    "Enable AI matching": "啟用 AI 配對",
    "Run the AI matching pipeline during duplicate detection":
        "在偵測重複項時執行 AI 配對流程",
    "Catch duplicates that rule-based scoring misses — nicknames, name initials, transposed names, phonetic variants, and phone-number format differences.":
        "找出規則式評分會漏掉的重複項 — 暱稱、姓名縮寫、姓名顛倒、發音變體,以及電話號碼格式差異。",
    "Local NLP Signals (always active)": "本機 NLP 訊號(永久啟用)",
    "These run instantly on-device with no network access required.":
        "這些完全在裝置上即時執行,不需要網路。",
    "Cloud AI (Anthropic API)": "雲端 AI(Anthropic API)",
    "Anthropic API Key": "Anthropic API 密鑰",
    "Show API key": "顯示 API 密鑰",
    "Hide API key": "隱藏 API 密鑰",
    "Test API Key": "測試 API 密鑰",
    "Get a key at console.anthropic.com — stored securely in the macOS Keychain":
        "可於 console.anthropic.com 取得密鑰 — 會安全儲存在 macOS 鑰匙串中",
    "Which Claude model analyses borderline duplicate pairs":
        "由哪個 Claude 模型分析難以判定的重複配對",
    "The cloud tier is called only for ambiguous pairs — never for high-confidence matches or when you're offline.":
        "只有在配對難以判定時才會呼叫雲端 — 高信心配對或離線時都不會呼叫。",
    "Optional. Without a key, only the on-device NLP signals above are used — still effective for most duplicates. With a key, borderline matches (rule score %lld–%lld) are escalated to the selected Claude model.":
        "選用。未填密鑰時只會使用上方的本機 NLP 訊號 — 對多數重複項仍然有效。填入密鑰後,難以判定的配對(規則評分 %1$lld–%2$lld)會交由所選的 Claude 模型判斷。",
    "Score Ranges": "評分範圍",
    "Call API for rule scores in range: %lld – %lld":
        "在此規則評分範圍內呼叫 API：%1$lld – %2$lld",
    "Wider range = more API calls and higher accuracy; narrower = fewer calls and lower cost.":
        "範圍越寬 = API 呼叫越多、準確度越高;越窄 = 呼叫越少、成本越低。",
    "Detection Sensitivity": "偵測靈敏度",
    "Deduplication Settings": "重複項處理設定",
    "Detect duplicates before sync": "同步前偵測重複項",
    "Scan for duplicate contacts before changes are applied":
        "在套用變更前掃描重複的聯絡人",
    "Possible Duplicates": "可能的重複項",
    "Review Possible Duplicates": "檢視可能的重複項",
    "No Duplicates Found": "未找到重複項",
    "All contacts appear to be unique.": "所有聯絡人看起來都沒有重複。",
    "These contacts appear to be the same person. Please confirm how to handle them.":
        "這些聯絡人看起來是同一個人。請確認要如何處理。",
    "Automatic Merging": "自動合併",
    "Auto-merge": "自動合併",
    "Auto-merge threshold:": "自動合併門檻：",
    "Enable auto-merge for high-confidence matches": "對高信心配對啟用自動合併",
    "Automatically merge contacts with score ≥ %lld": "自動合併評分 ≥ %lld 的聯絡人",
    "Score must be ≥ %lld for automatic merge": "評分須 ≥ %lld 才會自動合併",
    "Max group size for auto-merge:": "自動合併的群組上限：",
    "Groups with more than %lld contacts always need confirmation":
        "超過 %lld 位聯絡人的群組一律需要確認",
    "Confirmation threshold:": "確認門檻：",
    "Contacts with score %lld-%lld will prompt for confirmation":
        "評分 %1$lld-%2$lld 的聯絡人會要求確認",
    "User Confirmation": "使用者確認",
    "Require confirmation on first sync": "首次同步時要求確認",
    "Even high-confidence matches need manual confirmation on first sync":
        "即使是高信心配對,首次同步時仍需人工確認",
    "How scoring works": "評分機制說明",
    "Pattern Memory": "模式記憶",
    "Remember my decisions for similar matches": "記住我對類似配對的決定",
    "Remember this choice for similar matches": "記住此選擇並套用於類似配對",
    "Learn from your choices to auto-apply decisions for similar duplicate patterns":
        "從你的選擇中學習,自動套用到類似的重複模式",
    "Auto-merge patterns": "自動合併模式",
    "Keep separate patterns": "保持分開的模式",
    "Skip patterns": "略過的模式",
    "Total saved patterns": "已儲存的模式總數",
    "Clear All Saved Patterns": "清除所有已儲存的模式",
    "Clear All Saved Patterns?": "要清除所有已儲存的模式嗎？",
    "This will remove all saved duplicate resolution patterns. You'll be asked to confirm duplicates again.":
        "這會移除所有已儲存的重複項處理模式,之後系統會再次請你確認重複項。",
    "Merge Behaviour": "合併行為",
    "Merge Preview": "合併預覽",
    "Merged Result": "合併結果",
    "Preview Merged Result": "預覽合併結果",
    "Original Contacts (%lld)": "原始聯絡人(%lld)",
    "Merge during 2-way sync": "雙向同步時合併欄位",
    "Merge during 1-way sync": "單向同步時合併欄位",
    "Combine fields from both sides rather than overwriting":
        "合併兩邊的欄位,而非直接覆寫",
    "Merge fields during 1-way sync instead of full replacement":
        "單向同步時合併欄位,而非整筆取代",
    "Apply Decision": "套用決定",
    "Apply Decisions": "套用決定",
    "Your decision:": "你的決定：",
    "Values found:": "找到的值：",
    "Chosen: %@": "已選：%@",

    # ── Conflicts / preview ────────────────────────────────────────────
    "Changes & Conflicts": "變更與衝突",
    "Conflicts need review": "有衝突需要檢視",
    "Default Conflict Resolution": "預設衝突解決方式",
    "Apply %lld Change%@": "套用 %1$lld 項變更%2$@",
    "Nothing to Apply": "沒有可套用的項目",
    "All changes skipped": "已略過所有變更",
    "No changes": "沒有變更",
    "No %@ changes": "沒有 %@ 變更",
    "Switch to \"All\" to see other pending changes.": "切換到「全部」可查看其他待處理變更。",
    "Generating preview...": "正在產生預覽…",
    "Preview what would change without writing anything":
        "預覽將會變更的內容,但不寫入任何資料",
    "Dry run mode": "試執行模式",
    "Dry run is active — no changes will be saved.": "試執行已啟用 — 不會儲存任何變更。",
    "Force update all contacts": "強制更新所有聯絡人",
    "Write every contact even if it appears unchanged":
        "即使聯絡人看起來沒有變動,也一律寫入",
    "Force update is useful after fixing data corruption. Dry run is useful for auditing what a sync will do.":
        "修復資料損毀後適合使用強制更新;想稽核同步會做什麼時適合使用試執行。",
    "Per-contact overrides are always available in the Sync Preview.":
        "你隨時可以在「同步預覽」中逐一覆寫個別聯絡人。",

    # ── Deletions ──────────────────────────────────────────────────────
    "Sync deleted contacts": "同步已刪除的聯絡人",
    "Propagate deletions across sides": "將刪除同步到另一邊",
    "Confirm pending deletions": "確認待刪除項目",
    "Show pending deletions for review before they are applied":
        "在套用前顯示待刪除項目以供檢視",
    "Show a confirmation sheet for contacts that will be deleted":
        "對即將刪除的聯絡人顯示確認視窗",

    # ── Auto sync ──────────────────────────────────────────────────────
    "Auto-sync": "自動同步",
    "Enable automatic sync": "啟用自動同步",
    "Run sync automatically in the background": "在背景自動執行同步",
    "Off — turn on for background sync": "已關閉 — 開啟即可背景同步",
    "Next sync ": "下次同步 ",
    "Next sync will run after current interval elapses.": "下次同步會在目前間隔結束後執行。",
    "Never": "永不",
    "Forever": "永久保留",
    "Run Conditions": "執行條件",
    "Only when on AC power": "僅在接上電源時",
    "Only when on Wi-Fi": "僅在使用 Wi-Fi 時",
    "Only when Mac is idle": "僅在 Mac 閒置時",
    "Skip auto sync when running on battery": "使用電池時略過自動同步",
    "Skip auto sync on cellular or metered connections":
        "使用行動網路或計量連線時略過自動同步",
    "Skip auto sync while you're actively using your Mac":
        "你正在使用 Mac 時略過自動同步",
    "Auto sync will be skipped when any active condition is not met.":
        "任一啟用的條件不符合時,就會略過自動同步。",
    "No conditions set — auto sync will run unconditionally at the chosen interval.":
        "未設定任何條件 — 自動同步會依所選間隔無條件執行。",

    # ── Groups / filters ───────────────────────────────────────────────
    "Filter sync by groups / labels": "依群組／標籤篩選同步範圍",
    "Only sync contacts that belong to selected groups or labels":
        "只同步屬於所選群組或標籤的聯絡人",
    "No groups selected — the filter matches nothing. Select at least one group or label, or turn filtering off.":
        "未選取任何群組 — 篩選條件不會符合任何項目。請至少選一個群組或標籤,或關閉篩選。",

    # ── Backups ────────────────────────────────────────────────────────
    "Backups": "備份",
    "Backup Status": "備份狀態",
    "Backup Details": "備份詳細資料",
    "Backup Summary": "備份摘要",
    "Backup Information": "備份資訊",
    "Backup Timeline": "備份時間軸",
    "Backup Location": "備份位置",
    "Automatic Backups": "自動備份",
    "Manual Backup": "手動備份",
    "Create Backup Now": "立即建立備份",
    "Backing Up…": "正在備份…",
    "Automatically create a snapshot before every sync": "每次同步前自動建立快照",
    "Creates a safety backup before every sync operation. Recommended.":
        "在每次同步作業前建立安全備份。建議啟用。",
    "Backups will be created automatically during syncs": "同步過程中會自動建立備份",
    "Backed up %lld contacts successfully": "已成功備份 %lld 位聯絡人",
    "Contacts in Backup": "備份中的聯絡人",
    "Total Backups": "備份總數",
    "Total Contacts": "聯絡人總數",
    "Storage Used": "已用儲存空間",
    "Last Backup": "最近備份",
    "Newest Backup": "最新備份",
    "Oldest Backup": "最舊備份",
    "Recent Backup Files": "最近的備份檔案",
    "No Backups": "沒有備份",
    "No backups yet - run a sync to create backups": "尚無備份 — 執行同步即會建立備份",
    "No backup files yet": "尚無備份檔案",
    "Keep at most": "最多保留",
    "Older backups are pruned automatically once this limit is reached":
        "達到此上限後,較舊的備份會自動清除",
    "Backup storage exceeds 1 GB": "備份佔用空間已超過 1 GB",
    "Consider cleaning up old backups (>50 total)": "建議清理舊備份(總數已超過 50)",
    "Change Location…": "變更位置…",
    "Choose a different folder for backups": "為備份選擇其他資料夾",
    "Reset to Default": "重設為預設值",
    "Return to the app's default backup folder": "回到 App 的預設備份資料夾",
    "Open in Finder": "在 Finder 中開啟",
    "Reveal in Finder": "在 Finder 中顯示",
    "Reveal backup folder in Finder": "在 Finder 中顯示備份資料夾",
    "Restore": "還原",
    "Restore from Backup": "從備份還原",
    "This will restore all contacts to a previous state": "這會將所有聯絡人還原到先前狀態",
    "Replaces your current contacts with the contents of this backup.":
        "會以此備份的內容取代你目前的聯絡人。",
    "Current contacts will be replaced. Make sure you want to continue.":
        "目前的聯絡人將被取代。請確認你要繼續。",
    "Opens a detailed view of the backup contents.": "開啟備份內容的詳細檢視。",
    "View Full Details": "檢視完整詳細資料",
    "View History & Backups": "檢視記錄與備份",
    "Version History": "版本記錄",
    "No Version History": "沒有版本記錄",
    "This contact has no previous versions": "此聯絡人沒有先前的版本",
    "Version %lld": "版本 %lld",
    "Versions (%lld)": "版本(%lld)",
    "Created": "建立時間",

    # ── History ────────────────────────────────────────────────────────
    "Recent Changes": "最近的變更",
    "No Sync History": "沒有同步記錄",
    "No sync history yet": "尚無同步記錄",
    "Sync history will appear here": "同步記錄會顯示在這裡",
    "Search history": "搜尋記錄",
    "Filter history": "篩選記錄",
    "No results for \"%@\"": "找不到「%@」的結果",
    "Sync errors": "同步錯誤",
    "Keep history for": "記錄保留期限",
    "Events older than this are removed automatically": "超過此期限的事件會自動移除",
    "Data & History": "資料與記錄",
    "Export": "匯出",
    "Export Log": "匯出記錄",
    "Export to File": "匯出到檔案",
    "CSV…": "CSV…",
    "Excel…": "Excel…",
    "One-off spreadsheet exports for archiving or importing elsewhere. Snapshots above are the app's own restore format.":
        "一次性的試算表匯出,適合封存或匯入其他工具。上方的快照才是 App 自己的還原格式。",

    # ── Appearance / general ───────────────────────────────────────────
    "Appearance": "外觀",
    "Theme": "主題",
    "Accent colour": "強調色",
    "Tint for buttons and highlights. System follows your macOS accent colour.":
        "按鈕與標示的色調。「系統」會跟隨你的 macOS 強調色。",
    "Follow the system, or force light / dark mode for Contact SyncMate only":
        "跟隨系統,或僅為 Contact SyncMate 強制使用淺色／深色模式",
    "Launch at login": "登入時啟動",
    "Start Contact SyncMate automatically when you log in":
        "登入時自動啟動 Contact SyncMate",
    "Keep app in menu bar only": "只在選單列中顯示",
    "When enabled, Contact SyncMate won't appear in the Dock":
        "啟用後,Contact SyncMate 不會出現在 Dock 中",
    "Use monochrome menu bar icon": "使用單色選單列圖像",
    "Display a monochrome icon in the menu bar": "在選單列顯示單色圖像",
    "Show pending-changes badge on icon": "在圖像上顯示待處理變更標記",
    "Display a badge count on the menu bar icon for pending changes":
        "在選單列圖像上顯示待處理變更的數量標記",
    "Menu Bar Popover": "選單列彈出視窗",
    "Show account status rows": "顯示帳號狀態列",
    "Show auto-sync toggle": "顯示自動同步開關",
    "Show sync result banner": "顯示同步結果橫幅",
    "Show navigation shortcuts": "顯示導覽捷徑",
    "Google and Mac account rows in the menu bar popover":
        "選單列彈出視窗中的 Google 與 Mac 帳號列",
    "Quick auto-sync on/off switch in the popover": "彈出視窗中的自動同步快速開關",
    "Success/failure banner after each sync": "每次同步後的成功／失敗橫幅",
    "Dashboard / History / Preferences links in the popover":
        "彈出視窗中的儀表板／記錄／設定連結",
    "Trim the menu bar popover down to just what you use. Sync Now and Quit are always shown.":
        "把選單列彈出視窗精簡到只留你會用到的項目。「立即同步」與「結束」一律顯示。",

    # ── Language ───────────────────────────────────────────────────────
    "Language": "語言",
    "Interface language": "介面語言",
    "System Default": "系統預設",
    "The interface language changes after the app restarts.":
        "介面語言會在 App 重新啟動後變更。",
    "Restart the app after changing the language": "變更語言後請重新啟動 App",
    "Restart to change the language?": "要重新啟動以變更語言嗎？",
    "Restart Now": "立即重新啟動",
    "Later": "稍後",
    "Contact SyncMate needs to restart before the interface appears in the language you picked. Your settings are already saved. A sync in progress will be interrupted.":
        "Contact SyncMate 需要重新啟動,介面才會以你選擇的語言顯示。你的設定已儲存。正在進行的同步會被中斷。",

    # ── Confirmations ──────────────────────────────────────────────────
    "Confirmations": "確認提示",
    "Ask before Sync Now": "執行「立即同步」前先詢問",
    "Ask before restoring a backup": "還原備份前先詢問",
    "Ask before deleting contacts": "刪除聯絡人前先詢問",
    "Allow silent auto-merge of duplicates": "允許靜默自動合併重複項",
    "Show a confirmation dialog when clicking Sync Now":
        "點選「立即同步」時顯示確認對話框",
    "Delete all sync events?":
        "刪除所有同步事件？",
    "Google account is not connected":
        "尚未連接 Google 帳戶",
    "No backups yet":
        "尚無備份",
    "Backups are created automatically during syncs.":
        "備份會在同步時自動建立。",
    "No version history yet":
        "尚無版本記錄",
    "It builds up as syncs create backups.":
        "隨著同步建立備份，版本記錄會逐步累積。",
    "No contacts match your search":
        "沒有符合搜尋的聯絡人",
    "Reset Settings Only":
        "僅重設偏好設定",
    "Reset Everything":
        "完整重設",
    "The People API is not enabled for this Google Cloud project. Open the project's API Library, enable People API, then wait a minute and try again.":
        "此 Google Cloud 專案尚未啟用 People API。請開啟專案的 API 程式庫，啟用 People API，等候約一分鐘後再試。",
    "The connected account did not grant the Contacts permission. Sign out in Settings → Accounts, sign in again, and approve the Contacts scope.":
        "已連接的帳戶未授予聯絡人權限。請到「設定 → 帳戶」登出後重新登入，並允許聯絡人權限。",
    "Google refused this request. If the app's publishing status is Testing, the signed-in address must be listed as a test user in the OAuth consent screen.":
        "Google 拒絕了這個請求。若應用程式的發布狀態為「測試中」，登入的電子郵件必須列在 OAuth 同意畫面的測試使用者名單中。",
    "Copy":
        "拷貝",
    "Copy All Recent Changes":
        "拷貝所有近期變更",
    "This Client ID belongs to a Desktop or Web OAuth client, which requires a secret. Create an iOS client in Google Cloud Console — that is the type Google requires for macOS apps, and it needs no secret — then run Scripts/set-oauth-client.sh with its Client ID.":
        "這個 Client ID 屬於 Desktop 或 Web 類型的 OAuth 用戶端，需要 secret。請在 Google Cloud Console 建立 iOS 類型的用戶端 —— 那是 Google 對 macOS app 要求的類型，且不需要 secret —— 然後用它的 Client ID 執行 Scripts/set-oauth-client.sh。",
    "Erase All My Data & Sign Out":
        "清除我的所有資料並登出",
    "Reset Settings Only restores preferences. Reset Everything also deletes every backup, the sync log, the contact mappings and the duplicate decisions — deleted backups cannot be recovered, so nothing will be left to undo a past sync with. Erase All My Data does that and additionally removes the stored Google and API credentials and signs you out. None of them touch the contacts themselves, on this Mac or in your Google account.":
        "「僅重設偏好設定」只還原設定。「完整重設」還會刪除所有備份、同步記錄、聯絡人配對與重複判定 —— 已刪除的備份無法復原，之後將沒有任何東西可用來還原先前的同步。「清除我的所有資料並登出」在此之上再移除已儲存的 Google 與 API 憑證並登出。三者都不會動到聯絡人本身，無論在這台 Mac 或你的 Google 帳戶中。",
    "Reset Settings Only restores preferences. Reset Everything also deletes every backup, the sync log and the contact mappings — deleted backups cannot be recovered, so nothing will be left to undo a past sync with. Neither option touches your contacts or your Google sign-in.":
        "「僅重設偏好設定」只還原設定。「完整重設」還會刪除所有備份、同步記錄與聯絡人配對 —— 已刪除的備份無法復原，之後將沒有任何東西可用來還原先前的同步。兩者都不會動到你的聯絡人或 Google 登入。",
    "Run a sync, review pending changes and read the activity log in the Dashboard (⌘1).":
        "同步、檢視待處理變更與活動記錄，都在儀表板（⌘1）中進行。",
    "Delete all recorded sync events. Backups and contacts are not affected.":
        "刪除所有已記錄的同步事件。備份與聯絡人不受影響。",
    "Delete all recorded sync events. Backups are not affected.":
        "刪除所有已記錄的同步事件。備份不受影響。",
    "This clears the recorded activity log only. Your backups and contacts are not affected.":
        "這只會清除活動記錄，你的備份與聯絡人不受影響。",
    "Reload sync events and backups now":
        "立即重新載入同步事件與備份",
    "Refresh":
        "重新整理",
    "Apply Changes Directly":
        "直接套用變更",
    "Review Before Applying":
        "套用前先檢視",
    "Sync Now applies every change immediately":
        "「立即同步」會直接套用所有變更",
    "Automatic syncs will not delete contacts. Deletions are listed for you to apply from Sync Now.":
        "自動同步不會刪除聯絡人。待刪除的項目會列出，由你在「立即同步」中檢視後套用。",
    "Show a confirmation dialog before a restore rewrites contacts":
        "還原覆寫聯絡人前顯示確認對話框",
    "Apply high-confidence duplicate merges without asking. Off = always review.":
        "不詢問即套用高信心的重複項合併。關閉 = 一律人工檢視。",
    "Choose which actions ask for confirmation. Safer defaults are pre-selected; skip confirmations you find repetitive.":
        "選擇哪些動作需要確認。預設已選較安全的選項;覺得重複的確認可以關閉。",
    "These safeguards are recommended. Disabling them speeds up sync but increases the risk of data loss.":
        "建議保留這些防護。關閉可加快同步,但會提高資料遺失的風險。",

    # ── Notifications ──────────────────────────────────────────────────
    "Notifications": "通知",
    "Notify when a sync finishes successfully": "同步成功完成時通知",
    "Notify when a sync fails": "同步失敗時通知",
    "Notify when conflicts need your attention": "有衝突需要你處理時通知",
    "Open Notification Settings…": "開啟通知設定…",

    # ── Performance ────────────────────────────────────────────────────
    "Batch Google API updates": "批次處理 Google API 更新",
    "Send up to 100 changes per API call for faster sync":
        "每次 API 呼叫最多送出 100 項變更以加快同步",

    # ── Reset ──────────────────────────────────────────────────────────
    "Reset All Settings to Defaults…": "將所有設定重設為預設值…",
    "Reset Settings": "重設設定",
    "Reset all settings?": "要重設所有設定嗎？",
    "All preferences will return to defaults. Your Google account connection will not be affected.":
        "所有偏好設定會回到預設值。你的 Google 帳號連線不會受影響。",

    # ── Menu bar / windows ─────────────────────────────────────────────
    "Open Dashboard": "開啟儀表板",
    "Open Preferences": "開啟設定",
    "Settings…": "設定…",
    "Quit Contact SyncMate": "結束 Contact SyncMate",
    "Closes Contact SyncMate.": "結束 Contact SyncMate。",
    "Opens %@.": "開啟 %@。",
    "Runs %@": "執行 %@",
    "Runs a contact sync between Google Contacts and Mac Contacts using your configured direction and settings.":
        "依你設定的方向與選項,在 Google 聯絡人與 Mac 聯絡人之間執行同步。",
    "Get Last Sync Status": "取得最近同步狀態",
    "Returns a summary of the most recent contact sync.": "回傳最近一次聯絡人同步的摘要。",
    "Review…": "檢視…",
    "Loading…": "正在載入…",
    "Loading statistics...": "正在載入統計資料…",
    "Applied on next sync": "下次同步時生效",
    "·": "·",
    "•": "•",
    "• %@": "• %@",
    "sk-ant-…": "sk-ant-…",
    "English": "English",
    "繁體中文": "繁體中文",
    "简体中文": "简体中文",

    # ── Reached only via String(localized:) ────────────────────────────
    # `init(localized:)` forwards a *variable* to NSLocalizedString, so the
    # build-time extractor cannot see these literals and `xcstringstool sync`
    # never adds them. They are created below with extractionState "manual",
    # which is also what keeps sync from pruning them as stale.
    "System": "系統",
    "Light": "淺色",
    "Dark": "深色",
    "Indigo": "靛藍",
    "Teal": "藍綠",
    "Green": "綠色",
    "Orange": "橘色",
    "Pink": "粉紅",
    "Graphite": "石墨灰",
    "Manual Sync…": "手動同步…",
    "Sync changes in both directions automatically": "自動雙向同步變更",
    "Google contacts are the master, changes sync to Mac only":
        "以 Google 聯絡人為準,變更只同步到 Mac",
    "Mac contacts are the master, changes sync to Google only":
        "以 Mac 聯絡人為準,變更只同步到 Google",
    "Preview and approve each change before syncing": "同步前逐項預覽並核准變更",

    "All": "全部",
    "Changes": "變更",
    "Errors": "錯誤",
    "Sync started": "同步已開始",
    "Contact added": "已新增聯絡人",
    "Contact updated": "已更新聯絡人",
    "Contact deleted": "已刪除聯絡人",
    "Contacts merged": "已合併聯絡人",
    "Change failed": "變更失敗",
    "Backup failed": "備份失敗",
    "Retrying after rate limit": "已達速率上限,正在重試",
    "Mac contacts changed": "Mac 聯絡人已變更",
    "Conflict flagged for review": "衝突已標記待檢視",
    "Duplicates auto-merged": "重複項已自動合併",
    "Duplicates merged": "重複項已合併",
    "Contacts kept separate": "聯絡人保持分開",
    "Duplicates skipped (auto-sync)": "已略過重複項(自動同步)",
    "Contact mapping created": "已建立聯絡人對應",
    "Saved patterns cleared": "已清除儲存的模式",
    "Couldn't export the log": "無法匯出記錄",
    "OK": "好",
    "%lld failed": "%lld 項失敗",
    "No changes yet.": "尚無變更。",
    "Google access has expired. Please sign in again.": "Google 授權已過期,請重新登入。",
    "waiting for AC power": "等待接上電源",
    "waiting for an unmetered network": "等待非計量網路",
    "waiting until the Mac is idle": "等待 Mac 閒置",
    "Unnamed contact": "未命名聯絡人",
    "Hide contact names": "隱藏聯絡人姓名",
    "Replaces names with placeholders so the log can be shared safely":
        "以佔位符取代姓名,讓記錄可以安全分享",
    "Couldn't encode the log.": "無法編碼記錄。",
    "Contacts": "聯絡人",
    "Search contacts": "搜尋聯絡人",
    "No version history yet. It builds up as syncs create backups.":
        "尚無版本記錄。隨著同步建立備份會逐步累積。",
    "No contacts match your search.": "沒有符合搜尋的聯絡人。",
    "Select a contact to see its saved versions": "選擇聯絡人以查看其已儲存的版本",
    "Restore This Version": "還原此版本",
    "Contact restored": "聯絡人已還原",
    "%lld versions · %@": "%1$lld 個版本 · %2$@",
    "%@ was restored to version %lld.": "%1$@ 已還原至版本 %2$lld。",
    "Couldn't restore the contact": "無法還原此聯絡人",
    "Import Backup File…": "匯入備份檔案…",
    "Import Backup": "匯入備份",
    "Load a backup previously exported from Contact SyncMate": "載入先前從 Contact SyncMate 匯出的備份",
    "Delete contacts added since this backup": "刪除此備份之後新增的聯絡人",
    "Both address books will match this backup exactly. Contacts created after it — including any a faulty sync added — will be deleted.":
        "兩邊通訊錄將與此備份完全一致。之後建立的聯絡人 —— 包括錯誤同步所新增的 —— 都會被刪除。",
    "Contacts created after this backup will be kept. Use this if you only want to recover changed or deleted contacts.":
        "此備份之後建立的聯絡人會保留。若你只想復原被修改或刪除的聯絡人,請用這個選項。",
    "A safety snapshot of the current state is taken first, so this restore can itself be undone.":
        "系統會先為目前狀態建立安全快照,因此這次還原本身也可以復原。",
    "Contacts restored": "聯絡人已還原",
    "Your contacts were rolled back to the selected backup.": "你的聯絡人已回復到所選備份的狀態。",
    "Restore incomplete": "還原未完成",
    "Restoring contacts…": "正在還原聯絡人…",
    "Restored %lld contacts, but %lld could not be restored: %@":
        "已還原 %1$lld 位聯絡人,但有 %2$lld 位無法還原：%3$@",
    "Clear Log…": "清除記錄…",
    "Delete All Events": "刪除所有事件",
    "Clear the sync log?": "要清除同步記錄嗎？",
    "All recorded sync events will be deleted. Your contacts and backups are not affected. Export the log first if you might need it for troubleshooting.":
        "所有已記錄的同步事件將被刪除。你的聯絡人與備份不受影響。若日後可能需要排查問題,請先匯出記錄。",
}


# ── Simplified Chinese derivation ───────────────────────────────────────
#
# zh-Hans is *derived* from the table above rather than kept as a second
# hand-written list. Two independent tables drift: someone rewords one and the
# other silently keeps the stale text. Deriving means each string is authored
# once, in one place.
#
# Two stages, in order:
#   1. hant-to-hans.swift converts glyphs through ICU (聯絡人 → 联络人)
#   2. TERMS below fixes mainland vocabulary — an editorial choice ICU has no
#      opinion about (联络人 → 联系人, 介面 → 界面)
TERMS = {
    "联络人": "联系人",
    "介面": "界面",
    "档案": "文件",
    "汇出": "导出",
    "汇入": "导入",
    "预设值": "默认值",
    "预设": "默认",
    "选单列": "菜单栏",
    "选单": "菜单",
    "储存": "保存",
    "网路": "网络",
    "资料": "数据",
    "设定": "设置",
    "视窗": "窗口",
    "快取": "缓存",
    "登入": "登录",
    "帐号": "账号",
    "门槛": "阈值",
    "略过": "跳过",
    "检视": "查看",
    "核准": "批准",
    "讯号": "信号",
    "邮递": "邮政",
    "支援": "支持",
    "作业": "操作",
    "弹出视窗": "弹出窗口",
    "新增": "添加",
    "靛蓝": "藏青",
    "橘色": "橙色",
    "粉红": "粉色",
}


def _converter_binary() -> pathlib.Path:
    """Compile hant-to-hans.swift on demand and cache the binary.

    `swift file.swift` runs in interpreter mode, which both recompiles on every
    invocation and competes for stdin with the program it is running — the
    combination hangs when piping input. Compiling once with swiftc avoids both.
    """
    source = pathlib.Path("Scripts/hant-to-hans.swift")
    binary = pathlib.Path("build/hant-to-hans")

    if binary.exists() and binary.stat().st_mtime >= source.stat().st_mtime:
        return binary

    binary.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["swiftc", "-O", str(source), "-o", str(binary)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"could not compile {source}: {result.stderr.strip()}")
    return binary


def to_simplified(values: list[str]) -> list[str]:
    """Glyph-convert through ICU, then apply mainland terminology."""
    result = subprocess.run(
        [str(_converter_binary())],
        input=json.dumps(values, ensure_ascii=False),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"hant-to-hans failed: {result.stderr.strip()}")

    converted = json.loads(result.stdout)

    # Longest first: without it, "设定" inside "预设值" could be rewritten before
    # the longer phrase is considered.
    ordered = sorted(TERMS.items(), key=lambda kv: len(kv[0]), reverse=True)

    out = []
    for text in converted:
        for hant, hans in ordered:
            text = text.replace(hant, hans)
        out.append(text)
    return out


def main() -> int:
    if not CATALOG.exists():
        print(f"error: {CATALOG} not found — run from the repo root", file=sys.stderr)
        return 1

    catalog = json.loads(CATALOG.read_text())
    strings = catalog["strings"]

    keys = list(T.keys())
    hant_values = [T[k] for k in keys]

    try:
        hans_values = to_simplified(hant_values)
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    # A language names itself in its own script, whatever the converter says.
    self_named = {"繁體中文", "简体中文", "English"}

    created = 0
    for key, hant, hans in zip(keys, hant_values, hans_values):
        entry = strings.get(key)
        if entry is None:
            # Keys only reachable through String(localized:) are invisible to
            # the extractor. "manual" tells xcstringstool they are intentional
            # rather than stale leftovers, so `sync` leaves them alone.
            entry = {"extractionState": "manual"}
            strings[key] = entry
            created += 1

        localizations = entry.setdefault("localizations", {})
        localizations["zh-Hant"] = {
            "stringUnit": {"state": "translated", "value": hant}
        }
        localizations["zh-Hans"] = {
            "stringUnit": {
                "state": "translated",
                "value": hant if hant in self_named else hans,
            }
        }

    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")

    def missing(language: str) -> list[str]:
        return sorted(
            k for k in strings
            if k.strip() and k.strip() != "%lld"
            and language not in strings[k].get("localizations", {})
        )

    print(f"translated: {len(keys)} keys × 2 languages")
    print(f"created as manual entries: {created}")
    for language in ("zh-Hant", "zh-Hans"):
        gaps = missing(language)
        print(f"  {language}: {len(gaps)} untranslated")
        if gaps:
            pathlib.Path(f".l10n_untranslated_{language}.txt").write_text(
                "\n".join(gaps) + "\n"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
