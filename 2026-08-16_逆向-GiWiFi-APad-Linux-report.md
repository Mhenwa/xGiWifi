# GiWiFi APad Linux 登录协议逆向与实机验证报告

> 现场结论（2026-09-01）：APK App Portal 协议已完整复现。Linux 连接 GiWiFi 无线 `wlp7s0`（10.16.1.227）时，APad `authLogin` 返回 `resultCode=0`，随后 Portal 与公网探针均为 HTTP 200；同一客户端从 RJ45 `enp9s0`（10.20.x.x）发起时，phone/pad 请求返回 `resultCode=123`。这表明决定因素是 GiWiFi 接入网段，客户端没有混用旧 Web 协议；Windows 仍保留原 Web Portal 流程。

## 报告信息

| 项目 | 值 |
|---|---|
| 日期 | 2026-09-01（Asia/Shanghai；Case 于 2026-08-16 建立） |
| Case | [20260816-xgiwifi-apad-live](../work/20260816-xgiwifi-apad-live/README.md) |
| Scope | [scope.md](../work/20260816-xgiwifi-apad-live/scope.md) |
| Timeline | [timeline.md](../work/20260816-xgiwifi-apad-live/timeline.md) |
| APK | `giwifi-2.4.1.21.apk` |
| APK SHA-256 | `89ac60af719b17c304c0ae786bac63723b700b169052e22575c8f4f328f04bbd` |
| 客户端 | `xGiWifi` Linux x86-64 |
| 报告 flavor | `null`（普通 APK/协议逆向） |
| 数据处理 | 账号、密码、请求密文均省略 |

## 执行摘要

本次工作完成了五个闭环：

1. 从 APK 静态还原 Android/APad 的账号层和 App Portal 网络准入层，而不是沿用旧 iPad/Web Portal 参数。
2. 修复 Linux 多网卡下的本地身份选择错误。旧实现把 Dart `Socket.address` 当成本机源地址，随后回退到 metric 更低的手机 USB 默认路由，造成“HTTP 经 RJ45、加密正文却携带 USB IP/MAC”的不一致。新实现以 `ip -4 -o route get PORTAL_IPV4` 的 `dev/src` 为准。
3. 在真实 RJ45 GiWiFi 环境重放 APK 第一层账号登录，APad `service_type=1` 返回 `resultCode=0 / 登录成功！`，验证账号、密码、APad 类型和第一层 AES 字段编码。
4. 通过 userIp/userMac/appUuid 对照矩阵隔离决定变量：RJ45 10.20.x.x 声明得到 123，而平板无线 10.16.x.x 声明得到 0；userMac 与 appUuid 的切换未改变方向。
5. 关闭 Meta 虚拟网卡后，将 Portal 目标路由固定到 GiWiFi 无线；APad 从 `wlp7s0` 完成 `queryAuthState=0/authState=1` 与 `authLogin=0`，并以同一源地址通过 Portal 和公网 HTTP 200 探针。

因此，RJ45 上的 123 是该接入网段的服务端业务策略结果；无线网段的成功实测证明协议、签名、AES、设备元组与账号链路均可工作。客户端响应中仍未公开内部套餐/NAS 规则，结论按接入网段分别适用。

## 测试范围与网络隔离

### 网络角色

| 角色 | 接口 | IPv4 | 网关/路由 | 现场状态 |
|---|---|---|---|---|
| 手机 USB 共享公网（历史隔离采样） | `enx56d9e15a3550` | `192.168.238.239/24`（历史） | 默认路由 metric 103（历史） | 历史 IPv4 HTTPS 返回 200；本轮无线验证未启用 USB |
| GiWiFi RJ45 对照 | `enp9s0` | `10.20.1.57/16` | `10.20.1.1`，metric 100 | phone/pad 第二层返回 123，后置探测 302 |
| GiWiFi 无线（本轮成功链路） | `wlp7s0` | `10.16.1.227/16` | `10.16.1.1`，metric 600；Portal /32 metric 5 | APad 第二层返回 0，Portal/公网探针 200 |
| Meta TUN | `Meta` | 无（接口 DOWN） | 无活动策略路由 | 虚拟网卡模式已关闭 |

