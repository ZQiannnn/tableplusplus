# TablePlusPlus — Claude 协作规范

> 给下次开新 session 的 Claude 看的项目契约。**先读完再动代码**。

## 项目身份

- 开源 macOS 数据库 GUI 客户端，对标 TablePlus。GPL v3。
- 栈：Swift 6.x + SwiftUI + SwiftPM（暂未做 Xcode 工程化）。最低系统 macOS 14。
- 入口：`Sources/TablePlusPlus/App.swift`。`@main struct TablePlusPlusApp`，无 Info.plist —— 走 `AppDelegate.applicationDidFinishLaunching` 强制 `setActivationPolicy(.regular)` + 渲染 dock icon。

## 文件结构

```
Sources/TablePlusPlus/
  App.swift                       // @main + AppDelegate + WindowResizer + RootView 路由
  Models/
    ConnectionProfile.swift       // 用户保存的连接配置（带 engine 字段，向后兼容 decode）
  Services/                       // 所有 I/O + 业务无 UI 依赖的代码
    DatabaseDriver.swift          // ★ SPI 协议（见下）
    DriverRegistry.swift          // ★ engine → factory 路由
    MySQLDriver.swift             // MySQL 实现，包 MySQLNIO
    KeychainService.swift         // macOS Keychain 包装
  Stores/                         // @MainActor @Observable 状态容器
    ConnectionStore.swift         // 连接配置列表（JSON 落盘到 Application Support）
    SessionStore.shared           // 当前 active 会话（持 driver、databases、tables 等）
  Views/
    Welcome/WelcomeView.swift     // 启动窗（连接列表）
    ConnectionForm/...            // 新建/编辑连接表单
    Workspace/WorkspaceView.swift // 连上后的三栏工作区
    Shared/
      AppIcon.swift               // 应用图标（橙→青绿渐变）共享组件
      ErrorDialog.swift           // 全局错误弹窗（仿 TablePlus Error statement）
```

## 强约束

### 1. SPI 模式（绝对不能破坏）

**所有数据库操作必须走 `any DatabaseDriver`，禁止在 Views/Stores 里直接 import 驱动包**（MySQLNIO / PostgresNIO / ...）。

- `Services/DatabaseDriver.swift` 是唯一的抽象契约：connect / close / ping / serverVersion / listDatabases / selectDatabase / listTables / createDatabase / query。
- `Services/DriverRegistry.swift` 是唯一的工厂入口：`DriverRegistry.open(profile:password:)` 根据 `profile.engine` 路由。
- `Services/<Engine>Driver.swift` 是唯一允许 `import MySQLNIO` / `import PostgresNIO` 的地方。

**加新数据库引擎的 SOP**（重要，下次新 session 大概率会被要求）：

1. `Package.swift` 加依赖（如 `https://github.com/vapor/postgres-nio.git`）。
2. `Services/PostgresDriver.swift` 新建，`final class PostgresDriver: DatabaseDriver, @unchecked Sendable`，实现协议方法。
3. `DriverRegistry.factories` 字典里加一行（**唯一改动点之外不能再有改动**）。
4. `DriverRegistry.defaultPort` / `capabilities` 各加一个 case。
5. UI 自动认得，类型选择器自动解锁该 engine（如果有的话）。

如果一项操作引擎无法支持（PG 没有 `USE database`、SQLite 没有 user/pwd），在 driver 内 throw 一个清晰的 error，**不要降级到 UI 里写 `if engine == .postgres`**。

### 2. SwiftUI 已踩过的坑（别再踩）

