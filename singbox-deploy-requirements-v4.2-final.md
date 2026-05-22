# Sing-box 一键安全部署脚本需求文档 v4.2-final

适用对象：非程序员个人用户
使用者条件：M1 无需域名即可完成部署；已有域名可用于后续 M3 的 Hysteria2、订阅地址或节点迁移
VPS 范围：不限厂商，常见为 Ubuntu，含 amd64 与 arm64 架构
主要使用网络：以中国移动网络为主
服务端内核：官方 sing-box
默认协议：VLESS-Reality-Vision
暂不支持：VMess、AnyTLS、TUIC、Trojan、Shadowsocks
可选后续协议：Hysteria2，仅作为测速加速备用
客户端目标：Shadowrocket（小火箭）、Surge、Clash/Mihomo、sing-box 客户端
设计目标：安全、简单、低暴露、可导入、可卸载、可迁移
文档状态：定稿。本版作为 M1 开发基准文档，需求阶段到此结束，不再继续扩展需求。

本版（v4.2-final）相对 v4.2 的修订（三处小修正）：
1. §9.3 第 2 条：TLS 1.3 约束改为工程化的验收条件表述（“能完成 TLS 1.3 握手”+ openssl 检测 + 检测失败不写入），不再展开 Reality 原理。
2. §12.2：在 M1 主路径中明确“M1 不实现临时 HTTP 配置交付”。
3. §14.2：M1 以 root 运行的已知风险，要求在安装完成输出中向用户显式提示。

---

## 1. 项目定位

### 1.1 项目目标
本项目用于在一台全新的 Linux VPS 上，一键安装并配置官方 sing-box，部署一个安全、简洁、可维护的个人代理服务。

用户只需执行一条命令，即可完成：系统检测、sing-box 安装、VLESS-Reality 配置、systemd 服务托管、防火墙端口放行、节点链接生成、二维码生成、Shadowrocket / Surge / Clash-Mihomo / sing-box 客户端配置导出、后续管理菜单、一键卸载。

### 1.2 核心原则
1. 默认只部署一个主协议：VLESS-Reality。
2. 默认只开放一个端口：TCP 443。
3. 不默认部署多协议大杂烩。
4. 不修改系统全局 DNS。
5. 不关闭防火墙。
6. 不清空 iptables / nftables。
7. 不禁用 SELinux。
8. 不停止 nginx/apache/caddy 等无关服务。
9. 不默认输出 insecure=true。
10. 不在日志中泄露完整凭据。
11. 所有配置变更前备份，变更后校验，失败自动回滚。
12. 厂商无关：不针对任何特定云厂商定制，不调用任何云厂商 API。

### 1.3 非目标
本项目不做：机场面板、多用户售卖、批量节点管理、自动伪装站点、自动 CDN/Argo 隧道、自动 WARP 分流、自动多协议共存、自动修改系统 DNS、自动修改云厂商安全组、保证永远不被封、保证永远不可识别。

### 1.4 关于“域名”的说明
域名不是 M1 的必需项。M1 默认协议 VLESS-Reality 不申请、不依赖 TLS 证书，因此无需域名即可完成部署。域名仅在 M3 引入 Hysteria2 + ACME 证书时才需要，亦可用于订阅地址或节点迁移。已有域名的用户可保留备用。

---

## 2. 对参考项目的功能拆解

### 2.1 sing-box-yg 的产品功能范围
参考项目的产品范围大致包括：一键安装入口、root 权限运行、自动识别系统、多协议共存、VLESS-Reality、VMess-WS/TLS/Argo、Hysteria2、TUIC v5、AnyTLS、IPv4/IPv6/双栈、amd/arm、节点信息输出、订阅配置输出、本地生成订阅、管理菜单。其 README 明确写到支持“五大协议”共存（Vless-reality-vision、Vmess-ws(tls)/Argo、Hysteria-2、Tuic-v5、Anytls），并支持纯 IPv6、纯 IPv4、双栈 VPS 及 amd/arm 架构、Alpine 等环境。

