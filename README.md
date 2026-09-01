# Prism

本机 Mac 菜单栏工具：正常退出官方 ChatGPT → 保存当前最新认证 → 恢复所选账号认证 → 重开官方 ChatGPT。

仅处理默认 `CODEX_HOME` 的 `~/.codex/auth.json` 或 Direct Keyring（`Codex Auth`）认证。**不切换整个环境，不修改设置、插件、工作区或任务文件。** Codex CLI 和 IDE 扩展使用同一认证存储时也会换号。这不是 OpenAI 官方支持的账号切换接口。

## 使用

1. 打开下载的 DMG，将 `Prism.app` 拖入 Applications，推出磁盘映像后从“应用程序”启动。菜单栏出现星烁图标，点击即可展开账号菜单。启动后自动读取已保存账号及当前默认认证，并查询额度；首次使用或重新构建后可能需要点击“授权并重试”允许本工具访问 Prism 备份和 Codex Direct Keyring。后台读取不会主动弹出钥匙串授权框。
2. 选择“保存／更新当前账号”，命名，例如“个人”。工具正常退出 ChatGPT、保存认证后重开。
3. 选择“添加账号”。工具先备份当前认证，再从当前存储移除认证并重开客户端；不会调用服务端退出登录。由你在官方登录流程中选择另一个账号。
4. 登录完成后，选择“保存／更新当前账号”，命名为“工作”。
5. 已保存账号直接显示在菜单中，当前账号以勾选和“当前”标注。点击其他账号，确认“是否切换到「账号名」？”后才执行切换。每次切换自动更新离开账号的最新认证，不用手动反复保存。

切换前结束独立终端／IDE 的 Codex 任务。工具先记录客户端进程树并检查独立进程；发现阻塞时直接提示，不请求桌面客户端退出。通过检查后，再请求官方客户端正常退出（最多等待 25 秒）。主程序退出后，给后台进程最多 10 秒自行清理，再向已确认属于客户端的 Codex 残留发送 `SIGTERM` 并等待 5 秒。仍未退出时，会列出进程并询问是否强制结束；默认选项为“取消切换”。强制结束可能丢失未保存内容或中断任务，只有明确确认后才发送 `SIGKILL`。

如果主程序仍未退出（例如取消了官方退出对话框），不会自动发送信号，而是单独询问是否强制结束。独立终端／IDE 进程和无法确认归属的残留会提示进程名、PID、父进程 PID，不会自动结束。识别到 VS Code 标准扩展目录中的 Codex 进程时，会提示保存任务并完全退出 VS Code；仅关闭扩展面板可能无法停止后台进程。路径识别仅用于提示，不授予进程清理权限。ChatGPT 的 `browser_crashpad_handler` 只处理崩溃报告，不读取共享认证；退出后成为孤立进程时不会阻止切换，也不会被工具结束。退出后仍会复查，所有认证阻塞进程停止前不会替换认证。切换期间不要从终端、IDE 或 Dock 同时启动 ChatGPT / Codex。

如果添加账号时取消登录，从工具选择之前保存的账号即可恢复。登录过期或服务端撤销令牌时仍需正常登录，再更新备份。浏览器可能记住上一个账号，登录时请核对实际选择。

## 所有账号额度与后台刷新

