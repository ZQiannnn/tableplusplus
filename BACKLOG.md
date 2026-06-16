# TablePlusPlus — Backlog

> 未做的功能 + 已知风险点。优先级未排序，按主题分组。
> 实现规范 / SPI 契约 / SwiftUI 坑等参见 `CLAUDE.md`。

## 功能

### 数据浏览

- **行编辑 / 右键菜单 / 增删 — 已做，遗留**：update(橙)/insert(绿)/delete(红) 统一草稿模型 → 顶栏 放弃/预览SQL/提交（单事务，顺序 updates→deletes→inserts）。右键菜单 Copy / Copy Row JSON|INSERT / Edit / Set NULL / Set Empty / Filter / Insert Row / Duplicate Row / Delete(标红，红行显示 Cancel Delete)；底部 `+ Insert Row` 按钮；多选（cmd/shift）批量标删 + ⌫/⌦；insert/duplicate 后焦点跳新行。详情编辑框右键 Copy/Paste/Set NULL/Set Empty/Revert Field。`execute()` prepared 协议拿真实 affectedRows，commit 0-affected 软告警不回滚。literal 按 `columnIsNumeric` 决定引号、非 finite float 安全。`openTable` 用 `loadToken`、commit 校验 table+db 防快速切换 stale。待补：
  - **草稿未填列与空串显示都为 EMPTY**：未填(omit→DB DEFAULT) 与显式 Set Empty('') 网格都显示 EMPTY（提交语义不同；`copyRowAsInsert` 已按提交 SQL 一致，Copy Cell / Copy Row JSON 仍取显示值）。要分清需给 DriverCell 加 default 态。
  - **详情字段三态显示**：详情编辑框（AppKit `NSTextView`，多行、深色、右键 = 原生编辑菜单 + Set NULL/Set Empty/Revert）里 NULL 与空串都显示为空文本，靠 dirty 橙底 + 预览 SQL 区分。`sizeThatFits` 按内容 1~~12 行高度自适应（上限 220pt）。
  - **focus 按 grid index 异步**：insert/duplicate 后 async 聚焦用行号，极小概率在聚焦前行含义变化会选错行（有越界守卫不会崩）。理想按 draft UUID 解析。
  - **非事务引擎（MyISAM）部分提交**：`START TRANSACTION`/`ROLLBACK` 无效，中途失败前面的语句已永久生效。需检测引擎或提示。
  - **字符串转义靠手拼**：未处理 NUL/Ctrl-Z 等控制字符；理想是参数化（prepared 协议 binds）。
  - **Filter by This Value 覆盖手写 WHERE**：直接写 `whereText`（已清 structured `filters` 防残留）。覆盖语义是有意取舍，后续可考虑 append `AND (...)`。
  - **dataSchema 不随同表 ALTER 刷新**：仅切表加载一次；外部改表结构后同表 reload 不更新 insert skip / numeric / 空表兜底列。加载失败为空时 duplicate 不跳过 auto_increment/generated（提交报错，属降级）。
  - **draftCount 语义混合**：顶栏数字是 cell 改数 + 新增行数 + 删除行数之和，含义不纯（用户可能以为是行数）。
- **SQL 编辑器 0 行结果丢列**：`runQuery` 的 0 行 SELECT 因 text 协议无 `columnDefinitions` 当普通 `OK`、不显示列头（数据表浏览已用 `dataSchema` 兜底列名、空表可插入）。要彻底修需 binary/prepared 协议拿独立列定义。
- **重复列名右对齐**：网格按 `columns.first{name==}` 取列类型决定对齐，query 结果含重复列名（JOIN）时取第一个同名列类型，对齐可能错（显示问题，正确性无影响）。

### 编辑器 / 历史

- **SQL 编辑器增强**：当前 Queries tab + 主区 TextEditor + ⌘R 执行已可用，结果走 AppKitDataGrid。待办：语法高亮、多语句拆分执行、保存命名查询（`saved_queries` 表，schema 未建）。
- **History 增强**：当前 `query_history` 落盘 + History tab 列表 + 点击回填编辑器已可用。待办：搜索 / 按连接过滤 UI、清空历史按钮、失败项展开看 error。

### 连接 / 驱动

- **PostgreSQL driver**：按 CLAUDE.md "添加新数据库引擎 SOP" 加。
- **SSH 隧道**：Citadel 库；profile 已经有 `ssh: SSHConfig?` 字段；driver 接收 connection 时怎么走隧道还没定，**重要决策**：是 driver 自己 wrap socket，还是 service 层先建好隧道再把 host/port 替换成 localhost？倾向后者（让 driver 简单）。
- **Welcome 窗的 SSH 私钥 / passphrase 字段**：UI 写了，但实际连接时还没接进 SSHConfig 的执行路径。

### 工程化

- **Xcode 工程化**：现在 `swift run` 出来的不是 .app bundle，没法签名 / 公证 / 出 dmg。要发布前必须迁移到 .xcodeproj 或 SwiftPM `executable` + `tuist`/`xcodegen`。这一步做完才能解决 Keychain 真正"始终允许"问题（用 Developer ID 稳定签名，DR 永久不变）。

## 风险点 / 设计裂缝

- **session 切 DB 时清缓存**：当前 `selectDatabase` 没清 `tables` 之外的状态（如果将来加 schema 缓存、行编辑草稿等，**别忘了在切 DB 时清**）。
- **多窗口**：现在 App 是 `WindowGroup`，理论上支持多窗口，但 `WindowResizer` 只看 `NSApp.keyWindow`，多窗会乱。要么改成单窗 `Window`，要么 resizer 按 window 实例追踪。
- **没有 unit test**：driver 实现要有契约测试（mock server / Docker MySQL），现在裸跑全靠手测。
- **MainActor 隔离 + NIO eventloop 交界**：`MySQLDriver` 标 `@unchecked Sendable` 偷懒过 Swift 6 check，将来如果 NIO 升级或加 actor，可能会触发 race。如果加并发查询，先想好 driver 的并发模型。
- **错误本地化**：现在直接展示 `error.localizedDescription`，MySQL 错误是英文且非常技术性。后续可能要做 error 分类 + 友好文案。
