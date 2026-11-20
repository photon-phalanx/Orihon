# Orihon（折本）

为折叠双屏优化的原生 iOS 漫画阅读器：展开就是一本书，两块屏幕合成一个跨页，书脊落在铰链上。

Orihon 是开源漫画阅读器 **[Mihon](https://github.com/mihonapp/mihon)** 的**非官方** iOS / macOS 移植（原生 Swift + SwiftUI），与 Mihon 项目没有关联，也未获其认可。功能包括书架与分类、智能更新、阅读历史、多源浏览与跨源迁移、本地漫画（文件夹 / ZIP / CBZ / EPUB）、自建 Komga 服务器（含阅读进度同步）、下载、5 种阅读模式，以及 `.tachibk` 备份的导入与导出。

## 双屏优化

- **展开态布局**：左侧导航栏与列表，右侧实时详情，中间为铰链留出空隙。
- **跨页阅读**：自动把两页拼成一个跨页，支持从右到左 / 从左到右，封面可单独成页让后面的跨页对齐。
- **翻页**：默认平移翻页；也可以选仿真卷页（测试中），像翻纸书一样翻过书脊。
- **章节衔接**：读到章末时在后台预载下一话，翻过章节卡片直接就是下一话的第一个跨页，不黑屏、不转圈。

## iPhone 上添加图源

在「浏览 → 图源」选择站点。拷贝漫画沿用插件的 18+ 标记，需要先在图源筛选中打开「显示 18+ 图源与插件」。拷贝漫画、包子漫画、GoDa 漫画和漫画人使用 Swift 解析站点的目录和书页。vomic 的动态阅读页使用系统 WebKit。在作品详情的「⋯ → 打开源站」或阅读器提示登录时的「打开源站」进入 vomic。登录后点「完成」，阅读器会使用同一登录状态重新载入本章。

哔咔漫画也使用 18+ 开关。进入「浏览 → 图源 → 哔咔漫画」，点「登录哔咔账号」，使用原生表单登录后点「完成」。右上角的「哔咔账号」可查看账号状态或退出后切换账号。升级自网页登录版时需重新登录一次；已有书库、章节、阅读进度与下载保持兼容。

哔咔通过正式 iOS API `https://api.tipatipa.xyz` 获取百合花园、最近更新、搜索、多选分类、热门标签、漫画详情、完整章节和图片分页。登录令牌在 iOS 钥匙串保存，密码不保存；账号失效时提示重新登录。阅读与下载均使用原生网络请求，不需要隐藏网页或前台窗口。首页缓存按账号隔离，阅读器优先加载当前阅读位置所在批次，再补齐全章。

开发核验：`swift test --filter MihonBika` 运行离线协议与兼容测试。设置 `BIKA_TEST_ACCOUNT`、`BIKA_TEST_PASSWORD` 后，`swift test --filter MihonBikaAPITests/testLiveIOSAPI` 可运行正式服务验证；可选 `BIKA_TEST_COMIC_ID` 指定超过 80 页的分页样本。不要将真实账号或令牌写入测试文件。协议以 2026-11-20 的《接口请求签名说明》《业务接口与参数参考》为准；另经实测，服务端要求兼容 iOS 客户端的 User-Agent，普通 URLSession 默认值会返回 401/1005。

「动漫之家（再漫画）」保留 Android 动漫之家插件的图源编号、作品地址和章节编号，使用再漫画的目录和书页。恢复 Mihon 备份后，两站编号一致且再漫画仍提供的章节可以接着读。原「再漫画」图源仍使用自己的书架标识。[旧插件下架记录](https://github.com/keiyoushi/extensions-source/pull/10248) · [再漫画来源说明](https://github.com/keiyoushi/extensions-source/issues/5015)

附件中还有两个源暂时无法验证阅读。嗨皮漫画的旧站已由插件维护者标为停用。Comick 的新版目录仍可查询章节，但在 2026-11-18 核验时，官方示例和《BLUELOCK》的新旧章节都返回了空的图片列表。[嗨皮漫画下架记录](https://github.com/keiyoushi/extensions-source/pull/18625) · [Comick 书页接口](https://api.comick.dev/docs/#tag/chapter/GET/chapter/%7Bhid%7D/get_images)

对于提供普通 HTML 列表、章节链接和图片的站点，选择「浏览 → 图源 → ＋ → 从文件导入 JSON 图源」。

可以先把[《小辣椒与萝卜头》中文图源文件](./Examples/Sources/peppercarrot-zh.json)保存到 iPhone 的「文件」再导入。规则直接读取 David Revoy 的[官方中文目录](https://www.peppercarrot.com/cn/webcomics/peppercarrot.html)。像这样的单页作品目录可以省略 `search`，Orihon 会按书名搜索。站点没有更新列表时可省略 `latest`。

为其他网站编写图源时，将下面模板中的域名、路径及 CSS 选择器替换成该站的实际值并保存为 UTF-8 的 `.json` 文件。

```json
{
  "version": 1,
  "name": "我的漫画站",
  "lang": "zh",
  "baseUrl": "https://comics.example.org",
  "popular": "/popular?page={page}",
  "latest": "/updates?page={page}",
  "search": "/search?q={query}&page={page}",
  "cards": ".series-card",
  "cardTitle": ".series-title",
  "title": "h1",
  "chapters": ".chapter-list a[href]",
  "oldestFirst": true,
  "images": ".reader img",
  "next": "a[rel=next]"
}
```

`cards` 选中的每个元素应包含作品链接，可以就是链接本身。封面从卡片中的首个 `img` 或 `amp-img` 读取。章节名默认取链接文字，嵌套标题可指定 `chapterTitle`。源站按最早章节在前排列时使用 `oldestFirst`。书页图片依次读取 `data-src`、`data-original`、`src`。单页列表可省略路径里的 `{page}` 和 `next`。搜索词会自动编码。相同站址的规则再次导入会更新解析方式并保留书架关联。规则文件可分享给其他用户。

JSON 规则在手机上由内置解析器读取。依赖专用 API、登录流程或客户端脚本的站点可以实现 `LiveSourceEngine`，随 App 更新分发。Android 插件作者提供的 APK 可作为移植参考。

## 架构概览

1. **`Sources/MihonDomain` (核心领域层)**
   - [`DomainModels.swift`](./Sources/MihonDomain/Models/DomainModels.swift)：包含 `Manga`、`Chapter`、`MangaCategory`、`Track`、`HistoryEntry`、`ExtensionModel`、`DownloadItem`、`MihonBackupPayload` 等完整领域实体。
   - [`SourceAPI.swift`](./Sources/MihonDomain/SourceAPI/SourceAPI.swift)：1:1 对齐 Mihon `source-api` 的 `Source`、`CatalogueSource`、`HttpSource`、`ParsedHttpSource`、`SManga`、`SChapter`、`Page` 与 `SourceFilter`。
   - [`ChapterRecognitionAndFetchInterval.swift`](./Sources/MihonDomain/Utilities/ChapterRecognitionAndFetchInterval.swift)：1:1 移植 `ChapterRecognition.kt` 章节号识别算法与 `FetchInterval.kt` 智能更新周期计算器。

2. **`Sources/MihonData` (数据、网络与图像处理层)**
   - [`PerformanceAndNetworkEngine.swift`](./Sources/MihonData/PerformanceAndNetworkEngine.swift)：令牌桶限流 (`MihonRateLimitInterceptor`)、Cloudflare 检测、通过 `CGImageSource` 进行子采样解码、像素级白边/黑边裁切 (`crop_borders`)、超长条漫分片 (`splitTallWebtoonImage`)、双层内存/磁盘缓存 (`MihonTwoTierImageCache`) 与滑动窗口预加载器 (`MihonReaderPagePreloader`)。
   - [`MihonRepositoryStore.swift`](./Sources/MihonData/MihonRepositoryStore.swift)：统一管理书架、分类、章节筛选与排序、更新流、阅读历史、下载队列、多源迁移、Tracker 同步以及备份恢复。

3. **`Sources/MihonPresentation` (原生 SwiftUI Material 3 视图层)**
   - [`MihonRootView.swift`](./Sources/MihonPresentation/Root/MihonRootView.swift)：自适应折叠态底栏导航与 iPhone Duo 展开态双屏主从分栏 (`NavigationRail` + 铰链安全区 + 实时详情面板)。
   - [`LibraryScreen.swift`](./Sources/MihonPresentation/Library/LibraryScreen.swift)：分类标签栏、三种网格/列表布局、徽章系统、三合一底部抽屉（筛选/排序/显示）及批量操作栏。
   - [`UpdatesScreen.swift`](./Sources/MihonPresentation/Updates/UpdatesScreen.swift) & [`HistoryScreen.swift`](./Sources/MihonPresentation/History/HistoryScreen.swift)：按日期分组的更新流与阅读历史记录。
   - [`BrowseScreen.swift`](./Sources/MihonPresentation/Browse/BrowseScreen.swift)：图源浏览、扩展管理与跨源迁移。
   - [`MangaDetailScreen.swift`](./Sources/MihonPresentation/MangaDetail/MangaDetailScreen.swift)：高斯模糊背景顶栏、四宫格操作栏、可折叠简介、流式标签、章节列表与悬浮续读按钮。
   - [`MangaReaderScreen.swift`](./Sources/MihonPresentation/Reader/MangaReaderScreen.swift)：支持日式从右至左、从左至右、垂直翻页、条漫长图 (Webtoon)、连续垂直及 **iPhone Duo 双页书本跨页模式**。
   - [`MoreAndSettingsScreen.swift`](./Sources/MihonPresentation/More/MoreAndSettingsScreen.swift)：无痕模式、仅限已下载、下载队列、分类管理、阅读统计、备份与恢复、全局设置。

## 构建与测试

```bash
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache swift build \
  --disable-sandbox \
  --package-path . \
  -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache
```

## 许可

本项目以 [Apache License 2.0](./LICENSE) 发布。它移植自 [Mihon](https://github.com/mihonapp/mihon)（The Mihon Open Source Project，Apache License 2.0）。