- 菜单每个账号显示名称及两行额度：**5h 剩余百分比和距离重置的小时／分钟数**、**Week 剩余百分比和本机时区的具体重置日期、时间**。当前账号置顶，其他账号保持保存顺序。移除鼠标悬停提示，不显示最后刷新时间；登录失效、查询失败等异常才标注状态。时间已到但没有获得新的额度数据时显示等待重置确认，不自动推断额度恢复。长名称截断显示，切换确认框显示完整名称，VoiceOver 可读取完整名称及额度。当前已登录但尚未保存的账号也显示额度，并标记“未保存账号”；保存后才能在列表中切回它。
- 启动时自动查询；每轮结束后约 5 分钟刷新一次（计时器约 30 秒检查一次，休眠期间不查询）。展开菜单先显示缓存，距离上一轮查询结束满 30 秒才重新查询；首次没有查询记录时立即查询，已有查询尚未完成时复用同一轮请求，仍遵守各账号的限流退避。最多同时查询 3 个账号。结果返回后原位更新额度与状态，展开期间不重排已有账号。菜单不单独显示刷新入口或定时刷新提示，保留 ⌘Q 退出快捷键。
- 使用各账号已有的 access token 和账号请求头，向固定的 `https://chatgpt.com/backend-api/wham/usage` 发起 GET。该地址和字段来自检查过的官方桌面客户端，是**内部接口，不保证长期兼容**。不调用额度重置、购买、登录或退出登录接口。
- 不为了查询临时切换账号，不启动第二个 Codex 进程，也不关闭官方客户端。当前账号优先使用当前认证存储中刚读取的最新认证；其他账号使用已保存备份。查询不会写入 `auth.json`、更新钥匙串或修改官方认证状态。
- **不会自动刷新 access token 或轮换 refresh token。** 后台账号的令牌失效后将提示重新登录并保存；账号服务端撤销登录、权限不足、网络故障或接口变化也可能导致无法查询。401 标记登录失效，403 标记拒绝访问，不能把所有失败都当成额度耗尽。
- 失败只影响对应账号；已有成功数据保留在内存，并明确标注“上次剩余”和失败状态，不以 0% 代替未知值。服务没有返回 5h 或 Week 周期时显示“暂无额度数据”，不会将其他周期或模型专属额度冒充为通用额度。
- 失败默认至少等待 5 分钟再试；429 按 `Retry-After` 在 5–60 分钟范围内退避，手动刷新也遵守退避。重新保存当前已失效账号的新认证后可以立即重试。额度缓存不落盘，退出工具即清除。
- 切换或保存账号时暂停并取消查询，操作结束后重新读取账号和刷新。切换前的迟到结果不能覆盖新一轮状态。锁定钥匙串或认证检查失败时停止该轮查询，并提供查看原因及手动授权重试入口。
- 网络使用无持久缓存、无共享 Cookie／凭据存储的临时会话，拒绝重定向，不记录令牌或原始服务器错误内容；每个请求有超时和响应大小限制。

## 安全与兼容范围

- 备份存于当前用户 macOS 钥匙串，服务名称 `local.chatgptAccountSwitcher`，不写入项目目录，不设置 iCloud 同步。macOS 可能请求钥匙串访问许可。
- 官方当前认证仍采用其已经选择的文件或 Direct Keyring 存储。文件替换使用 `0600` 权限和同目录原子重命名；钥匙串更新精确匹配 service 与 account，并在写入后重新读取校验。其他配置不变。
- 每次替换前保存当前最新认证；备份失败不替换当前存储。启动失败时，仅在相关进程均停止且认证未被其他程序更改的情况下恢复原认证。
- 工具意外退出时，已保存的账号仍在钥匙串中；结束 Codex 进程后重新运行工具，选择原账号恢复。
- 只支持当前检查过的官方 macOS ChatGPT `26.825.51511`、默认目录、文件认证、Codex Direct Keyring 及完整 ChatGPT 令牌格式。Direct Keyring 精确匹配 `Codex Auth` 服务和默认 `CODEX_HOME` 的 `cli|<hash>` 账号；Secrets 后端、其他钥匙串布局、版本更新、未知认证格式、自定义登录策略或不安全文件权限时拒绝操作，绝不自动修改安全策略。
- 进程检查和认证内容比较可以发现普通并发冲突，但无法与不遵守本工具锁的其他客户端形成跨程序事务。切换期间其他程序启动仍存在竞态；工具不会宣称绝对隔离。
- 清理权限来自退出前和等待期间观察到的父子关系，不来自进程名称。内核启动时间（精确到微秒）与可执行文件路径用于校验 PID 是否仍对应原进程；发送信号前再次校验。强制结束仅限确认清单里的实例，确认后出现的新进程不会自动加入强制结束清单。macOS 的检查与发送信号仍是两个系统调用，不能声称绝对消除竞态。
- 某些长期运行的插件宿主无法通过内核接口取得可执行文件路径时，会使用 `ps` 的可执行文件字段辅助识别，不读取命令参数。备用路径只用于分类与提示，不能用于授权发送结束信号。
- 同一次运行中取消切换后，工具保留仍存活进程的已确认归属，方便再次尝试；工具重启前就已经失去父子关系的孤立进程不能可靠追溯，仍需手动处理。不会结束客户端任务启动的普通开发服务器等非 Codex 进程；它们不提供认证隔离保证。
- **保留本地数据并不隔离账号数据。** 云端会话、订阅、权限和第三方插件授权仍由当前账号决定，不保证换号后能使用原账号云端任务。工具不会复制或合并云端数据。
- 从普通 Dock 图标打开官方客户端会使用最后一次替换后的默认认证。第一版不支持自定义 `CODEX_HOME`、其他副本、旧版 ChatGPT Classic 或远程主机。
- 本机构建使用临时签名，未公证；重复构建后系统可能重新请求钥匙串许可。应用只针对当前 Mac 架构构建。
- 应用对外名称为 Prism，团队为 xelume；为兼容已保存的账号，应用标识、钥匙串服务名以及 `Library/Application Support/ChatGPT Account Switcher` 存储路径保持不变。

