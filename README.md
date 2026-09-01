# Prism

Prism 是一款 macOS 菜单栏工具，用于保存、添加和切换 ChatGPT / Codex 账号。保存或添加账号不会中断当前任务；只有切换默认认证时，才需要结束相关 Codex 任务，并在桌面模式下重新打开 ChatGPT。

Prism 只处理默认的 `~/.codex/auth.json`，不会切换整个 Codex 环境，也不会修改设置、插件、工作区或任务文件。Codex CLI 和 IDE 扩展如果使用同一认证文件，也会随之切换账号。

> Prism 是独立工具，并非 OpenAI 官方支持的账号切换接口。

## 普通用户指南

### 系统要求

- Apple Silicon Mac，macOS 26.0 或更高版本。
- 通过官方签名验证的 macOS ChatGPT，或独立安装且文件权限安全的官方 Codex CLI。
- 使用默认 `~/.codex/auth.json` 和 ChatGPT 账号登录方式。

Prism 目前使用临时签名，未经 Apple 公证，仅针对当前 Mac 架构构建。

### 安装和启动

1. 打开下载的 DMG，将 `Prism.app` 拖入 Applications。
2. 推出磁盘映像，从“应用程序”启动 Prism，不要直接在 DMG 中运行。
3. 菜单栏出现星烁图标后，点击图标打开账号菜单。

Prism 启动后会读取已保存账号和当前默认认证，并查询各账号额度。首次使用或重新构建后，macOS 可能要求允许访问账号备份钥匙串；如果账号列表加载失败，点击“授权并重试…”。后台刷新不会主动弹出钥匙串授权框。

### 保存当前账号

1. 先在 ChatGPT 或 Codex 中登录要保存的账号。
2. 打开 Prism 菜单，选择“保存当前账号…”。
3. Prism 将认证备份到当前用户的 macOS 钥匙串。

账号默认使用登录邮箱命名；认证中没有可用邮箱时使用编号名称。保存操作不会退出 ChatGPT，也不会中断当前任务。

### 添加另一个账号

1. 选择“添加账号…”，确认继续登录。
2. 在浏览器中完成另一个 ChatGPT 账号的登录。
3. 登录成功后，Prism 会校验并保存账号，然后删除临时登录目录。

登录使用 ChatGPT.app 内置或独立安装的官方 Codex CLI，并运行在隔离的临时 `CODEX_HOME` 中，因此当前默认认证和运行中的任务不会改变。等待窗口可以随时取消，3 分钟未完成会自动超时。

浏览器可能记住上一次登录的账号，请确认实际选择的账号。取消、超时或认证格式不受支持时，Prism 不会修改当前登录或已有备份。

### 切换账号

已保存账号显示在菜单顶部，当前账号置顶，并带有勾选和“当前”标记。

1. 保存正在处理的内容，结束独立终端和 IDE 中的 Codex 任务。
2. 点击目标账号。
3. 在“是否切换到「账号名」？”对话框中确认。

如果安装了受支持的 ChatGPT.app，Prism 会请求客户端正常退出，替换默认认证后重新打开 ChatGPT；仅使用 CLI 时不会启动桌面客户端。每次切换前，Prism 会先保存离开账号的最新认证，无需手动反复保存。

如果后台账号显示“需要重新登录”，点击该账号并登录同一个账号即可更新备份。误登其他账号时不会覆盖原备份。

### 管理已保存账号

选择“管理账号…”可以重命名账号或删除账号备份：

- 重命名只改变 Prism 中显示的名称，不修改实际登录账号；自定义名称不会在重新保存或重新登录时被邮箱覆盖。
- 删除只移除 Prism 钥匙串中的备份，不删除默认认证，也不会退出当前登录。
- 删除后台账号后不能再直接切回，需要重新添加或登录。
- 删除当前账号的备份后，该账号会显示为尚未保存；重新选择“保存当前账号…”即可再次保存。

#### 为什么有时不能切换