当前 Portal 精确路由均进入 GiWiFi 无线；RJ45 保留为较低优先级回退：

~~~text
100.100.100.2 via 10.16.1.1 dev wlp7s0 src 10.16.1.227 metric 5
10.100.100.2 via 10.16.1.1 dev wlp7s0 src 10.16.1.227 metric 5
115.159.209.137 via 10.16.1.1 dev wlp7s0 src 10.16.1.227 metric 5
100.100.100.2 via 10.20.1.1 dev enp9s0 src 10.20.1.57 metric 100
115.159.209.137 via 10.20.1.1 dev enp9s0 src 10.20.1.57 metric 100
~~~

历史 USB 隔离采样中的普通 IPv4 公网请求明确绑定手机 USB：

~~~text
PHONE_USB_IPV4 status=200 local=192.168.238.239 remote=39.156.70.239 (historical)
~~~

本轮无线认证前的网关探测：

~~~text
status=301
local=10.16.1.227
remote=115.159.209.137
redirect=http://100.100.100.2/gportal/web/login
~~~

本轮无线认证后的探针：

~~~text
WIFI_PORTAL status=200 local=10.16.1.227 remote=115.159.209.137 redirect=
WIFI_PUBLIC status=200 local=10.16.1.227 remote=39.156.70.239 redirect=
~~~

RJ45 对照仍返回：

~~~text
RJ45 status=302 local=10.20.1.57 remote=115.159.209.137 redirect=http://100.100.100.2/gportal/web/login?...&wlanacname=GIWIFI-BAS
~~~

历史 USB/RJ45 隔离见 [E-001](../work/20260816-xgiwifi-apad-live/evidence/E-001.md)；userIp 矩阵见 [E-008](../work/20260816-xgiwifi-apad-live/evidence/E-008.md)；本轮无线成功见 [E-009](../work/20260816-xgiwifi-apad-live/evidence/E-009.md)。

## 客户端协议升级结果

### 三种可选设备

| 客户端选项 | 协议分支 | 关键设备字段 | 状态 |
|---|---|---|---|
| Android | APK App Portal | `btype=1`、`staType=phone`、`staModel=Google,Pixel 9,35,15` | 已实现并实测 |
| APad | APK App Portal | `btype=2`、`staType=pad`、`staModel=samsung,SM-T870,34,14` | 已实现并实测 |
| Windows | 原 Web Portal | `/gportal/Web/loginAction` 及既有 Windows 参数 | 保持原协议 |

生产实现中的分支位置：

- [giwifi_models.dart](lib/giwifi/giwifi_models.dart)：设备类型、协议类型和三组常量。
- [giwifi_client.dart](lib/giwifi/giwifi_client.dart)：Android/APad 的 App Portal 分支与 Windows Web Portal 分支。
- [app_network_identity.dart](lib/giwifi/app_network_identity.dart)：Linux/Android 网络接口身份解析。

Android/APad 在 [giwifi_client.dart](lib/giwifi/giwifi_client.dart) 中先完成 APK 账号层 `appLogin.bin`，再执行 `queryAuthState/authLogin/reBindMac`，不会落入后面的 Windows Web Portal `loginAction`。

### APK 第一层账号登录

APK 锚点 `C3989i.m22802A0()` 构造：

~~~text
POST http://PORTAL_HOST:8080/wocloud_v2/appUser/appLogin.bin
Content-Type: text/plain;charset=utf-8
~~~

内层字段：

~~~text
service_type
phone
staticPassword
ip
apMac
gwAddress
staType
staModel
~~~

外层字段：

~~~text
token
version=2.4.1.21
mac
gatewayId
data=<JSON string>
~~~

APK 对受保护字段逐项执行固定 AES-128-ECB/PKCS5 编码。历史 RJ45 现场 APad `service_type=1` 结果为：

~~~text
interface=enp9s0
userIp=10.20.195.28
userMac=18:C0:4D:2F:A8:E7
resultCode=0
resultMsg=登录成功！
~~~

完整观察见 [E-005](../work/20260816-xgiwifi-apad-live/evidence/E-005.md)。