## Xcode 工程

安装完整 Xcode 26 或更新版本（仅 Command Line Tools 不足以运行 XCTest），打开 `Prism.xcodeproj`，选择共享 Scheme **Prism** 和 **My Mac**：

- **⌘B / Build**：由 Xcode 编译源码、生成图标、组装 `.app` 并临时签名。
- **⌘R / Run**：启动菜单栏应用进行调试；这会按应用正常行为读取当前登录和查询额度。
- **⌘U / Test**：运行独立 XCTest，不启动主应用，不访问真实账号。
- **Product → Archive**：生成 Release 归档，可在 Organizer 查看。

工程包含三个 Target：应用 `Prism`、测试 `PrismTests`，以及仅供测试使用的 C 子进程 `ShutdownFixture`。测试直接编译非 UI 源码，未设置应用宿主；测试子进程由 Xcode 编译并复制到测试 Bundle 中，不依赖当前工作目录。不要为了运行测试给它配置主应用宿主。

`config/app.xcconfig` 是版本和最低系统要求的唯一配置来源：`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`MACOSX_DEPLOYMENT_TARGET`。`info.plist` 使用 Xcode 变量引用这些值，应用标识及可执行文件名保持原样。当前默认仍为 ad-hoc 临时签名，不要求 Apple 开发者账号，不代表已公证。

图标源文件仍为 `assets/logo.svg`。工程的 **Generate SVG icon resources** 构建阶段运行 `scripts/generateIcons.swift`，生成 `.icns` 与菜单栏 PNG；声明输入／输出依赖，生成文件放在 Xcode 派生目录和应用资源目录，不提交 Git。应用的源码编译、资源目录及签名由 Xcode 负责，不再手动组装应用包。

命令行使用与 Xcode 相同的 Scheme（在仓库根目录执行）：

```sh
# 首次构建或依赖变更后，解析已锁定的 Sparkle 依赖
xcodebuild -resolvePackageDependencies -project Prism.xcodeproj -scheme Prism \
  -clonedSourcePackagesDirPath build/SourcePackages -onlyUsePackageVersionsFromResolvedFile

# 编译，不启动应用
xcodebuild -project Prism.xcodeproj -scheme Prism \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  -derivedDataPath build/DerivedData build

# XCTest：测试报告保存在 .xcresult，可用 Xcode 打开
xcodebuild -project Prism.xcodeproj -scheme Prism \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  -derivedDataPath build/DerivedData \
  -resultBundlePath build/TestResults.xcresult test

# 创建供 DMG 分发的 arm64 归档
xcodebuild -project Prism.xcodeproj -scheme Prism \
  -configuration Release -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  -derivedDataPath build/DerivedData \
  -archivePath build/Prism.xcarchive ARCHS=arm64 archive