切换账号必须确保没有进程继续使用默认认证：

- Prism 先检查独立终端、IDE 和桌面客户端的相关进程。发现独立进程时会直接提示，不会自动结束它们。
- 识别到 VS Code 标准扩展目录中的 Codex 进程时，请保存任务并完全退出 VS Code；只关闭扩展面板可能无法停止后台进程。
- 检查通过后，Prism 请求官方客户端正常退出，最多等待 25 秒；主程序退出后再给后台进程 10 秒自行清理。
- 对确认属于客户端的残留进程，Prism 发送 `SIGTERM` 并等待 5 秒。仍未退出时会列出进程并询问是否强制结束，默认选项是“取消切换”。
- 如果主程序仍未退出，例如取消了官方退出对话框，Prism 不会直接发送信号，而会单独询问是否强制结束。

强制结束可能丢失未保存内容或中断任务，只有明确确认后 Prism 才会发送 `SIGKILL`。独立终端、IDE 进程和无法确认归属的残留不会被自动结束。

ChatGPT 的 `browser_crashpad_handler` 只负责崩溃报告；退出后成为孤立进程时，它不会阻止切换，也不会被 Prism 结束。切换期间不要同时从终端、IDE 或 Dock 启动 ChatGPT / Codex。

### 查看账号额度

每个账号显示两行额度：

- **5 小时**：剩余百分比和距离重置的小时／分钟数。
- **每周**：剩余百分比和按本机时区显示的重置日期、时间。

当前已登录但尚未保存的账号也会显示额度，并标为“当前账号（尚未保存）”；必须保存后才能从其他账号切回。VoiceOver 可以读取完整账号名称和额度。

Prism 启动时查询额度，此后每轮结束约 5 分钟刷新一次。展开菜单时先显示缓存；如果上一轮结束已满 30 秒，则触发新一轮查询。最多同时查询 3 个账号。额度缓存只保存在内存中，退出 Prism 后清除。

时间已经到达但服务端尚未返回新数据时，界面显示“等待重置确认”，不会自行推断额度已经恢复。请求失败时保留此前成功数据并显示“上次剩余”，不会用 0% 代替未知值：

- “需要重新登录”：账号令牌失效，点击该后台账号重新登录。
- “无法查看额度”：服务拒绝访问。
- “稍后再试”：服务触发限流。
- “更新失败”或“暂无额度信息”：网络、接口或返回数据暂不可用。

普通失败至少等待 5 分钟再试；服务返回 429 时按 `Retry-After` 在 5–60 分钟内退避。手动触发也遵守退避时间。

### 额度查询的边界

Prism 使用各账号现有的 access token 和账号请求头，向 `https://chatgpt.com/backend-api/wham/usage` 发起 GET。该地址和字段来自已检查的官方桌面客户端，是内部接口，不保证长期兼容。

额度查询不会：

- 临时切换账号、启动第二个 Codex 进程或关闭官方客户端；
- 写入 `auth.json`、更新钥匙串或改变官方认证状态；
- 自动刷新 access token 或轮换 refresh token；
- 调用额度重置、购买、登录或退出登录接口；
- 使用共享 Cookie、持久网络缓存或凭据存储。

请求拒绝重定向，不记录令牌或原始服务器错误内容，并限制超时和响应大小。官方登录组件不为后台账号常驻刷新令牌；当前账号通常由正在使用它的 Codex 续期，后台账号失效后需要手动重新登录。

### 账号与数据安全

- 账号备份保存在当前用户的 macOS 钥匙串，服务名称为 `local.chatgptAccountSwitcher`，仅在本机解锁后可用，不设置 iCloud 同步。
- Prism 不读取账号密码。认证文件替换使用 `0600` 权限和同目录原子重命名。
- 每次替换前先保存当前最新认证；备份失败时不替换文件。
- 启动新账号失败时，只有在相关进程均已停止且认证未被其他程序更改的情况下，Prism 才会恢复原认证。
- 进程清理权限来自退出前和等待期间观察到的父子关系，不来自进程名称。发送信号前还会校验 PID、启动时间和可执行文件路径。
- Prism 不会结束客户端任务启动的普通开发服务器等非 Codex 进程。