### APK 第二层 App Portal

APK `C3989i.m22808D0()` 的 `authLogin` 字段共 15 项：

~~~text
appUuid
userIp
nasName
ssid
nasIp
userMac
vlan
apMac
userFirstUrl
userName
passwd
btype
staType
staModel
timestamp
~~~

签名与封装顺序：

1. 字段键按 Java `String.compareTo` 顺序排列。
2. 使用原始密码计算 `MD5(sortedParams + 5447c08b53e8dac47f81269f98cfeada)`。
3. 只对 `passwd` 执行 Java `URLEncoder` 编码。
4. 重新排序，并追加小写 `sign`。
5. 整体执行 AES-128-ECB/PKCS5Padding。
6. Base64 `NO_WRAP`。
7. URL encode。
8. 作为 FormBody 的 `data` 字段再做表单编码。

本地 [app_portal_protocol_test.dart](test/app_portal_protocol_test.dart) 使用独立 MD5/OpenSSL 固定向量验证了明文排序、签名、AES、Base64 和 URL 编码。完整 APK 锚点见 [E-002](../work/20260816-xgiwifi-apad-live/evidence/E-002.md)。

APK 的 OkHttp 构造器仅设置五秒连接超时，没有安装 `CookieJar`。普通账号登录成功后缓存的 `loginStaticPassword` 也是原始输入。因此账号层与 Portal 层之间不存在额外 Cookie 或服务器下发替代密码这一前置条件。

## Linux 路由身份修复

旧链路的关键错误是：

~~~text
socket.address.address
~~~

在 Dart 已建立连接的 `Socket` 上，该属性代表连接目标地址，例如 `10.100.100.2`，不是内核选定的本机源 IP。本地接口匹配因此为空，代码再按默认路由 metric 回退到手机 USB：

~~~text
错误身份: interface=enx56d9e15a3550, userIp=192.168.238.239
实际传输: enp9s0 -> 10.100.100.2
~~~

这解释了修复前服务器返回 `CHALLENGE_ERR_DENY / resultCode=99`：加密正文的网络身份与真实入口不一致。

新实现执行：

~~~bash
ip -4 -o route get PORTAL_IPV4
~~~

并完成以下约束：

- 独立解析 `dev` 与 `src`，不依赖列号。
- 精确匹配 `NetworkInterface.name`。
- 验证 `src` 确实属于该接口。
- 从 `/sys/class/net/<dev>/address` 读取 MAC。
- GUI 启动环境依次尝试 `/usr/sbin/ip`、`/sbin/ip`、`/usr/bin/ip`、`/bin/ip` 和 `ip`。
- Portal 路由若指向虚拟接口，直接报告该状态，不再拿另一块物理网卡身份代替。

实机结果（本轮无线与 RJ45 对照）：

~~~text
Wi-Fi: interface=wlp7s0 userIp=10.16.1.227 userMac=<本机无线 MAC>
RJ45: interface=enp9s0 userIp=10.20.1.57 userMac=<本机 RJ45 MAC>
~~~

纯解析测试覆盖网关路由、直连路由、`dev/src` 顺序变化、`table/from/uid/cache` 可选字段、缺失字段和无效 IPv4。完整证据见 [E-003](../work/20260816-xgiwifi-apad-live/evidence/E-003.md)；无线现场身份与准入见 [E-009](../work/20260816-xgiwifi-apad-live/evidence/E-009.md)。

## 现场认证调用流

~~~mermaid
sequenceDiagram
    autonumber
    participant L as xGiWifi Linux
    participant R as Linux 路由
    participant D as 115.159.209.137
    participant P as 100.100.100.2 Portal
    participant A as APK 账号接口 :8080
    participant W as wlp7s0 / 10.16.1.227
    participant E as enp9s0 / 10.20.x.x

    L->>D: 无线 GET /，关闭重定向
    D-->>L: 301 到 canonical Portal
    L->>R: ip -4 route get 100.100.100.2
    R-->>L: dev=wlp7s0, src=10.16.1.227
    L->>A: APad appLogin.bin，service_type=1
    A-->>L: resultCode=0，登录成功
    L->>P: queryAuthState（App Portal）
    P-->>L: resultCode=0，authState=1
    L->>P: APad authLogin（btype=2, staType=pad）
    P-->>L: resultCode=0，认证成功
    L->>W: Portal 与公网 HTTP 探针
    W-->>L: HTTP 200，无重定向
    L->>E: RJ45 对照 authLogin（同一 APK 协议）
    E-->>L: resultCode=123，后置探针 302
