# 更新日志

本文件根据 `git log` 整理，按日期倒序记录项目更新。每条记录末尾的短哈希可以用 `git show <hash>` 查看对应提交详情。

## 2026-05-22

### 9f72f8e - revert: restore 2dc7ca1 version
- 将项目实际文件内容恢复到 `2dc7ca1` 版本。
- 删除今天新增但不属于 `2dc7ca1` 内容的 `CHANGELOG.md`。
- 当前脚本状态以 `2dc7ca1` 为准。

### e612f5e - docs: add changelog from git history
- 新增 `CHANGELOG.md`，按 `git log` 整理历史更新记录。
- 该提交随后被 `9f72f8e` 回滚，当前再次单独加回更新日志文件。

### 40945e2 - fix: harden vless reality deployment
- 尝试加固 VLESS + Reality + XTLS Vision 部署稳定性。
- 包含默认 SNI、`jq` 依赖、内核更新逻辑、sniff 和 `domain_strategy` 等调整。
- 该提交已被 `9f72f8e` 回滚，当前脚本不包含这次改动。

### 5523e00 - revert: restore may 19 shortcut version
- 回滚并恢复到 2026-05-19 带全局快捷命令 `sb` 的版本。

### bc6ab7b - revert: restore 10-36 morning version
- 回滚并恢复到当天上午 10:36 左右的脚本版本。

## 2026-05-21

### dac3300 - revert: restore morning script version
- 回滚并恢复到上午版本脚本。

### cc48f9c - revert: restore afternoon script version
- 回滚并恢复到下午版本脚本。

### 0936970 - revert: restore clean deployment script
- 回滚并恢复到较干净的部署脚本版本。

### b51fb81 - fix: keep port stable for 5g repair
- 修复 5G 修复相关流程中端口保持稳定的问题。

### e5bb91c - fix: harden vless reality deploy stability
- 加强 VLESS-Reality 部署稳定性。

### 474faeb - fix: 修复 5G 环境下 VLESS-Reality 连接不稳定的多个问题
- 服务端 inbound 加入流量嗅探相关配置。
- 移除可能影响 5G NAT 场景的 `tcp_fast_open`。
- short_id 去掉多余空字符串。
- 移除 `max_time_difference`，使用 sing-box 默认值。
- direct outbound 加入 `domain_strategy`。
- 客户端 TLS 指纹从 `random` 统一改为 `chrome`。

### 2dc7ca1 - fix: 移除 Clash 中错误的 udp:true 及 sing-box 客户端的 auto_detect_interface，并加强服务端稳定性
- 移除 Clash/Mihomo 配置中错误的 `udp: true`。
- 移除 sing-box 客户端配置中的 `auto_detect_interface`。
- 加强服务端稳定性配置。
- 当前脚本实际内容已恢复到此版本。

### 9678c52 - feat: Clash/Mihomo 和 sing-box 客户端配置加入大陆分流和 DNS 防污染
- 为 Clash/Mihomo 配置加入大陆分流规则。
- 为 sing-box 客户端配置加入大陆分流和 DNS 防污染相关配置。

### b8b6575 - fix: 日志函数写入前判断目录是否存在，避免卸载后残留警告
- 日志写入前检查目录是否存在。
- 避免卸载后日志目录不存在导致残留警告。

### 9bfee8c - fix: 卸载时清理 BBR sysctl 残留配置，以及 iptables 规则删除后持久化保存
- 卸载时清理脚本写入的 BBR sysctl 配置。
- 删除 iptables 规则后尝试持久化保存。

### 894a103 - fix: iptables 规则改用 -I 插入到 REJECT 之前，修复 Oracle Cloud 等默认 REJECT 场景下端口无法放行的问题
- iptables 放行规则改为插入到 REJECT/DROP 规则之前。
- 修复 Oracle Cloud 等默认 REJECT 场景下端口放行无效的问题。

### 2acbeee - docs: 归档需求文档 v4.2-final 到项目目录
- 将需求文档 v4.2-final 归档到项目目录。

### f3fd84b - fix: 修复菜单16恢复备份与菜单15路径不匹配的bug
- 修复菜单 16 恢复备份与菜单 15 备份路径不一致的问题。

## 2026-05-19

### 192d455 - feat: add automatic global shortcut command 'sb'
- 安装后自动创建全局快捷管理命令 `sb`。

### 0746afe - feat: enhance 5G compatibility with native BBR and explicit VLESS parameters
- 加入原生 BBR 相关优化。
- 显式补充 VLESS 参数，提升 5G 网络兼容性。

### e8643f8 - fix: add 5G compatibility fixes (sniffing and prefer_ipv4)
- 加入 5G 兼容性修复。
- 增加 sniffing 和 `prefer_ipv4` 相关配置。

### 002e6d2 - feat: add sing-box M1 一键安全部署脚本
- 新增 sing-box M1 一键安全部署脚本。
- 初始目标协议为 VLESS + Reality + XTLS Vision。