| 坑 | 触发 | 修法 |
|---|---|---|
| `@State` 在 sheet 重复呈现时不刷新 `initialValue` | 用 `@State editing: T?` + `.sheet(isPresented:)` 模式，第一次开 sheet 内容求值可能 race 拿到旧 `editing` | 改用 `.sheet(item: $optional)` 模式，把"是否打开"和"打开哪个"耦合成一个 Identifiable optional —— 见 `WelcomeView.FormPresentation` |
| `Number` formatter 默认带千位逗号 | `format: .number` 会让 3306 显示成 "3,306" | 用 `format: .number.grouping(.never)` |
| `.windowStyle(.hiddenTitleBar)` + 自绘 toolbar 布局怪 | 隐藏标题栏后仍保留 ~28px 标题栏区域，自绘 toolbar 跟它叠加 / 错位 | 老老实实用默认 title bar，工具栏放在 title bar 下方一行 |
| `.toolbar` 在 `.hiddenTitleBar` 下只占左半 | `placement: .primaryAction` 不会推到 trailing | 同上：用默认 title bar 或纯自绘 |
| `macOS` 自动保存窗口尺寸覆盖 `.defaultSize()` | 关 app 后再打开，恢复上次尺寸 | `AppDelegate` 里给所有 window 调 `setFrameAutosaveName("")`，并实现自定义 `WindowResizer`（见 `App.swift`） |
| Swift 6 strict concurrency 拒绝可变 static | `enum WindowResizer { static var trackResize = false }` 报错 | 整个 enum 加 `@MainActor` |
| 桌面 dock icon 占满画布 | `NSApp.applicationIconImage = renderAppIcon()` 直接渲染，icon 在 dock 里比其他 app 大 | 渲染时套 1024×1024 透明 canvas + 100px inset（HIG 标准），见 `AppDelegate.renderDockIcon` |

### 3. 视觉设计 token

- **AppIcon**（`Views/Shared/AppIcon.swift`）：所有出现 app 标识的地方（启动窗大 icon / row badge / database row 小 icon / dock icon）**必须**用 `AppIcon(size:)`，禁止重复实现圆角+渐变+cylinder。
- 渐变色：橙 `#F78D11` → 青绿 `#00758F`，topLeading → bottomTrailing。
- 字号约定：13px 主、12px 次、11px 标签 / 元数据、10px kbd。
- 不要再尝试用 web UI 库去仿 macOS 原生 —— 这个项目特意从 Tauri+React 弃换 Swift 就是为了拿 native 控件，**直接用 SwiftUI 原生 `TextField` / `Picker` / `Toggle` / `List` 即可**。
- **全局锁定暗色外观**：`AppDelegate` 里 `NSApp.appearance = NSAppearance(named: .darkAqua)`。数据网格 / chrome / 控制台等用的是按 TablePlus 暗色采样的硬编码背景，配语义文字色（`.labelColor` / `.primary`）；若跟随系统进浅色模式，深色文字会叠在硬编码深背景上变不可见。**不要移除这行**，也不要在网格区域用浅色硬编码背景。

### 4. Window 行为

- 启动 / 断开连接：缩小到 720×540（或用户上次在 welcome 拉过的尺寸，存在 `UserDefaults["TablePlusPlus.welcomeSize"]`）。
- 连上之后：自动 expand 到 `screen.visibleFrame`（满屏）。
- 工作区点红 X（traffic-light close）：**不退出 app**，调 `SessionStore.shared.close()` → 自动回 welcome 小窗。`AppDelegate.windowShouldClose` 拦截。
- Welcome 状态下点红 X：正常退出 app。
- 窗口尺寸只在 welcome 状态下记录（`WindowResizer.trackResize` 标志，进 workspace 时关，回 welcome 时开）。

### 5. 数据落盘（SQLite via GRDB）

唯一数据库文件：`~/Library/Application Support/TablePlusPlus/tpp.sqlite`。所有持久化都在这里，**不要再用 JSON / UserDefaults 存业务数据**。

表结构（见 `Services/Persistence.swift` 里的 migrations）：
- `connections` — 连接配置（替代旧 `connections.json`）。`init(from:)` 兼容写法仍保留在 `ConnectionProfile` 但只用于 legacy import。
- `recent_objects` — 最近访问的对象，按 `(connection_id, database)` 分组。
- `query_history` — SQL 执行历史（schema 已建，UI 未消费）。
- `ui_prefs` — 通用 key/value，留给未来的 setting 存储。

**Migration 政策**：
- `Persistence.migrator` 是唯一的 schema 演进入口。
- **绝不修改已发布的 migration**。新版本一律 `m.registerMigration("vN_xxx") { db in ... }` 追加。
- 加新表 / 加列 → 新 migration。删列基本别想，用 nullable 兼容。