~~~

## 实机结果

| 检查 | 请求身份/条件 | 服务端结果 | 判定 |
|---|---|---|---|
| 手机 USB IPv4 公网（历史） | `enx56d9e15a3550 / 192.168.238.239` | HTTP 200 | 普通公网隔离出口可用 |
| RJ45 登录前对照 | `enp9s0 / 10.20.1.57` | HTTP 302 到 `GIWIFI-BAS` | RJ45 尚未建立会话 |
| APK 账号层 APad | `service_type=1, staType=pad` | `resultCode=0 / 登录成功！` | 账号层协议有效 |
| 无线 Portal 状态 | `wlp7s0 / 10.16.1.227` | `resultCode=0, authState=1` | 允许继续认证 |
| 无线 Portal APad | `btype=2, staType=pad` | `resultCode=0 / 认证成功！` | 建立 APad 会话 |
| 无线认证后探针 | 强制 `wlp7s0` | Portal HTTP 200；公网 HTTP 200 | 已获得实际公网准入 |
| RJ45 Portal APad 对照 | `enp9s0 / 10.20.x.x`，`btype=2` | `resultCode=123` | 该接入网段按策略拒绝 |
| RJ45 Portal Android 对照 | `enp9s0 / 10.20.x.x`，`btype=1` | `resultCode=123` | 与 APad 相同的网段策略结果 |

RJ45 对照 trace 见 [E-004](../work/20260816-xgiwifi-apad-live/evidence/E-004.md)，userIp/userMac/appUuid 矩阵见 [E-008](../work/20260816-xgiwifi-apad-live/evidence/E-008.md)，无线成功 trace 与后置探针见 [E-009](../work/20260816-xgiwifi-apad-live/evidence/E-009.md)。

## Evidence

| ID | 观察 | 类型 | 关联结论 |
|---|---|---|---|
| [E-001](../work/20260816-xgiwifi-apad-live/evidence/E-001.md) | 手机 USB 公网与 RJ45 Portal 路由隔离（历史） | command/network | F-001, F-005 |
| [E-002](../work/20260816-xgiwifi-apad-live/evidence/E-002.md) | APK App Portal 字段与算法还原 | file | F-002, F-003, F-004 |
| [E-003](../work/20260816-xgiwifi-apad-live/evidence/E-003.md) | Linux route-get 身份修复 | file/command | F-001, F-005 |
| [E-004](../work/20260816-xgiwifi-apad-live/evidence/E-004.md) | RJ45 APad/Android 第二层均为 123，后置仍 302 | network/log | F-001, F-003, F-004 |
| [E-005](../work/20260816-xgiwifi-apad-live/evidence/E-005.md) | APK 第一层 APad 登录成功 | network/log | F-002 |
| [E-006](../work/20260816-xgiwifi-apad-live/evidence/E-006.md) | Linux bundle、AOT 与运行进程一致 | file/command | F-002, F-005, F-006 |
| [E-007](../work/20260816-xgiwifi-apad-live/evidence/E-007.md) | 官方 APK 平板成功 PCAP 与签名校验 | network/file | F-002 |
| [E-008](../work/20260816-xgiwifi-apad-live/evidence/E-008.md) | userIp/userMac/appUuid 对照矩阵 | log | F-003, F-004 |
| [E-009](../work/20260816-xgiwifi-apad-live/evidence/E-009.md) | Linux wlp7s0 APad 成功并获得公网准入 | network/log | F-001, F-002, F-004, F-005, F-006 |

## Findings

