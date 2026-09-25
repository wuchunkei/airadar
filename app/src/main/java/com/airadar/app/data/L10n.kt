package com.airadar.app.data

import java.util.Locale

/**
 * The app's words in the language the system gives it — English, or Simplified
 * Chinese when that's chosen (for the whole phone, or just for Airadar in the
 * system's per-app language setting). Keyed by the English, as iOS's string
 * catalog is; anything without a translation stays English.
 */
object L10n {
    val chinese: Boolean get() = Locale.getDefault().language == "zh"
}

/** [en] in the app's language; with [args], a format string (`%s`, `%d`, `%1$s`…). */
fun tr(en: String, vararg args: Any?): String {
    val template = if (L10n.chinese) ZH[en] ?: en else en
    return if (args.isEmpty()) template else String.format(Locale.ROOT, template, *args)
}

private val ZH: Map<String, String> = mapOf(
    // Tabs, sections, headings
    "Trip" to "行程", "Search" to "搜索", "Community" to "社区", "My" to "我的",
    "Past" to "过往", "Now" to "现在", "Coming" to "即将出行", "Settings" to "设置",
    "Account" to "账户", "Import" to "导入", "Display" to "显示", "Trips" to "行程", "About" to "关于",
    "Friends" to "好友", "Requests" to "请求", "Sent" to "已发送", "History" to "历史",
    "My Reviews" to "我的审核", "My Submissions" to "我的提交", "Recycle Bin" to "回收站",
    "Appearance" to "外观", "System" to "跟随系统", "Light" to "浅色", "Dark" to "深色", "Version" to "版本",
    "Back" to "返回", "Refresh" to "刷新", "My location" to "我的位置", "Your photo" to "你的头像",
    "Distance" to "距离", "Flights" to "航班", "Countries" to "国家/地区", "Cities" to "城市",

    // Detail sheet and cards
    "Airline" to "航空公司", "Status" to "状态", "Departing" to "起飞", "Arriving" to "到达",
    "Gate" to "登机口", "Duration" to "飞行时长", "Aircraft" to "机型", "Baggage claim" to "行李转盘",
    "Booking reference" to "订座编号", "Shared by" to "分享者", "Arrives at " to "到达 ",
    "On time" to "准点", "Delayed" to "延误", "Cancelled" to "已取消", "Diverted" to "已备降",
    "Scheduled" to "计划中", "Completed" to "已完成", "Boarding" to "登机中", "Departed" to "已起飞",
    "In flight" to "飞行中", "Finished" to "已结束", "Landed" to "已落地", "Landed · on time" to "已落地 · 准点",
    "Check-in open" to "值机开放", "Gate open" to "登机口开放", "Final call" to "最后召集",
    "Gate closing" to "登机口即将关闭", "Gate closed" to "登机口已关闭",
    "just now" to "刚刚", "Share" to "分享", "Accept" to "接受", "Together" to "同行", "Reject" to "拒绝",
    "Edit" to "编辑", "Delete" to "删除", "Manual" to "手动", "Blocked" to "已屏蔽", "Expired" to "已过期",
    "Email" to "邮件", "Calendar" to "日历",
    "Refreshing" to "正在刷新", "Release to open past trips" to "松开查看过往行程",
    "Release to refresh · keep pulling for history" to "松开刷新 · 继续下拉查看历史",
    "Pull to refresh" to "下拉刷新",
    "Blocked — this flight couldn't be confirmed" to "已屏蔽 — 无法确认此航班",
    "Unverified — review expired" to "未验证 — 审核已过期", "Imported · needs review" to "已导入 · 待确认",
    "Come to create your first trip!" to "来创建你的第一个行程吧！", "No upcoming trips." to "没有即将出行的行程。",
    "That trip link has expired." to "这个行程链接已过期。",
    "Moved to the Recycle Bin. Restore it from My › Settings › Recycle Bin within 30 days." to
        "已移至回收站。30 天内可在 我的 › 设置 › 回收站 中恢复。",
    "Add to trips" to "添加到行程", "Close" to "关闭",

    // Maps
    "Google Maps" to "Google 地图", "Amap" to "高德地图", "Waze" to "Waze", "Other map app" to "其他地图 App",

    // Share
    "Link copied." to "链接已复制。", "Could not create a link." to "无法创建链接。", "Share trip" to "分享行程",
    "Copy link" to "复制链接", "Share via…" to "通过…分享", "Via" to "方式", "Link" to "链接",
    "Copy" to "复制", "Send…" to "发送…", "Send to friend" to "发送给好友",
    "Pending" to "待回复", "Accepted" to "已接受", "Rejected" to "已拒绝",

    // Pending / imported flight
    "Imported from email" to "从邮件导入", "Flight number" to "航班号", "Departure date" to "出发日期",
    "Route" to "航线", "Found" to "找到", "Correct" to "正确", "Incorrect" to "不正确", "Discard" to "丢弃",
    "Save" to "保存", "Feedback" to "反馈",

    // Settings
    "Continue with Google" to "使用 Google 继续", "Signed in" to "已登录", "Sign out" to "退出登录",
    "Friends can find me by email" to "允许好友通过邮箱找到我", "Read trips from email" to "从邮件读取行程",
    "Read trips from calendar" to "从日历读取行程", "Show times in my time zone" to "以我的时区显示时间",
    "Premium" to "高级版", "No plan" to "无方案", " · grace period" to " · 宽限期", " · lifetime" to " · 终身",
    "Reading calendars" to "正在读取日历", "No flights found in your calendars." to "日历中没有找到航班。",
    "Every calendar flight is already in Trips." to "日历中的航班都已在行程中。",

    // Manual entry
    "Add manually" to "手动添加", "Edit trip" to "编辑行程", "Flight" to "航班", "Tap to set" to "点按设置",
    "From (IATA)" to "出发地 (IATA)", "To (IATA)" to "目的地 (IATA)",
    "Times (local at each airport)" to "时间（各机场当地时间）", "Departure" to "出发", "Arrival" to "到达",
    "Cancel" to "取消", "Add" to "添加", "Is the airline correct?" to "航空公司正确吗？", "Yes" to "是", "No" to "否",
    "Choose" to "选择", "Terminal" to "航站楼", "OK" to "好", "Search airline name or code" to "搜索航空公司名称或代码",
    "No match in the bundled list." to "内置列表中没有匹配项。",
    "Other — my airline isn't listed" to "其他 — 列表中没有我的航空公司", "Suggest an airline" to "建议添加航空公司",
    "e.g. Some New Airline" to "例如：某新航空公司",
    "Not in the bundled list yet — this trip uses the name you type right away, and it's kept on this device to review adding properly later." to
        "尚未收录 — 此行程会直接使用你输入的名称，并保存在本设备上，以便稍后正式收录。",
    "Use this" to "使用这个",

    // Email import
    "Could not read the mailbox." to "无法读取邮箱。", "Google did not return access." to "Google 未授予访问权限。",
    "Google sign-in is unavailable." to "Google 登录不可用。", "Import from email" to "从邮件导入",
    "Read my Gmail" to "读取我的 Gmail", "Searching the mailbox" to "正在搜索邮箱",
    "No mail mentioning a flight in the last two years." to "过去两年没有提到航班的邮件。",
    "Or paste a booking confirmation" to "或粘贴订票确认信息", "Scan the text" to "扫描文字",
    "No new flights recognised." to "没有识别到新航班。",

    // Recycle bin, friends, community
    "Restore" to "恢复", "Restore this trip?" to "恢复此行程？", "Confirm" to "确认",
    "Find by email" to "通过邮箱查找", "Find" to "查找", "Add friend" to "添加好友", "Decline" to "拒绝",
    "Remove" to "移除",
    "No friends yet. Find someone by email, or accept a request from a shared trip." to
        "还没有好友。可通过邮箱查找，或接受共享行程中的请求。",
    "Couldn't load your history." to "无法加载你的历史记录。", "Couldn't load the review queue." to "无法加载审核队列。",
    "You haven't reviewed anything yet." to "你还没有审核过任何内容。",
    "You haven't fed any flights yet." to "你还没有提交过航班。", "Try again" to "重试",
    "Nothing to review right now." to "目前没有需要审核的内容。", " · needs more votes" to " · 需要更多投票",
    "You: Approved" to "你：通过", "You: Rejected" to "你：拒绝",
    "Looks real" to "看起来真实", "Doesn't look real" to "看起来不真实",

    // Search, date picker
    "Search flight" to "搜索航班", "Pick a date" to "选择日期", "Select date" to "选择日期",
    "Year" to "年", "Month" to "月", "Day" to "日", "Network error" to "网络错误",

    // Tiers
    "Black Iron" to "黑铁", "Bronze" to "青铜", "Silver" to "白银", "Gold" to "黄金", "Platinum" to "白金",
    "Diamond" to "钻石", "Ruby" to "红宝石", "Amber" to "琥珀", "Silk" to "丝绸", "Porcelain" to "瓷器",
    "Every journey starts here." to "每段旅程都从这里开始。", "Ten flights and counting." to "十个航班，还在继续。",
    "A quarter-century in the air." to "二十五次翱翔蓝天。", "Fifty flights strong." to "五十个航班，实力见证。",
    "Triple digits — a real habit now." to "三位数了 — 飞行已成习惯。", "Diamond-clear dedication." to "钻石般纯粹的坚持。",
    "Two-fifty, and still climbing." to "二百五十次，仍在爬升。",
    "Preserved in flight, one leg at a time." to "一段一段，封存在飞行之中。",
    "Smooth as the old trade routes." to "顺滑如古老的丝路。", "A secret worth finding." to "一个值得寻找的秘密。",

    // Notifications
    "Trip reminders" to "行程提醒", "The day before, and three hours before departure" to "出发前一天及出发前三小时",
    "Live updates" to "实时动态", "Delays, gate changes, departure and landing" to "延误、登机口变更、起飞与落地",
    "Progress while airborne" to "飞行途中的进度", " · on time" to " · 准点",

    // Templates
    "Navigate to %s" to "导航至 %s",
    "Shared by %s" to "由 %s 分享",
    "Landed from %1\$s %2\$s" to "%2\$s从 %1\$s 落地",
    "%dm ago" to "%d分钟前", "%dh ago" to "%d小时前",
    "%dm" to "%d分钟", "%dh" to "%d小时", "%1\$dh %2\$dm" to "%1\$d小时%2\$d分", "%1\$dh%2\$dm" to "%1\$d时%2\$d分",
    "%1\$s for %2\$s" to "%1\$s %2\$s",
    "%1\$s · %2\$s late" to "%1\$s · 延误 %2\$s",
    "Landed · %s early" to "已落地 · 提前 %s", "Landed · %s late" to "已落地 · 延误 %s",
    "Terminal %s" to "%s 号航站楼",
    "Overlaps with %s — you can't be on two flights at once" to "与 %s 时间重叠 — 你不可能同时乘坐两个航班",
    "Usually %s" to "通常 %s",
    "Share %s" to "分享 %s", "Send to %d friends" to "发送给 %d 位好友",
    "%1\$s %2\$s → %3\$s on %4\$s" to "%4\$s %1\$s %2\$s → %3\$s",
    "No schedule for %1\$s on %2\$s." to "%2\$s 没有 %1\$s 的航班计划。",
    " · until %s" to " · 至 %s",
    "Unknown airport %s." to "未知机场 %s。",
    "Reading mail %1\$d of %2\$d" to "正在读取邮件 %1\$d / %2\$d",
    "Checking flight %1\$d of %2\$d" to "正在核对航班 %1\$d / %2\$d",
    "Read %d candidates; every flight is already in Trips." to "已读取 %d 封候选邮件；所有航班都已在行程中。",
    "%d trips added — open each one in Trips to confirm." to "已添加 %d 个行程 — 请在行程中逐一打开确认。",
    "%d trips added — confirm them in Trips." to "已添加 %d 个行程 — 请在行程中确认。",
    "%d trips added from your calendars — confirm them in Trips." to "已从日历添加 %d 个行程 — 请在行程中确认。",
    "Nothing here. Deleted trips stay for %d days." to "这里空空如也。已删除的行程会保留 %d 天。",
    "%s goes back to your trips, reminders included." to "%s 将回到你的行程中，提醒也会一并恢复。",
    "Deleted %1\$s · gone for good in %2\$d days" to "%1\$s 删除 · %2\$d 天后永久删除",
    "Deleted %1\$s · gone for good in 1 day" to "%1\$s 删除 · 1 天后永久删除",
    "%1\$d approve · %2\$d reject" to "%1\$d 通过 · %2\$d 拒绝",
    "%1\$d/%2\$d flights · %3\$s" to "%1\$d/%2\$d 个航班 · %3\$s",
    "%d flight fed" to "已提交 %d 个航班", "%d flights fed" to "已提交 %d 个航班",
    "%1\$s · Gate %2\$s" to "%1\$s · %2\$s 号登机口",
    "%s's trip" to "%s 的行程",
    "%1\$s tomorrow · %2\$s" to "%1\$s 明天 · %2\$s",
    "Departs %s" to "%s 起飞", " from Terminal %s" to "，%s 号航站楼出发",
    "%1\$s in 3 hours · %2\$s" to "%1\$s 3 小时后 · %2\$s",
    "Scheduled %s · status unavailable" to "计划 %s · 暂无状态",
    "Landing in %1\$s · %2\$s" to "%1\$s后降落 · %2\$s",
    "%s · landed" to "%s · 已落地",
    "Arrived %s" to "%s 抵达",
    "Scheduled arrival %s · actual time unavailable" to "计划 %s 到达 · 暂无实际时间",
    " · Gate %s" to " · %s 号登机口",
    "Delayed to %1\$s (+%2\$d min)" to "延误至 %1\$s（+%2\$d 分钟）",
    "On time · %s" to "准点 · %s",
    " · %d min late" to " · 延误 %d 分钟",
    "%d min" to "%d 分钟", "%1\$d h %2\$d min" to "%1\$d 小时 %2\$d 分钟",
    "%d km" to "%d 公里",
)