进程检查和文件比较可以发现普通并发冲突，但无法与不遵守 Prism 锁的其他客户端形成跨程序事务。检查与发送信号也是两个独立系统调用，因此切换期间仍不要启动其他相关程序。

**保留本地数据不等于隔离账号数据。** 本地设置和任务不会因为切换而删除，但云端会话、订阅、权限和第三方插件授权由当前账号决定。Prism 不复制或合并云端数据。

### 兼容范围

Prism 会验证 ChatGPT.app 的 bundle ID 和官方 Apple 代码签名，不依赖某个精确的客户端版本号。添加账号时还会检查内置 Codex 的文件归属、写权限和可执行权限。Prism 也会从 `CODEX_CLI_PATH`、当前 `PATH` 以及常见 Homebrew、npm、nvm、Volta、asdf、mise 路径查找独立 Codex CLI，不自动下载可执行文件。

以下情况不受支持，Prism 会拒绝操作而不会自动修改安全策略：

- 自定义 `CODEX_HOME`、其他应用副本、旧版 ChatGPT Classic 或远程主机；
- 非默认目录、非文件认证或不完整的 ChatGPT 令牌格式；
- 显式使用 `keyring`、`auto`、`ephemeral`、Secrets、未知认证格式或自定义登录策略；
- 不安全的目录或文件权限。

历史 `Codex Auth` 钥匙串条目会被忽略且不会被修改。从 Dock 或终端正常启动客户端时，会继续使用最后一次切换后的默认认证。

### 更新 Prism

“关于 Prism…”窗口提供“检查更新…”和“每天自动检查更新”选项。后台发现新版本时，只在菜单显示“更新至…”入口，不抢占焦点；点击后才显示更新说明、下载和安装进度。

Prism 不会自动下载或静默安装，也不会发送账号、令牌或系统分析信息。更新只替换并重启 Prism，不会结束官方客户端，也不会修改认证、钥匙串或任务文件。安装与账号操作互斥：账号操作完成后才能安装，退出请求也不会打断进行中的账号操作。