**Legacy import**：
- `Persistence.importLegacyIfNeeded()` 在 `AppDelegate.applicationDidFinishLaunching` 头部调一次。
- 老 `connections.json` 会被读入 SQLite 然后**改名为 `.imported`**（不删，万一回滚还在）。
- 老 `UserDefaults["TablePlusPlus.recent.*"]` 会被吃进 `recent_objects` 然后从 UserDefaults 删除。

**所有用户偏好走 `PrefsStore.shared`**（@MainActor @Observable），底层 SQLite `ui_prefs` 表。**禁止 `@AppStorage` / 直接 UserDefaults**（PrefsStore 自己会一次性吃旧 UserDefaults 然后清掉）。

PrefsStore 现有字段：`language` / `showRecently` / `showFunctions` / `showProcedures` / `showViews` / `welcomeWidth` / `welcomeHeight`。

**加新偏好 SOP**：
1. `PrefsStore.swift` 加一行属性（带默认值）
2. `enum Key` 加 key 字符串常量
3. `load()` 里加一行从字典读
4. 加 `setXxx(_:)` 方法，内部调通用 `set(key, value)`
5. UI 用 `prefBinding` 或直接 `prefs.xxx` 读、`prefs.setXxx(...)` 写

**绝不在业务代码里 `UserDefaults.standard.set(...)`**。唯一的 UserDefaults 写在 PrefsStore 的迁移逻辑里。

**未来 backup / restore**：因为所有数据（连接 + 密码引用 + 偏好 + recent + history）都在 `tpp.sqlite`，备份 = copy 这个文件，恢复 = replace 它（注意 Keychain 里的密码是单独存的，备份时要一并 export，恢复时 import 回 Keychain）。

**密码**：依旧 macOS Keychain，service `dev.tableplusplus.app`，account 是 `connection.id.uuidString`。Form Test/Connect 在密码框空时**回退到 Keychain 读**。**绝对不要把密码写进 SQLite**。

### 6. L10n 语言包

唯一入口：`Services/L10n.swift`。

**规则**：
- 所有 UI 字符串（`Text(...)` / `TextField(label:...)` / `Button(...)` 等用户可见处）**必须**用 `L10n.t("key")` 包。
- 禁止中英混杂硬编码（这是用户明确投诉过的）。
- key 命名 `namespace.field`：`welcome.*` / `form.*` / `workspace.*` / `db.*` / `error.*`。
- 加新 key **必须同时**写 `en` 和 `zh` 两个字典里，否则 fallback 会显示 key 名字。

**当前限制（要注意）**：
- `L10n.t(...)` 是 static 函数，**不是** @Observable 依赖。切换语言后已渲染 view 不会自动 refresh，需要重启 app 或重 mount。
- 想做"切语言立刻全屏更新"得改成 `@Environment(L10n.self) private var l10n` 注入 + `l10n.resolved` 读引发依赖。**MVP 不做**，restart 提示即可。

**自动语言探测**：`Locale.current.language.languageCode` 开头是 `zh` → 中文，否则英文。用户可通过 `L10n.shared.language = .en/.zh/.auto` 覆写。

### 5.5 右侧详情面板（硬性要求）

**任何网格的行被选中，右侧 Details 面板都必须能展示该行详情**——数据网格、Structure 的列/索引/触发器网格、SQL 查询结果网格，无一例外。

- 统一模型：`SessionStore.detailFields: [DetailField]`（`DetailField(label, value, isKey, tag)`）。每个网格的选中回调调用对应的 `session.showXxxDetail(index)` 填充它；取消选中调 `clearDetail()`。
- 右侧面板（`WorkspaceView.detailList` + `detailFieldRow`）只渲染 `detailFields`，不关心数据来自哪个网格。
- 新增任何网格 → **必须**接 `onChange(选中索引)` → `showXxxDetail` / `clearDetail`，并在 SessionStore 加对应 `showXxxDetail`。这是不可省略的交互。
- 切 tab / 切视图模式（Data↔Structure）/ 切 Structure 子区 / 切 sidebar tab 时都要 `clearDetail()`，避免显示陈旧详情。

### 6. 错误处理

- **模态 sheet 里的操作失败，错误要内联显示在该 sheet 内**，不能依赖全局 `ErrorDialog`（`session.error` 触发的 sheet 无法盖在已弹出的 sheet 之上，会被吞掉）。参考 `NewTriggerSheet`：执行方法返回 `String?` 错误信息，sheet 内 `@State errorMsg` 红字展示。