### F-001
- title: Linux Portal 网络身份选择已按目标路由修复
- severity: n/a_re
- category: reverse_algo
- status: validated
- evidence_ids: [E-001, E-003, E-004, E-009]
- location: lib/giwifi/app_network_identity.dart:117
- impact: 请求正文携带的 userIp/userMac 与实际 Portal 出口接口一致；无线使用 wlp7s0/10.16.1.227，RJ45 使用 enp9s0/10.20.x.x。
- confidence: high
- repro_steps: 执行 `ip -4 -o route get PORTAL_IPV4`，再运行 APad live 测试并核对 trace 中 interface 与 userIp。
- remediation: 已落实于生产源码；保留 route-get 解析和接口断言回归。
- optional_attack: n/a

### F-002
- title: APK Android/APad App Portal 协议已完整复现
- severity: n/a_re
- category: reverse_algo
- status: validated
- evidence_ids: [E-002, E-005, E-007, E-009]
- location: C3989i.m22802A0, C3989i.m22808D0, C3989i.m22832P0, C3989i.m22836R0
- impact: Android/APad 使用 APK 账号层、queryAuthState、authLogin、reBindMac、设备元组、签名和 AES 封装；Windows 保持 Web Portal 分支。
- confidence: high
- repro_steps: 对照 JADX 锚点，运行固定向量测试，解密 E-007 官方平板 PCAP，再运行 E-009 无线 APad 重放。
- remediation: n/a for pure reverse engineering
- optional_attack: n/a

### F-003
- title: RJ45 10.20.x.x 接入网段对 phone/pad App Portal 认证返回业务码 123
- severity: n/a_re
- category: design
- status: validated
- evidence_ids: [E-004, E-008]
- location: http://10.100.100.2/gportal/app/authLogin
- impact: APad 与 Android 在 enp9s0 上均先得到 queryAuthState=0/authState=1，随后 authLogin=123；RJ45 后置探测仍为 HTTP 302。
- confidence: high
- repro_steps: 使用 `XGIWIFI_EXPECTED_INTERFACE=enp9s0` 分别运行 APad/Android 测试，并执行 enp9s0 后置 HTTP 探针。
- remediation: 该结果限定于 RJ45 10.20.x.x 接入网段；保留原始业务码和后置探针记录。
- optional_attack: n/a

### F-004
- title: userIp 所属 GiWiFi 接入网段是本次业务结果的决定变量
- severity: n/a_re
- category: design
- status: validated
- evidence_ids: [E-008, E-009]
- location: App Portal authLogin userIp/userMac 对照矩阵
- impact: 同一协议与凭据下，声明 Linux RJ45 userIp 得到 123，声明平板 Wi-Fi 10.16.x.x userIp 得到 0；切换 userMac 或 appUuid 未改变矩阵方向。
- confidence: high
- repro_steps: 复测 E-008 四组 fresh-timestamp 请求，再用 E-009 的真实 wlp7s0 身份执行 APad 登录和公网探针。
- remediation: 部署时按实际接入接口获取 userIp/userMac，不把 RJ45 身份伪装成平板地址。
- optional_attack: n/a

### F-005
- title: 手机 USB 公网、GiWiFi 接入链路与 Linux 交付包已形成可验证隔离
- severity: n/a_re
- category: other
- status: validated
- evidence_ids: [E-001, E-003, E-006, E-009]
- location: Linux routing tables and build/linux/x64/release/bundle
- impact: 历史现场中手机 USB 承担普通公网；当前无线实测绑定 wlp7s0；最终 bundle 的 AOT、ELF 依赖和运行映射可独立核验。
- confidence: high
- repro_steps: 分别绑定 USB/RJ45/无线接口执行探针，核对目标 route-get，再执行 bundle 完整性检查。
- remediation: 保留 Portal 精确路由、接口断言和认证后 HTTP 探针作为验收项。
- optional_attack: n/a

### F-006
- title: Linux wlp7s0 使用 APK APad 协议获得真实 GiWiFi 公网准入
- severity: n/a_re
- category: design
- status: validated
- evidence_ids: [E-009, E-002, E-006]
- location: wlp7s0/10.16.1.227 → /gportal/app/authLogin
- impact: 无线网段上的 queryAuthState 返回 0/authState=1，APad authLogin 返回 0；同一源地址访问 Portal 目标和公网目标均 HTTP 200 且无重定向，表明会话已实际生效。
- confidence: high
- repro_steps: 使用 E-009 中的命令运行无线 APad live 测试，然后执行 `curl --interface wlp7s0` 的 Portal 与公网探针。
- remediation: 交付 Linux 包时默认使用实际 GiWiFi 接口；RJ45 与无线分别显示其服务端策略结果。
- optional_attack: n/a