### 2.2 应吸收的部分
一键入口、中文交互、小白默认模式、节点链接输出、二维码输出、客户端配置导出、管理菜单、卸载功能、IPv4/IPv6 检测、系统检测。

### 2.3 不应照搬的部分
默认五协议共存、默认部署 VMess、默认部署 AnyTLS、默认部署 TUIC、复杂 Argo 隧道、Psiphon/WARP/多出口分流、大量自动修改系统网络行为、一次性堆叠过多客户端形态、为“小白方便”牺牲系统安全边界。

原因：本项目是个人自用，不是公开脚本项目。协议越多，出错面、暴露面、维护成本越高。

---

## 3. 技术选型

### 3.1 服务端内核
使用：官方 sing-box。
不使用：魔改 sing-box、未知来源二进制、第三方重新打包的二进制。

### 3.2 默认协议
使用：VLESS + Reality + xtls-rprx-vision（即 VLESS-Reality-Vision）。
原因：无需自行申请 TLS 证书；不依赖 UDP；适合中国移动环境；配置复杂度低于 HY2/TUIC；客户端支持较广；适合个人自用 MVP。

### 3.3 端口
默认：TCP 443。第一版不开放 UDP 端口。

### 3.4 不做的协议
VMess、AnyTLS、TUIC、Trojan、Shadowsocks 均不做。原因：用户明确不需要 VMess/AnyTLS；TUIC 与 Hysteria2 定位重叠；Trojan/Shadowsocks 非主目标；多协议会增加脚本复杂度。

### 3.5 可选后续协议
第二阶段可考虑 Hysteria2，但默认关闭，仅作为测速加速备用。

---

## 4. 支持环境

### 4.1 操作系统
MVP 支持：Ubuntu 22.04 LTS、Ubuntu 24.04 LTS、Debian 12。
不支持：CentOS 7/8、Oracle Linux、Alpine、Arch、OpenWrt、非 systemd 系统。
说明：仅聚焦 Ubuntu/Debian 系，统一使用 apt 与 systemd，降低维护与测试成本。

### 4.2 CPU 架构
支持：amd64、arm64。
不支持：armv7、i386、riscv64。

### 4.3 权限要求
必须 root 运行。非 root 时提示：“当前脚本需要 root 权限。请切换 root 用户或使用 sudo 后重新执行。”

---

## 5. 一键入口设计

### 5.1 入口命令
用户最终看到的是一条命令。要求：入口脚本只做 bootstrap；主逻辑从固定版本地址下载；支持版本锁定；下载失败即退出；主脚本落盘后再执行。

### 5.2 版本与完整性
长期生产入口应锁定到固定版本（如固定 tag / commit），不长期直接执行随时变化的 main 分支代码。
说明：
1. 对非程序员用户，最低限度的做法是“认准一个固定版本号运行”，不必自建版本化托管设施。
2. 真正可靠的完整性校验必须来自独立渠道公布的 hash 或签名，由用户在执行前自行核对。
3. 若用户以 curl | bash 形式运行，首次入口脚本本身无法被脚本内部逻辑完全保护——脚本“自己校验自己”并不构成有效保护。脚本内部校验只能作为后续主逻辑的辅助手段，不能替代来自独立渠道的校验。

---

## 6. 安装流程

首次运行流程：
1. 检查 root 权限。
2. 检查系统发行版。
3. 检查系统版本。
4. 检查 CPU 架构。
5. 检查 systemd。
6. 检查 curl/wget/tar/openssl/qrencode 等依赖。
7. 检查公网 IPv4 / IPv6。
8. 检查 TCP 443 是否被占用。
9. 提示用户检查云厂商安全组（若有）。
10. 下载官方 sing-box。
11. 校验 sing-box 文件。
12. 安装 sing-box 到 /usr/local/bin/sing-box。
13. 生成 VLESS UUID。
14. 生成 Reality key pair。
15. 生成 Reality short_id。
16. 生成服务端 server.json。
17. 执行 sing-box check。
18. 创建 systemd 服务。
19. 启动 sing-box。
20. 检查服务状态。
21. 生成客户端配置。
22. 生成节点链接。
23. 生成二维码。
24. 输出安装结果。