# 只对已有归档打包，不重复编译或重复创建 DMG
bash scripts/packageRelease.sh v0.3.4
```

再次运行时，为测试报告使用新的 `-resultBundlePath`，或移走之前的报告；Xcode 不覆盖已有 `.xcresult`。DerivedData 和用户个人 Xcode 设置由 Git 忽略。没有新增 XcodeGen 或 Tuist；Sparkle 2.9.6 通过 Swift Package Manager 固定版本和提交号，`Package.resolved` 需提交。首次构建需要联网解析依赖。

归档中的应用位于 `build/Prism.xcarchive/Products/Applications/Prism.app`；最终分发文件位于 `build/release/`，包含 `prism-v0.3.4-macos-arm64.dmg`、`SHA256SUMS.txt` 和发行说明。打包脚本先读取 Xcode 的有效配置，并核对归档中版本、标识、最低系统版本和可执行文件名，拒绝版本不一致的归档。

保留的脚本只有资源生成和分发职责：

| 文件 | 职责 |
| --- | --- |
| `generateIcons.swift` | SVG 生成图标，由 Xcode 构建阶段调用 |
| `createDmg.sh` | 创建、只读挂载验证并卸载 DMG |
| `packageRelease.sh` | 校验版本和归档，生成一次 DMG、校验文件和发行说明 |

`updateFeed.swift` 专门验证签名、版本和发布元数据，并生成可部署的订阅目录；不编译应用。

旧的 `build.sh`、`test.sh` 和 `SELF_TEST` 应用入口已移除。DMG 内包含应用和 `/Applications` 快捷入口；不会自动安装、启动应用或关闭 Gatekeeper。

## 测试范围

原有五组 XCTest 复用已有回归验证：认证存储读写与安全检查、账号切换及回滚、额度解析和刷新、客户端退出流程、原生进程适配器。使用模拟认证、网络响应和虚拟时钟，不请求真实额度或访问真实钥匙串。原生进程验证会枚举进程元数据，仅向测试自己创建的 `codex-shutdown-fixture` 发送结束信号。

新增四项 XCTest 验证更新配置和账号操作／安装互斥。`python3 tests/updateFeedTests.py` 使用临时 Ed25519 密钥验证签名篡改、发布状态、元数据、同版本不可变和禁止降级等边界；不访问钥匙串。

**真实多账号额度、系统钥匙串授权、客户端退出和切换后的身份确认仍需人工验证。** 自动化测试不会启动菜单栏主应用；成功启动客户端不等于服务端接受登录。

## GitHub Actions 与发布

`.github/workflows/ci.yml` 在 PR、推送 `main` 和手动运行时执行脚本／plist 检查、`xcodebuild test`、`xcodebuild archive` 和 DMG 打包。环境固定为 `macos-26`（arm64）。测试结果 `.xcresult` 尽可能在失败时也上传，保留 14 天。

CI 使用只读仓库权限，官方 Actions 固定到提交号，checkout 不持久保存凭据，不使用 `pull_request_target`，不跨运行缓存 Swift 模块。云端不需要安装 ChatGPT 或配置真实账号。GitHub Actions artifact 外层是 ZIP，解压得到 DMG 后打开，将应用拖到 Applications 即可。

发布步骤：

1. 更新 `config/app.xcconfig` 中三段数字版本 `MARKETING_VERSION`（如 `0.3.3`）及递增的 `CURRENT_PROJECT_VERSION`。不要在 `info.plist` 或工作流中重复写版本。
2. 将代码合并到 `main` 并确认 CI 通过。建议把 `Verify macOS arm64` 设置为必需检查，限制 `v*` 标签创建权限。
3. 在待发布提交上创建并推送匹配版本的标签；当前版本示例，仅在准备发布时执行：

   ```sh
   git tag -a v0.3.4 -m 'Release v0.3.4'
   git push origin v0.3.4
   ```

4. `release.yml` 首先通过 Xcode 解析配置并校验标签，再运行 XCTest、归档、生成 DMG 和 SHA-256 校验文件，使用受保护的更新密钥签署 DMG 并生成 `appcast.xml`，验证签名与应用内公钥一致后上传完整附件，再自动公开 Release。上传期间使用临时草稿，避免用户下载到不完整附件，无需人工发布。
5. 打标签前编辑根目录 `releaseNotes.md`；该文件会同时嵌入更新订阅和发行说明。推送标签即表示确认发布，请在此前完成必要的安装包和账号切换验收。仅在 GitHub 编辑 Release 正文不会改变已签包对应的更新说明。已有相同标签的 Release 不会被覆盖；失败重试前先检查旧草稿，正式发布后应使用新版本。

可单独运行 `bash scripts/packageRelease.sh v0.3.4 --check-only`，无需先构建归档。为避免旧附件混入，本地再次打包前需移走已有的 `build/release/`；CI 使用新运行环境。Xcode 普通构建不生成 DMG，分发阶段只生成一次 DMG。

Release 任务仅由标签触发，使用 `contents: write` 和步骤限定的 `GITHUB_TOKEN` 上传附件并自动公开 Release；无需 PAT 或 Apple Secrets，但签名步骤必须配置 `release-signing` Environment 中的 `SPARKLE_PRIVATE_KEY` Secret。PR 和普通 CI 不使用更新私钥。配置推送后才会在 GitHub 上运行，本地通过不能代替云端验证。

**产物仍为临时签名、未经 Apple 公证的测试分发包。** 正式分发需要后续配置 Developer ID Application 证书、Hardened Runtime、公证和 stapling。证书私钥和公证凭据只能放在受保护的 GitHub Environment／Secrets，不能提交到仓库或交给外部 PR。当前未启用 Apple 正式签名、公证或 Intel 发行包。

参考：[GitHub macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

## 应用更新

“关于 Prism…”显示图标、版本、xelume 团队、项目链接及安全说明；关于窗口保留“检查更新…”；菜单仅在发现新版本时显示“更新至…”入口，两处共用一个 Sparkle 更新器。用户同意自动检查后约每天检查一次，也可在关于窗口随时关闭。后台发现更新只修改菜单入口，不抢焦点；用户主动点击后才展示更新说明、下载和安装进度。没有更新或请求失败由 Sparkle 标准窗口提示；网络失败不会误报为最新版本。

不自动下载、不静默安装、不发送账号、令牌或系统分析信息。更新仅替换本工具并重启，不结束官方客户端、不修改认证、钥匙串或任务文件。安装与账号操作互斥，下载期间可以正常使用；一旦请求安装就不再接受新账号操作，已有操作结束后才恢复安装。退出请求也不能打断账号操作。

当前订阅地址为 `https://xelume.github.io/prism/appcast.xml`，DMG 来自公开的 `xelume/prism` GitHub Releases。如果仓库私有，不要把 GitHub Token 打包到应用；应先提供公开的分发仓库或 HTTPS 下载服务。发布前验证这个固定地址可公开访问。默认发布单个最新稳定版本，最低 macOS 和 arm64 限制由 Sparkle 读取；未来提高系统要求时，应扩展为保留旧系统分支的订阅，不能直接删除旧系统最后可用版本。