当前更新订阅地址为 `https://xelume.github.io/prism/appcast.xml`，安装包来自公开的 [xelume/prism GitHub Releases](https://github.com/xelume/prism/releases)。从 DMG 直接运行时不能原地更新，请先将应用拖入 Applications。

### 卸载和清理

退出 Prism 后删除应用即可。卸载不会改变最后一次选中的默认认证。

如需同时删除账号备份，请在系统“钥匙串访问”中删除服务名为 `local.chatgptAccountSwitcher` 的项目。删除后不能再通过 Prism 恢复这些账号，需要重新正常登录。

## 开发者指南

### 开发环境和工程结构

安装完整 Xcode 26 或更新版本；仅安装 Command Line Tools 无法运行 XCTest。打开 `Prism.xcodeproj`，选择共享 Scheme **Prism** 和 **My Mac**：

- **⌘B / Build**：编译源码、生成图标、组装 `.app` 并临时签名。
- **⌘R / Run**：启动菜单栏应用调试；会按正常行为读取当前登录并查询额度。
- **⌘U / Test**：运行独立 XCTest，不启动主应用，也不访问真实账号。
- **Product → Archive**：生成 Release 归档。

工程有三个 Target：应用 `Prism`、测试 `PrismTests` 和测试专用 C 子进程 `ShutdownFixture`。测试直接编译非 UI 源码，不设置应用宿主；测试子进程由 Xcode 编译并复制到测试 Bundle，不依赖当前工作目录。

`config/app.xcconfig` 是版本和最低系统要求的唯一配置来源，包括 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION` 和 `MACOSX_DEPLOYMENT_TARGET`。

`info.plist` 通过 Xcode 变量引用这些值。应用标识、钥匙串服务名和 `Library/Application Support/ChatGPT Account Switcher` 路径为兼容已有账号而保持不变。

### 资源和依赖

应用图标源文件是 `assets/logo.svg`，18／36 px 菜单栏模板图标使用 `assets/menuLogo.svg`。Xcode 的 **Generate SVG icon resources** 构建阶段运行 `scripts/generateIcons.swift`，输出 `.icns` 和菜单栏 PNG 到派生目录及应用资源目录，不提交生成文件。

Sparkle 2.9.6 通过 Swift Package Manager 固定版本和提交号，`Package.resolved` 需要提交。首次构建需要联网解析依赖。项目未使用 XcodeGen 或 Tuist。

### 命令行构建和测试

以下命令均在仓库根目录执行：

```sh
# 首次构建或依赖变更后，解析已锁定的 Sparkle 依赖
xcodebuild -resolvePackageDependencies -project Prism.xcodeproj -scheme Prism \
  -clonedSourcePackagesDirPath build/SourcePackages -onlyUsePackageVersionsFromResolvedFile

# 编译，不启动应用
xcodebuild -project Prism.xcodeproj -scheme Prism \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  -derivedDataPath build/DerivedData build

# XCTest；每次使用新的 resultBundlePath，Xcode 不覆盖已有 xcresult
xcodebuild -project Prism.xcodeproj -scheme Prism \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  -derivedDataPath build/DerivedData \
  -resultBundlePath build/TestResults.xcresult test

# 创建 arm64 Release 归档
xcodebuild -project Prism.xcodeproj -scheme Prism \
  -configuration Release -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution \
  -derivedDataPath build/DerivedData \
  -archivePath build/Prism.xcarchive ARCHS=arm64 archive

# 只打包已有归档，不重复编译
bash scripts/packageRelease.sh vX.Y.Z
```

归档位于 `build/Prism.xcarchive/Products/Applications/Prism.app`。最终文件位于 `build/release/`，包含 `prism-vX.Y.Z-macos-arm64.dmg`、`SHA256SUMS.txt` 和发行说明。

保留脚本的职责如下：

| 文件 | 职责 |
| --- | --- |
| `generateIcons.swift` | 从 SVG 生成应用和菜单栏图标，由 Xcode 构建阶段调用 |
| `createDmg.sh` | 创建、只读挂载验证并卸载 DMG |
| `packageRelease.sh` | 校验版本和归档，生成 DMG、校验文件和发行说明 |
| `updateFeed.swift` | 验证签名、版本和发布元数据，生成可部署的更新订阅目录 |

旧的 `build.sh`、`test.sh` 和 `SELF_TEST` 应用入口已移除。Xcode 普通构建不生成 DMG。

### 测试范围

XCTest 覆盖：

- 认证文件读写、安全检查、账号切换和失败回滚；
- 额度解析、刷新、退避和异常状态；
- 客户端退出、残留进程确认及原生进程适配器；
- 更新配置、账号操作与安装互斥。

测试使用模拟认证、网络响应和虚拟时钟，不请求真实额度。原生进程测试只向测试创建的 `codex-shutdown-fixture` 发送信号。

更新订阅边界另由下列命令验证，使用临时 Ed25519 密钥，不访问钥匙串：

```sh
python3 tests/updateFeedTests.py
```

真实多账号额度、系统钥匙串授权、客户端退出、切换后的身份确认和实际更新安装仍需人工验证。自动化测试不会启动菜单栏主应用。

### CI

`.github/workflows/ci.yml` 在 PR、推送 `main` 和手动运行时执行：

1. 解析锁定的 Swift 包；
2. 检查脚本和 plist；
3. 运行更新订阅边界测试和 XCTest；
4. 创建 arm64 归档并打包 DMG。

CI 固定使用 `macos-26` arm64，仓库权限只读。测试结果尽可能在失败时上传并保留 14 天。云端不需要安装 ChatGPT 或配置真实账号。

### 发布流程

1. 更新 `config/app.xcconfig` 中的三段数字版本 `MARKETING_VERSION`，并递增 `CURRENT_PROJECT_VERSION`。不要在 `info.plist` 或工作流中重复版本。
2. 编辑根目录 `releaseNotes.md`，合并到 `main` 并确认 CI 通过。
3. 在待发布提交创建并推送与版本完全匹配的标签：

   ```sh
   git tag -a vX.Y.Z -m 'Release vX.Y.Z'
   git push origin vX.Y.Z
   ```

4. `release.yml` 校验标签和配置，运行测试、归档及签名打包，上传完整附件后公开 Release。
5. 发布任务通过 `workflow_call` 调用 `updateFeed.yml`；它读取最新公开稳定 Release，验证附件和签名、防止订阅降级，然后部署到 GitHub Pages。

推送标签即表示确认发布。已有同标签 Release 不会被覆盖；正式发布后需要修改内容时，应发布更高版本和构建号。

可在不构建归档的情况下单独检查版本：

```sh
bash scripts/packageRelease.sh vX.Y.Z --check-only
```

本地再次打包前，应移走已有的 `build/release/`，避免旧附件混入。Release 使用 `contents: write` 上传附件；PR 和普通 CI 不接触更新私钥。

### Sparkle 更新签名和订阅

当前订阅地址为 `https://xelume.github.io/prism/appcast.xml`，DMG 来自公开的 `xelume/prism` GitHub Releases。仓库如果改为私有，不要把 GitHub Token 打包进应用，应先提供公开分发仓库或 HTTPS 下载服务。

首次启用更新签名时：

1. 解析依赖后，在可信本机生成或复用项目专用 Sparkle 密钥：

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account xelume-prism
   ```

2. 将公钥写入 `config/app.xcconfig` 的 `SPARKLE_PUBLIC_ED_KEY` 并提交。私钥只保存在钥匙串并安全备份，不要每次构建重新生成。
3. 使用 `generate_keys --account xelume-prism -x <仓库外安全临时文件>` 导出私钥，将内容配置为 GitHub `release-signing` Environment 的 `SPARKLE_PRIVATE_KEY` Secret，然后安全删除临时文件。
4. 在 GitHub Pages 设置中选择 **GitHub Actions**，并为 `github-pages` Environment 配置可信发布权限。
5. 创建并验收第一个包含公钥的版本。旧版用户需要手动安装一次，之后才能使用应用内更新。

本地生成带 Sparkle 签名的更新包：

```sh
bash scripts/packageRelease.sh vX.Y.Z --signed
```

Sparkle 的 `generate_appcast` 生成元数据和 EdDSA 签名，`updateFeed.swift` 再使用应用内公钥独立验证 DMG、版本、最低系统和固定下载地址。第一版不生成增量包。

发布前应在隔离测试安装中人工验证：旧版检测新版、取消或稍后更新、下载失败、签名不匹配、最低系统不兼容、只读 DMG 提示、账号操作期间安装，以及更新后的重启。

当前产物仍是临时签名且未经 Apple 公证。正式分发需要配置 Developer ID Application、Hardened Runtime、公证和 stapling；证书私钥与公证凭据只能放在受保护的 GitHub Environment / Secrets 中。

## 参考资料

- [项目主页](https://github.com/xelume/prism)
- [OpenAI 认证与登录缓存说明](https://learn.chatgpt.com/docs/auth#login-caching)
- [Sparkle 接入与签名](https://sparkle-project.org/documentation/)
- [Sparkle 发布更新](https://sparkle-project.org/documentation/publishing/)
- [GitHub Pages 自定义工作流](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-for-github-pages-sites)
- [GitHub macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

实现细节和当前版本代码的兼容性判断不代表 OpenAI 官方承诺。