说明：第 9 步本质是“提示”而非“检测”。脚本无法可靠判断 VPS 属于哪家厂商、是否存在云防火墙，因此只做统一提示。

---

## 7. 目录规范

### 7.1 主目录
/etc/sb-deploy/
├── config/
│   ├── server.json
│   ├── client-sing-box.json
│   ├── clash-mihomo.yaml
│   ├── surge.conf
│   ├── shadowrocket.txt
│   └── subscription.txt
├── credentials/
│   ├── vless.json
│   └── reality.json
├── state/
│   ├── install-state.json
│   └── firewall-rules.json
├── backup/
│   ├── server.json.bak
│   └── sing-box.bak
└── tmp/

### 7.2 日志目录
/var/log/sb-deploy/
├── install.log
├── error.log
└── audit.log

### 7.3 二进制路径
/usr/local/bin/sing-box

### 7.4 systemd 文件
/etc/systemd/system/sing-box.service

---

## 8. 凭据管理

### 8.1 必须生成的凭据
VLESS UUID、Reality private_key、Reality public_key、Reality short_id。

### 8.2 凭据生成要求
1. UUID 使用系统安全随机源生成。
2. Reality key 使用 sing-box 官方命令生成。
3. short_id 使用安全随机值。
4. 每次全新安装都生成独立凭据。
5. 重新生成凭据必须由用户主动选择。
6. 不在日志中输出完整凭据。
7. 不在错误信息中输出完整节点链接。