首次启用（一次性）：

1. 解析依赖后，在可信本机执行以下命令，生成专用于本项目的 Sparkle 密钥。已有同名密钥会复用，不会覆盖：

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account xelume-prism
   ```

2. 将输出的**公钥**写入 `config/app.xcconfig` 的 `SPARKLE_PUBLIC_ED_KEY` 并提交；私钥保留在本机钥匙串并安全备份。它不是 Apple 开发者证书，也不能消除 Gatekeeper 提示。不要每次构建生成新密钥。空公钥时本地应用仍可使用，但会明确显示尚未配置更新，正式签名打包会失败。
3. 在 GitHub 建立 `release-signing` Environment，限制 `v*` 标签，不配置 Required reviewers，以便标签推送后自动发布。通过 Sparkle 的 `generate_keys --account xelume-prism -x <仓库外的安全临时文件>` 导出私钥，把文件内容配置为该 Environment 的 `SPARKLE_PRIVATE_KEY` Secret，随后安全移除临时导出文件。不要把私钥放进仓库、命令参数、聊天或日志。
4. 在仓库 **Settings → Pages → Build and deployment → Source** 选择 **GitHub Actions**，为 `github-pages` Environment 配置可信发布权限。此工作流部署整个 Pages 站点；如果仓库已有站点，需要先合并部署内容，避免覆盖。这里尚未自动修改 GitHub 设置。
5. 创建并验收首个包含公钥的版本。已有旧版用户需要手动安装一次，之后才能使用应用内更新。

本地正式更新包使用和普通 DMG 相同的归档，额外指定签名模式：

```sh
bash scripts/packageRelease.sh v0.3.4 --signed
```

本地签名只读取 `xelume-prism` 对应的更新密钥；CI 只在签名步骤通过标准输入传递 Secret。Sparkle 官方 `generate_appcast` 生成元数据与 EdDSA 签名，`updateFeed.swift` 再以应用内公钥独立验证 DMG、版本、最低系统和固定下载地址。发布说明来自根目录 `releaseNotes.md`，第一版不生成增量包。

`release.yml` 在完整上传 DMG、校验文件、`appcast.xml` 后自动公开稳定版，再通过 `workflow_call` 调用 `updateFeed.yml`，不依赖 `GITHUB_TOKEN` 产生的发布事件。订阅流程读取当前最新公开稳定 Release，下载并验证附件，拒绝草稿／预发布、错误签名和更低构建号，只把订阅文件部署到 Pages。公开订阅始终最后更新。支持手动重跑部署；相同构建号仅允许原样重发，变更说明或更新包有修改时发布新版本和更高构建号。

维护者推送每个发布标签前应在隔离测试安装中验证：旧版检测新版、取消／稍后更新、下载失败、签名不匹配、最低系统不兼容、只读 DMG 提示移至 Applications、账号操作期间点击安装、更新后重启。自动化测试不替代实际安装验收，不应为此操作真实账号。应用从 DMG 直接运行时不能原地替换，请先拖到 Applications。

参考：[Sparkle 接入与签名](https://sparkle-project.org/documentation/)、[发布更新](https://sparkle-project.org/documentation/publishing/)、[GitHub Pages 自定义工作流](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。

## 本地清理

退出工具后可删除应用。卸载工具不会改变最后一次选中的当前认证。若不再需要账号备份，可使用系统“钥匙串访问”删除 `local.chatgptAccountSwitcher` 对应项；删除备份后不能通过工具恢复这些账号，须正常登录。

参考：[OpenAI 认证与登录缓存说明](https://learn.chatgpt.com/docs/auth#login-caching)。实现细节和当前版本代码的兼容性判断不代表官方承诺。