## Path

### P-001
- title: Linux APad 从接口选择到 GiWiFi 实际准入的完整调用流
- path_type: callflow
- start: 电脑连接 GiWiFi 无线，wlp7s0 获得 10.16.1.227；Meta TUN 处于 DOWN
- goal: 验证 APad 是否以 APK App Portal 协议建立真实 GiWiFi 会话，并保留 RJ45 对照
- steps: |
    1. action: 当前网关探测返回 301，解析 canonical Portal 100.100.100.2 — evidence: E-009 — finding: F-002
    2. action: route-get 将 Portal 目标经 10.16.1.1 送往 wlp7s0，源地址 10.16.1.227 — evidence: E-009 — finding: F-001
    3. action: queryAuthState 返回 resultCode=0/authState=1 — evidence: E-009 — finding: F-002
    4. action: APad authLogin 使用 btype=2/staType=pad 返回 resultCode=0 — evidence: E-009 — finding: F-006
    5. action: wlp7s0 访问 Portal 目标与公网目标均 HTTP 200、无 redirect — evidence: E-009 — finding: F-006
    6. action: RJ45 enp9s0 对照的 APad/Android authLogin 返回 123，后置探测为 302 — evidence: E-004, E-008 — finding: F-003
    7. action: 官方 APK 平板 PCAP 的字段、AES 和 sign 校验通过 — evidence: E-007 — finding: F-002
    8. action: Linux bundle 与 AOT/运行依赖核验 — evidence: E-006 — finding: F-005
- residual_risks: RJ45 与无线属于不同接入网段，业务策略结果不可互相外推；服务端响应未公开内部套餐/NAS 规则。

~~~mermaid
flowchart TD
    A["GiWiFi 无线 wlp7s0 / 10.16.1.227"] --> B["Portal 路由经 10.16.1.1"]
    B --> C["GET 探测：301 → 100.100.100.2"]
    C --> D["queryAuthState：0 / authState=1"]
    D --> E["APad authLogin：btype=2 / staType=pad / 0"]
    E --> F["wlp7s0 Portal + 公网探针：HTTP 200"]
    R["RJ45 enp9s0 / 10.20.x.x"] --> S["同一 APad/Android 请求：123；后置探针：302"]
~~~

## Timeline 摘要

| 时间 | 阶段 | 结果 | Evidence |
|---|---|---|---|
| 20:54 | Case 初始化 | Scope 就绪 | — |
| 21:00 | APK 静态逆向 | 账号层、App Portal、设备分支和算法还原 | E-002 |
| 21:01 | Linux 身份修复 | 从 USB 默认路由回退切换到 Portal `dev/src` | E-001, E-003 |
| 21:06 | Linux AOT/打包 | 最终 bundle 启动，依赖与映射一致 | E-006 |
| 21:30 | 第一层现场测试 | APad `resultCode=0 / 登录成功` | E-005 |
| 21:32 | 第二层 A/B 现场测试 | APad 与 Android 均为 123；APad 后仍 302 | E-001, E-004 |
| 21:34 | 回归（历史） | 42 passed、3 live skipped、analyzer clean | E-002, E-003 |
| 21:39 | 当前网关与路由 | Portal 返回 301；canonical 100.100.100.2 与 115.159.209.137 的 /32 路由切到 wlp7s0；Meta DOWN | E-009 |
| 21:45 | 无线 APad 实测 | wlp7s0 `queryAuthState=0/authState=1`，`authLogin=0` | E-009 |
| 21:52 | 无线认证后探针 | Portal 与公网目标均 HTTP 200、无重定向 | E-009 |
| 22:04 | 当前完整回归 | 50 passed、3 live skipped、analyzer clean | E-002, E-003, E-009 |