### 8.3 文件权限
/etc/sb-deploy/credentials/       700
/etc/sb-deploy/credentials/*.json 600
/etc/sb-deploy/config/*.json      600
/etc/sb-deploy/config/*.yaml      600
/etc/sb-deploy/config/*.conf      600
/etc/sb-deploy/state/*.json       600
/var/log/sb-deploy/               700

---

## 9. 服务端配置要求

### 9.1 VLESS-Reality 入站
服务端只开启一个入站：type=vless；listen=::；listen_port=443；flow=xtls-rprx-vision；tls.enabled=true；tls.reality.enabled=true。（此为需求描述，非最终代码。）

### 9.2 监听策略
默认监听 ::，兼容 IPv4/IPv6 双栈。脚本必须检测系统是否支持 IPv6；若 IPv6 不可用，降级为 0.0.0.0。

### 9.3 SNI / server_name 策略
安装时询问：“请输入 Reality SNI，直接回车使用默认推荐值。”
要求：
1. 必须是真实存在、可正常访问的域名；不允许空值，不允许填 IP。
2. 该域名必须能完成 TLS 1.3 握手。脚本应通过 openssl 或等效方式检测目标域名的 TLS 1.3 可达性；检测失败时不得继续写入该 SNI。
3. 建议该域名同时支持 HTTP/2（关系到 ALPN 匹配，能提升伪装一致性）。
4. 宜选用境外大厂、稳定且不易被封、网络质量好的 HTTPS 站点。
5. 不频繁自动更换；修改后必须重新生成客户端配置。

### 9.4 不启用项
默认不启用 multiplex、tcp brutal、utls 特殊伪装、udp over tcp、复杂传输层。理由：第一版追求稳定，而非堆参数。

---

## 10. 端口策略

### 10.1 默认端口
TCP 443。

### 10.2 端口检测
安装前检测：TCP 443 是否被占用；TCP 22 是否正常存在；系统防火墙是否存在；并提示云厂商安全组可能未放行。

### 10.3 如果 443 被占用
脚本不能停止 nginx/apache/caddy、不能强杀进程、不能抢占端口。
脚本应：提示 443 已被占用 → 显示占用进程名称 → 询问是否改用备用端口 → 推荐 8443 → 用户确认后使用新端口。

### 10.4 备用端口
推荐顺序：443、8443、2053、2083。不推荐默认随机高位端口。

---

## 11. 防火墙策略

### 11.1 本机防火墙
只允许添加本服务需要的端口。
允许：TCP 443、备用 TCP 端口（如 8443）。
禁止：ufw disable、systemctl stop firewalld、iptables -F、nft flush ruleset、setenforce 0、修改 /etc/selinux/config。

### 11.2 防火墙规则的记录与回收
脚本对防火墙所做的每一条改动，必须写入 state 文件 /etc/sb-deploy/state/firewall-rules.json，记录规则类型、端口、协议、添加方式、添加时间。
卸载或改端口时，只删除 state 文件中记录、且当前仍然匹配存在的规则；不依赖 comment 文本匹配作为唯一判断依据。

### 11.3 UFW
检测到 UFW 时：添加 TCP 端口放行规则（如 443/tcp），并将该规则写入 state 文件。卸载时依据 §11.2 回收。

### 11.4 firewalld
检测到 firewalld 时：只添加指定 TCP 端口，不关闭 firewalld，不修改默认 zone 以外的无关配置；所添加端口写入 state 文件。

### 11.5 nftables / iptables
MVP 阶段只检测，不主动大幅修改。如需添加规则，必须：先备份现有规则；只添加本服务端口；将所添加规则写入 state 文件；卸载时依据 §11.2 只删除本项目记录的规则。

### 11.6 云厂商安全组提示
安装完成必须提示：
“若你的 VPS 厂商提供云防火墙 / 安全组（如 Oracle、AWS、GCP、阿里云、腾讯云等），需自行登录其控制台放行 TCP 443（或你设置的端口）。脚本只能修改 VPS 系统内部防火墙，无法修改云厂商安全组。部分厂商默认已放行全部端口，是否需要操作以实际能否连通为准。”
若使用备用端口，则提示对应端口。

---

## 12. 客户端导出

这是本脚本最重要的产品功能之一。

### 12.1 必须导出的内容
安装完成后必须输出：VLESS-Reality 原始分享链接、VLESS-Reality 二维码、Shadowrocket 导入文本、Surge 配置文件、Clash/Mihomo YAML、sing-box 客户端 JSON、本地订阅文件 subscription.txt、配置文件保存路径。

### 12.2 配置交付方式（如何把配置取到客户端设备）
MVP（M1）主路径：
1. 单行 vless:// 链接：终端直接打印 + 终端二维码，手机扫码即可导入。
2. 多行配置文件（Clash YAML / Surge conf / sing-box JSON）：二维码不适用。M1 要求在管理菜单中支持“整段打印到终端”，由用户手动复制粘贴。
3. 不依赖任何第三方订阅转换或文件中转服务。
4. M1 不实现临时 HTTP 配置交付，避免额外公网暴露面。

可选增强（M2，默认关闭）：临时 HTTP 配置交付。
约束（启用时必须满足）：
- 仅作为 M2 可选功能，默认关闭，每次使用需用户显式开启。
- 由于 VPS 与手机通常不在同一局域网，该服务为可用必须监听可被手机访问的接口；因此不能依赖“仅监听本机”作为风险缓解手段。
- 必须随机生成一次性、不可猜测的下载路径。
- 监听时间极短（建议不超过 5 分钟）。
- 下载成功一次后立即自动关闭服务。
- 启用前必须向用户明确提示“配置文件将在该时段内可被公网访问”的风险。

### 12.3 Shadowrocket / 小火箭
输出文件 /etc/sb-deploy/config/shadowrocket.txt，内容为 vless:// 链接。
要求：终端显示完整链接与二维码；文件保存完整链接；日志不保存完整链接；扫码失败时提示复制链接导入。

### 12.4 Clash / Mihomo
输出文件 /etc/sb-deploy/config/clash-mihomo.yaml，必须包含 proxies、proxy-groups、rules。
M1 默认规则保持极简：局域网 / 私有地址直连；其余走代理（LAN DIRECT、GEOIP private DIRECT、MATCH PROXY）。
常见国内域名 / IP 的直连规则作为 M2 可选增强，不在 M1 强制；不默认依赖过时 geosite 逻辑。

### 12.5 Surge
输出文件 /etc/sb-deploy/config/surge.conf，必须包含 [Proxy]、[Proxy Group]、[Rule]。
要求：生成可复制配置片段；提示 Surge 版本差异可能影响 Reality 支持；导入失败时建议改用 Shadowrocket 或 Mihomo。

### 12.6 sing-box 客户端 JSON
输出文件 /etc/sb-deploy/config/client-sing-box.json。
要求：结构完整；可用于 sing-box 客户端；与服务端凭据一致；不写入服务器 private_key。

### 12.7 二维码
依赖 qrencode。要求：缺失时自动安装；二维码只在终端显示；不默认上传二维码图片到任何外部服务；不调用第三方二维码 API。

---

## 13. 日志与隐私

### 13.1 日志文件
/var/log/sb-deploy/install.log、error.log、audit.log。

### 13.2 日志允许记录
系统版本、CPU 架构、sing-box 版本、安装步骤状态、服务启动状态、端口检查结果、错误码。

### 13.3 日志禁止记录
完整 UUID、完整 Reality private_key、完整 Reality short_id、完整 vless:// 链接、完整客户端配置、完整订阅内容。

### 13.4 日志脱敏规则
示例：
UUID: 2f4c****-****-****-****-****9a81
private_key: [REDACTED]
vless link: vless://[REDACTED]

---

## 14. systemd 服务

### 14.1 服务名
sing-box.service。

### 14.2 服务运行权限
1. 开机自启。
2. 异常退出自动重启。
3. 启动前检查配置。
4. 配置错误时不启动。
5. 运行权限策略：
   - M1：允许以 root 运行 sing-box。此为已知遗留风险，必须在文档与安装完成输出中明确记录。安装输出需包含提示：“M1 阶段 sing-box 可能以 root 运行。该设计用于降低首版实现复杂度，后续 M2 将改为专用系统用户运行。”
   - M2：必须优化为专用系统用户运行，并通过 CAP_NET_BIND_SERVICE 能力绑定 443 等低位端口。
   - 若在 M1 阶段即实现专用用户方案，必须先通过完整测试（服务启动、端口绑定、配置/日志读写、升级后权限保持）再启用，不得作为 M1 的强制验收项。

### 14.3 状态检查
安装后自动执行 systemctl is-active / status 检查，输出给用户时简化为：
sing-box 服务：运行中
监听端口：TCP 443
配置检查：通过

---

## 15. 管理菜单

再次运行脚本进入管理菜单：
1. 查看节点链接
2. 显示二维码
3. 导出 Shadowrocket 链接
4. 导出 Clash/Mihomo 配置
5. 导出 Surge 配置
6. 导出 sing-box 客户端 JSON
7. 查看服务状态
8. 重启 sing-box
9. 查看最近日志
10. 更新 sing-box 内核
11. 修改监听端口
12. 修改 Reality SNI
13. 重新生成客户端配置
14. 重新生成全部凭据
15. 备份当前配置
16. 恢复上一个备份
17. 完全卸载
0. 退出

### 15.1 查看节点链接
显示完整 vless:// 链接、二维码、配置文件路径。对多行配置文件，支持整段打印到终端供复制。

### 15.2 更新 sing-box
要求：
1. 显示当前版本与可更新版本。
2. 默认不追 latest：优先更新到脚本已测试过、确认配置兼容的稳定版本；更新菜单提供“稳定版更新”，不默认跳到未知最新版本。
3. 更新前根据目标版本检查当前配置字段是否兼容，不允许盲目升级。
4. 备份旧二进制与旧配置 → 下载新版 → 执行 sing-box check → 检查通过才替换 → 失败自动回滚到旧版本与旧配置。

### 15.3 修改端口
检测新端口是否占用；修改 server.json；修改客户端配置；按 §11.2 更新防火墙规则与 state 文件；提示同步修改云厂商安全组；重启服务；检查状态。

### 15.4 修改 SNI
检查域名格式与 TLS 1.3 可达性（同 §9.3）；修改 Reality 配置；重新生成客户端配置；重启服务；显示新链接和二维码。

### 15.5 重新生成凭据
必须二次确认：“重新生成凭据后，旧客户端链接将全部失效。是否继续？[y/N]”。

---

## 16. 卸载要求

完全卸载时删除：/usr/local/bin/sing-box、/etc/sb-deploy/、/var/log/sb-deploy/、/etc/systemd/system/sing-box.service、依据 §11.2 的 state 记录回收本脚本添加的防火墙规则。

不得删除：用户已有网站、用户已有 nginx/apache/caddy、用户已有证书、用户已有防火墙规则、用户系统 DNS、用户系统软件源、云厂商安全组。

卸载完成后显示：
“sing-box 已卸载。本脚本创建的配置、日志、服务文件已删除。请注意：云厂商控制台的安全组规则（若有）需要你手动删除。”

---

## 17. 错误处理

### 17.1 退出码
0 成功；10 非 root；11 不支持的系统；12 不支持的架构；13 缺少 systemd；20 下载失败；21 校验失败；30 端口占用；31 防火墙配置失败；40 sing-box 配置检查失败；41 sing-box 启动失败；50 客户端配置生成失败；60 卸载失败。

### 17.2 失败处理原则
1. 下载失败不替换旧文件。
2. 配置检查失败不重启服务。
3. 服务启动失败自动恢复旧配置。
4. 防火墙修改失败必须提示用户。
5. 任何失败必须有中文原因说明。

---

## 18. 安全基线

### 18.1 禁止行为
关闭防火墙、清空 iptables、清空 nftables、禁用 SELinux、修改 /etc/resolv.conf、修改 /etc/hosts、替换系统软件源、停止 nginx/apache/caddy、默认部署多个协议、默认开放 UDP、默认输出 insecure=true、上传节点信息到第三方、调用第三方订阅转换服务、调用第三方二维码服务、调用任何云厂商 API、日志保存完整节点链接。

### 18.2 必须行为
使用官方 sing-box、使用固定目录、使用最小依赖、使用强随机凭据、收紧文件权限、配置检查后启动、修改前备份、失败后回滚、防火墙改动记录入 state 文件、卸载只删自己创建的东西。

---

## 19. 依赖要求

### 19.1 最小依赖
curl 或 wget、tar、gzip、openssl、qrencode、systemd。
可选：jq、unzip。
不默认安装：nginx、apache、caddy、cloudflared、warp、docker、python、nodejs。

---

## 20. 云厂商安全组（厂商无关）

### 20.1 安全组提示
安装完成、以及每次改动端口后，必须显示通用提示：
“若你的 VPS 厂商提供云防火墙 / 安全组，需自行登录其控制台放行 TCP 443（或你设置的端口）。脚本只能修改 VPS 系统内部防火墙，无法修改云厂商安全组。”
不同厂商默认策略差异较大：部分厂商（如 Oracle、AWS）默认安全组偏严，需手动放行；部分小厂商 VPS 默认放行全部端口。是否需要操作以实际能否连通为准。

### 20.2 不自动处理
脚本不尝试登录任何云厂商 API 修改安全组。原因：需要云账号高权限；增加安全风险；对非程序员不透明；出错后风险更大。

---

## 21. 中国移动网络专项建议

默认策略：优先 TCP；不默认 UDP；不默认 Hysteria2；不默认 TUIC；不默认端口跳跃；不默认随机高位端口。
原因：中国移动网络下 UDP/QUIC 表现可能不稳定；个人自用优先求稳，不优先追求测速峰值。

---

## 22. Hysteria2 后续扩展（不进 MVP）

### 22.1 是否加入
第一版不加入；第二/三版可选加入 Hysteria2 加速节点。

### 22.2 启用条件
用户明确选择开启；用户域名解析正确；ACME 证书申请成功；UDP 端口可达；客户端支持 HY2。

### 22.3 默认端口
UDP 8443。

### 22.4 失败策略
证书失败：不启用 HY2；UDP 不通：不启用 HY2；服务失败：回滚到只使用 VLESS-Reality。

---

## 23. 测试验收标准

TC-01 全新安装
环境矩阵：Ubuntu 22.04 与 24.04 × amd64 与 arm64；并在至少 1–2 家不同云厂商各跑一遍。
预期：安装成功；sing-box 运行中；TCP 443 监听；输出 vless:// 链接与二维码；生成 Shadowrocket、Clash/Mihomo、Surge、sing-box 客户端四类配置。

TC-02 重复运行
预期：进入管理菜单；不覆盖配置；不重新生成凭据；不改变端口。

TC-03 端口占用
模拟 443 被占用。预期：不停止占用进程；提示占用进程；推荐备用端口；用户确认后才修改。

TC-04 防火墙安全
预期：未关闭 ufw；未停止 firewalld；未清空 iptables；未禁用 SELinux；只添加所需 TCP 端口；所添加规则已写入 state 文件。

TC-05 客户端导入
至少测试：Shadowrocket 扫码、Shadowrocket 复制链接、Clash Verge / Mihomo Party 导入 YAML、Surge 导入 conf、sing-box 客户端导入 JSON。

TC-06 凭据安全
预期：credentials 目录权限 700；凭据文件权限 600；日志无完整 UUID、无 private_key、无完整 vless 链接。

TC-07 更新回滚
模拟新版 sing-box 配置不兼容。预期：更新失败；旧版本恢复；旧配置恢复；服务继续运行。

TC-08 卸载
预期删除：/usr/local/bin/sing-box、/etc/sb-deploy/、/var/log/sb-deploy/、/etc/systemd/system/sing-box.service、state 文件中记录的防火墙规则。
预期保留：用户网站、系统 DNS、系统软件源、用户已有防火墙规则、云厂商安全组。

TC-09 无域名场景安装
环境：未配置任何域名的全新 VPS。
预期：M1 安装全程不要求输入域名；VLESS-Reality 部署成功；服务正常运行；四类客户端配置正常生成。

---

## 24. 版本路线图

M1（最小安全版，当前应做的版本）：官方 sing-box、VLESS-Reality、TCP 443、systemd（允许 root 运行并记录风险）、二维码、Shadowrocket 链接、Clash/Mihomo YAML（极简规则）、Surge conf、sing-box 客户端 JSON、管理菜单、卸载。

M2（体验增强版）：一键更新（稳定版策略）、一键备份、一键恢复、配置重新生成、订阅文件、更好的 IPv6 检测、临时 HTTP 配置交付（默认关闭）、Clash 国内直连规则增强、服务改为专用用户 + CAP_NET_BIND_SERVICE。

M3（可选加速版）：Hysteria2、ACME 证书、UDP 可达性测试、HY2 二维码、HY2 客户端导出。

M4（迁移增强版）：一键导出迁移包、新 VPS 导入配置、更换 IP 后快速重建节点。

---

## 25. 最终结论

本项目不需要复刻 sing-box-yg 的“五协议精装桶”。参考项目的定位是“大而全、小白多协议合集”，而本项目的定位是个人自用的单协议安全版：

官方 sing-box + VLESS-Reality + TCP 443 + 客户端配置导出 + 二维码 + 管理菜单 + 安全卸载。

一句话：不要做“精装桶”，做“单协议、厂商无关的安全版”。本文档（v4.2-final）至此定稿，进入 M1 开发。
