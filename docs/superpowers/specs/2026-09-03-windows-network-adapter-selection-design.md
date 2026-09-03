# Windows network adapter selection

## Goal

Allow Windows users to explicitly choose the network adapter used for GiWiFi authentication, primarily to prevent an automatically selected virtual adapter from supplying the wrong IP or identity. Keep Android behavior unchanged.

## User experience

- The login card shows a `网络适配器` selector on Windows only.
- The first option is `自动选择`.
- Active physical Ethernet and Wi-Fi adapters are listed before virtual adapters.
- Each option shows its friendly name, network type, and current IPv4 address. Virtual adapters are visibly marked `虚拟`.
- The selected adapter is persisted by a stable Windows adapter identifier rather than by its DHCP address.
- On startup and before each login, the adapter list is refreshed. If the persisted adapter no longer exists or has no usable IPv4 address, the app selects `自动选择` and displays a concise notice.
- The selector is disabled while authentication is running.
- Authentication logs identify the adapter and IPv4 address actually used.

The login card also permanently displays this notice:

> 有线网络仅支持 Windows（电脑端）认证；Wi-Fi 可选择 Android、APad 或 Windows 终端认证。

If an Ethernet adapter is explicitly selected while the terminal profile is Android or APad, login is stopped before any network request and the user is told to select Windows. Wi-Fi accepts all three terminal profiles. Automatic selection keeps the existing profile choice because the transport type is not known until resolution.

## Architecture

### Adapter discovery

The Windows runner exposes a method channel backed by the Windows IP Helper API (`GetAdaptersAddresses`). It returns active IPv4-capable adapters with:

- stable adapter identifier;
- friendly name and system adapter name;
- IPv4 address;
- MAC address when available;
- IPv4 gateway when available;
- adapter type (`ethernet`, `wifi`, or `other`);
- virtual-adapter classification.

Virtual classification uses Windows adapter metadata first and conservative name/description matching second. Virtual adapters remain selectable; they are only marked and sorted after physical adapters.

Dart owns a small immutable adapter model and a discovery service. Non-Windows platforms return no selectable adapters and retain their existing identity-resolution behavior.

### Persisted settings

`AppSettings` gains an optional Windows adapter identifier. `AppSettingsStore` persists it in shared preferences. An empty identifier means `自动选择`.

The saved identifier is never silently reassigned to another adapter. A missing saved adapter is cleared and persisted as automatic selection after the user is notified.

### Authentication routing

Before login, the selected adapter is refreshed and converted to a network binding containing its IPv4, MAC, gateway, name, and type.

For an explicit selection:

1. App Portal identity fields use the selected adapter's IP, MAC, and gateway.
2. Windows HTTP sockets bind to the selected IPv4 address, so traffic originates from the chosen adapter.
3. Failure to bind or loss of the selected address stops login with an actionable error. It does not silently use another adapter.

For `自动选择`, the current resolver remains the fallback, with physical adapters preferred over virtual ones. Existing Android native Wi-Fi identity resolution is unchanged.

The binding is passed into `GiWifiClient.login` as per-login input. Tests can inject adapter discovery and HTTP client creation without requiring live network access.

## Error handling

- No active IPv4 adapters: show `未发现可用的 IPv4 网络适配器` and keep login disabled until refresh succeeds.
- Saved adapter missing: revert to automatic selection and show one notice.
- Selected adapter loses IPv4 before login: stop and ask the user to refresh or choose another adapter.
- Source-address socket binding fails: surface the adapter name and binding error in the login log.
- Windows native enumeration fails: retain the automatic option, show the enumeration error, and allow the existing automatic resolver to be used.

## Testing

- Unit tests cover adapter ordering, virtual marking, stable-ID matching, and missing-adapter fallback.
- Settings tests cover saving, loading, and clearing the adapter identifier.
- Client tests verify that an explicit binding is used for App Portal identity and HTTP client creation, and that invalid bindings fail before requests are sent.
- Widget tests verify the Windows-only selector, persisted selection, refresh/error states, the usage notice, and Ethernet/profile validation.
- Existing Flutter tests, static analysis, Windows release build, and Android tests/build remain green; Android behavior must not change.

## Scope

This change does not add adapter selection on Android, Linux, macOS, iOS, or web. It does not modify GiWiFi protocol payloads beyond sourcing existing network identity fields from the selected Windows adapter.
