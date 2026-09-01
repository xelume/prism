# Prism 0.3.4

- 新增 Codex Direct Keyring 支持，可切换官方客户端保存在 macOS 钥匙串 `Codex Auth` 中的认证。
- 根据 `config.toml` 和实际认证位置选择文件或 Direct Keyring；支持 `file`、`keyring`、`auto` 及未显式配置的默认场景。
- 钥匙串读写精确匹配默认 `CODEX_HOME`，写入前比较、写入后复查；未知布局、Secrets 后端或自定义登录策略会安全停止，不覆盖认证。
- 后台额度查询不会主动触发钥匙串授权；需要访问时可通过“授权并重试”由用户明确确认。

已安装 0.3.3 或更早版本的用户可通过应用内更新安装本版，或下载 DMG 将应用拖入 Applications。

仍为临时签名、未经 Apple 公证的发行包；更新包签名用于校验来源，不能代替 Apple 签名或公证。