完整时间线见 [timeline.md](../work/20260816-xgiwifi-apad-live/timeline.md)。

## 复测命令

### 默认回归与静态分析

~~~bash
cd /home/mhenwa/codefile/ctf/xGiWifi
flutter test --no-pub --reporter compact
flutter analyze --no-pub
~~~

当前结果（本次源码加入账号层回归后）：

~~~text
50 passed
3 live tests skipped by default
No issues found
~~~

### 手机 USB 与 RJ45 路由

~~~bash
ip -4 route show default
ip -4 route get 115.159.209.137
ip -4 route get 10.100.100.2

curl -4 --interface enx56d9e15a3550 \
  --connect-timeout 8 --max-time 15 \
  -sS -o /dev/null \
  -w 'PHONE_USB_IPV4 status=%{http_code} local=%{local_ip} remote=%{remote_ip}\n' \
  https://www.baidu.com/

curl --interface enp9s0 \
  --connect-timeout 8 --max-time 15 \
  -sS -o /dev/null \
  -w 'RJ45 status=%{http_code} local=%{local_ip} redirect=%{redirect_url}\n' \
  http://115.159.209.137
~~~

### APK 第一层 APad 账号登录

测试从本机 xGiWifi 配置读取账号、密码与 `appUuid`，输出不包含它们：

~~~bash
cd /home/mhenwa/codefile/ctf/xGiWifi
XGIWIFI_LIVE_ACCOUNT_LOGIN=1 \
XGIWIFI_LIVE_PROFILE=apad \
XGIWIFI_SERVICE_TYPES=1 \
XGIWIFI_EXPECTED_INTERFACE=enp9s0 \
  flutter test --no-pub \
    test/live_app_account_login_test.dart \
    --reporter expanded
~~~

期望当前现场响应：

~~~text
resultCode=0
resultMsg=登录成功！
~~~

### APK 第二层 APad（RJ45 对照）

~~~bash
cd /home/mhenwa/codefile/ctf/xGiWifi
XGIWIFI_LIVE_TEST=1 \
XGIWIFI_LIVE_PROFILE=apad \
XGIWIFI_LIVE_ALLOW_REBIND=1 \
XGIWIFI_EXPECTED_INTERFACE=enp9s0 \
  flutter test --no-pub \
    test/live_apad_network_test.dart \
    --reporter expanded
~~~

RJ45 对照测试的最终断言要求真实登录成功；当 10.20.x.x 接入网段返回 123 时，命令以一项测试失败退出，并打印脱敏 trace。关键现场值：

~~~text
queryAuthState: resultCode=0, authState=1
authLogin: resultCode=123
该账户套餐不支持本类型设备使用!
~~~

### APK 第二层 APad（GiWiFi 无线实测）

关闭虚拟网卡模式后，先确认 Portal 目标走 `wlp7s0`，再运行同一 APK App Portal 流程：

~~~bash
cd /home/mhenwa/codefile/ctf/xGiWifi
ip -4 -o route get 100.100.100.2
ip -4 -o route get 115.159.209.137

XGIWIFI_LIVE_TEST=1 \
XGIWIFI_LIVE_PROFILE=apad \
XGIWIFI_LIVE_ALLOW_REBIND=1 \
XGIWIFI_EXPECTED_INTERFACE=wlp7s0 \
XGIWIFI_SETTINGS_PATH=/home/mhenwa/.local/share/xgiwifi/shared_preferences.json \
  flutter test --no-pub \
    test/live_apad_network_test.dart \
    --reporter expanded
~~~

本轮无线关键响应：

~~~text
interface=wlp7s0
userIp=10.16.1.227
queryAuthState: resultCode=0, authState=1
authLogin: resultCode=0, 认证成功！
outcome=success
~~~

认证后的真实准入探针：

~~~bash
curl --interface wlp7s0 --max-time 10 -sS -o /dev/null \
  -w 'WIFI_PORTAL status=%{http_code} local=%{local_ip} remote=%{remote_ip} redirect=%{redirect_url}\n' \
  http://115.159.209.137
