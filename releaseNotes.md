# Prism 0.3.5

- 修复新安装用户使用 Codex Direct Keyring 时，因桌面客户端内部认证目录与默认 `~/.codex` 不同而被误报为不支持的问题。
- 仅枚举 `Codex Auth` 的 account 元数据，不读取认证内容；唯一符合官方 `cli|<hash>` 格式的条目可被安全识别。
- 多个 Direct Keyring 候选、未知钥匙串布局、Secrets 后端及钥匙串查询错误仍会明确停止，不修改当前登录。

已安装 0.3.4 或更早版本的用户可通过应用内更新安装本版，或下载 DMG 将应用拖入 Applications。

仍为临时签名、未经 Apple 公证的发行包；更新包签名用于校验来源，不能代替 Apple 签名或公证。
