<div align="center">
    <img width="200" height="200" src="assets/logo.png">
</div>



<div align="center">
    <h1>xGiWifi</h1>
</div>



使用 Flutter 实现的第三方 GiWiFi 客户端，支持 Android、Windows、Linux 等运行平台。登录时可以选择 Android、APad 或 Windows 三种模拟终端。

<br>
<br>
<br>
<br>

## 预览

> 预览图来自旧版本，其中的 iPad 选项在当前版本中已更新为 APad。


<div align="center">
    <table>
        <tr>
            <td align="center">
                <b>Android</b><br><br>
                <img src="./assets/andriod.jpg" width="216" height="480" />
            </td>
            <td align="center">
                <b>Windows</b><br><br>
                <img src="./assets/windows.png" width="631" height="352" />
            </td>
        </tr>
    </table>
</div>

## 功能

- 支持模拟登陆

- 支持换绑

## 模拟终端与协议

运行客户端的平台与登录时选择的模拟终端是两个不同概念。当前终端列表固定为：

| 模拟终端 | 认证协议 | 关键终端字段 |
| --- | --- | --- |
| Android | APK App Portal | `btype=1`、`staType=phone` |
| APad | APK App Portal | `btype=2`、`staType=pad` |
| Windows | Web Portal | 保留原 Web 登录页、Windows User-Agent 和 `device_*` 字段 |

Android/APad 会完整使用 APK 的 Wi-Fi Portal 认证链：

1. 请求 `http://115.159.209.137`，关闭自动重定向并从 `Location` 或响应正文识别 `/gportal/web/login` Portal 地址；
2. 从当前物理网络接口读取 IPv4 和 MAC，不读取 Web 登录页隐藏字段；
3. 先向 `:8080/wocloud_v2/appUser/appLogin.bin` 发送 APK 第一层账号认证（Android 使用 `service_type=1`、`staType=phone`，APad 使用 `service_type=1`、`staType=pad`）；
4. 账号层成功后请求 `/gportal/app/queryAuthState`；
5. 未认证时请求 `/gportal/app/authLogin`；
6. 发生设备冲突时请求 `/gportal/app/reBindMac`，等待 4 秒后重新探测网络身份和认证状态，再重试一次登录。

App 账号层和 App Portal 使用 APK 的 MD5 + AES-128-ECB 数据格式，以及稳定持久化的 `appUuid`。账号层默认使用 APK 的 `service_type=1`，可通过 `fallbackServiceTypes` 配置部署需要的回退类别。Android 构建会使用设备真实的 `MANUFACTURER,MODEL,SDK,RELEASE` 生成 `staModel`；Linux 桌面端模拟 Android/APad 时使用对应的内置终端模型。Windows 继续使用原有 Web Portal 登录页、PHP 会话、AES-CBC 和换绑时序，不复用 App Portal 请求。

## 下载

可以通过右侧release进行下载或拉取代码到本地进行编译

## 注意

- 仅对山东科技大学GiWifi测试！

- 程序不会自动检查所连WiFi是否为GiWiFi，也不会检查当前究竟真的是否使用WiFi上网！

## 参考

查看另一个使用shell模拟登录的项目：[Giwifi_autoLogin](https://github.com/Mhenwa/Giwifi_autoLogin)

## 声明

仅供学习交流，严禁用于商业用途，请于24小时内删除！