curl --interface wlp7s0 --max-time 10 -sS -o /dev/null \
  -w 'WIFI_PUBLIC status=%{http_code} local=%{local_ip} remote=%{remote_ip} redirect=%{redirect_url}\n' \
  http://39.156.70.239
~~~

两条探针均返回 `HTTP 200`，本地源地址为 `10.16.1.227` 且无重定向；完整脱敏记录见 [E-009](../work/20260816-xgiwifi-apad-live/evidence/E-009.md)。

### Android 对照

~~~bash
cd /home/mhenwa/codefile/ctf/xGiWifi
XGIWIFI_LIVE_TEST=1 \
XGIWIFI_LIVE_PROFILE=android \
XGIWIFI_LIVE_ALLOW_REBIND=1 \
XGIWIFI_EXPECTED_INTERFACE=enp9s0 \
  flutter test --no-pub \
    test/live_apad_network_test.dart \
    --reporter expanded
~~~

## Linux 桌面端交付

| 产物 | 路径 | SHA-256 |
|---|---|---|
| runner | `build/linux/x64/release/bundle/xgiwifi` | `0dec2998043cfec644dda70b634868c85f9f3a4c96093af786e794a30a085e9d` |
| AOT | `build/linux/x64/release/bundle/lib/libapp.so` | `3e0d02ed4e4c2c2275451022822fc9df59b9db4b25ebee06fc5cfb9d261884d9` |
| tar.gz | `build/xGiWifi-linux-x64-apk-app-protocol.tar.gz` | `e08ee41e751256bb86f59b4be934ecfc73d932f2d45ce8c25e965f3e26b95093` |

交付检查：

- gzip 完整性通过。
- runner 为 ELF64 x86-64。
- RUNPATH 为 `$ORIGIN/lib`。
- `ldd` 没有缺失项。
- PID `53581` 于 2026-09-01 22:44:17+08 从最终 bundle 启动；启动快照中的 runner 与 `libapp.so` 对应当前交付物。
- AOT 中可见 `queryAuthState`、`authLogin`、`reBindMac` 与 `/sys/class/net/` 标记。
- KWin 已识别并激活原生 Wayland `xgiwifi` 窗口；[脱敏运行截图](../work/20260816-xgiwifi-apad-live/evidence/xgiwifi-wayland-running-redacted.png)中可见 Android、APad、Windows 三个选项。无线 APad 的认证与公网准入由 E-009 独立记录，RJ45 的 123 对照由 E-004/E-008 记录。

完整检查见 [E-006](../work/20260816-xgiwifi-apad-live/evidence/E-006.md)。

## 结论与剩余可见性

本轮已经确认：

- Android/APad 严格使用 APK 的账号层（`appLogin.bin`）与 App Portal（`queryAuthState`、`authLogin`、`reBindMac`），没有落入旧 iPad/Web Portal 请求。
- Windows 分支保持原有 Web Portal `loginAction` 协议。
- Linux 路由身份按目标 `dev/src` 解析；本轮无线使用 `wlp7s0 / 10.16.1.227`，RJ45 对照使用 `enp9s0 / 10.20.x.x`。
- APK 第一层 APad 账号接口返回 `resultCode=0 / 登录成功！`，固定向量、官方平板 PCAP 的 AES/sign 校验均通过。
- GiWiFi 无线 10.16.x.x 网段上的 APad 第二层返回 `queryAuthState=0/authState=1` 与 `authLogin=0`；Portal 目标和公网目标的 wlp7s0 探针均返回 HTTP 200，无重定向，确认已获得实际公网准入。
- RJ45 10.20.x.x 网段上的 APad 与 Android 对照仍返回 `authLogin=123`，后置探针为 HTTP 302；该结果是接入网段服务端策略差异，不代表协议实现失败。

因此，协议升级与 Linux 无线实机验收均已完成。若业务上要求 RJ45 也支持 phone/pad，应由网络侧调整该接入网段的终端类型策略；客户端现已把接口、设备元组和服务端业务码完整暴露，后续可直接按 E-004/E-008 对照复测。服务端响应未包含更细的套餐/NAS 内部规则，现有结论按本次接口与 `GIWIFI-BAS` 场景限定。