- Store 层 throw —— **绝不 swallow `try?`**（除了 close / 不影响功能的辅助操作）。
- Views 层 do/catch，写到 `SessionStore.shared.error: String?` 或本地 `@State error`，触发 `ErrorDialog`。
- `ErrorDialog`（`Views/Shared/ErrorDialog.swift`）是全局错误样式，仿 TablePlus 的 "Error statement" 弹窗。不要随便用 `.alert(...)`，那个样式不好看。

### 7. 命名 / Swift 风格

- `@Observable` 的 store 都用 `final class` + `@MainActor`，单例叫 `.shared`（目前只有 `SessionStore.shared`，`ConnectionStore` 还按 `@State` 注入，**不要随便单例化**）。
- 文件一个 view 一个 file，私有子 view 用 `private struct` 放同 file。
- SwiftUI 修饰符链：每个换行一个 `.modifier()`，不要堆一行。
- `Color` 用 `Color(red:green:blue:)` 直写而不是 Asset Catalog（暂时没有 catalog）。

## 添加新数据库引擎 SOP（详）

1. **Package.swift**：加 driver 库依赖（e.g. `https://github.com/vapor/postgres-nio`）+ 加进 target.dependencies。
2. **Services/`<Engine>`Driver.swift**：
   ```swift
   final class PostgresDriver: DatabaseDriver, @unchecked Sendable {
       static let engine: DatabaseEngine = .postgres
       static let defaultPort: Int = 5432
       static let capabilities: DriverCapabilities = [.ssh, .ssl, .createDatabase, .schemaNamespace]
       static func connect(host:..., ...) async throws -> Self { ... }
       func close() async throws { ... }
       // ... 实现所有 protocol 方法
   }
   ```
3. **Services/DriverRegistry.swift**：
   - `factories` 字典加一行 `.postgres: { try await PostgresDriver.connect(...) }`
   - `defaultPort(for:)` switch 加 case
   - `capabilities(for:)` switch 加 case
4. **完成**。UI 自动认得，无需改动 Form / Workspace 任何 view。

如果新 driver 有 MySQL 没有的概念（PG schema、SQLite 无 user）：
- 用 `DriverCapabilities` 标记
- View 通过 `session.profile?.engine` + capabilities 决定是否显示某 UI block
- **绝不** `if engine == .postgres` 这种代码进 View

## 添加新 L10n 字符串 SOP

```swift
// 1. Services/L10n.swift 的 en 字典加一行：
"workspace.newKey": "New thing",
// 2. 同一个 file zh 字典加一行：
"workspace.newKey": "新东西",
// 3. View 里：
Text(L10n.t("workspace.newKey"))
```

## 添加新 schema 表 / 列 SOP

```swift
// Services/Persistence.swift 末尾追加：
m.registerMigration("v2_new_thing") { db in
    try db.create(table: "thing") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull()
    }
}
```
然后在文件里新建 `struct ThingRecord: Codable, FetchableRecord, PersistableRecord`，table name 指定。

## Backlog / 未来风险点

见 [`BACKLOG.md`](./BACKLOG.md)。新增 TODO 都加在那里，不要写进本文件。

## 编译 / 打开应用

```
./scripts/run.sh
```

## 给 Claude 的元规则

- **改代码前先 `swift build`**，验证当前是干净的。改完再 `swift build` 验证。**不要把构建留给用户**。
- 改 UI 后**用 `./scripts/run.sh` 重新启动**（不要直接 `swift run` 或裸跑 binary —— 钥匙串会狂弹），看进程在没在；用户截图反馈基本快。
- 用户的视觉 review 反应很快，**改一处看一眼**，不要批量改多处再让用户对一堆。
- 用户会反复说 "再小一点 / 再大一点"，**不要硬犟**默认值，按需求改 `App.swift` 的 `defaultSize(width:height:)` + `WindowResizer.defaultSize`。
- 不要往代码里写注释来解释设计 / 历史 / 改动原因（参考 ai-config CLAUDE.md 的全局规则）。注释只解释代码本身的非显然逻辑。
