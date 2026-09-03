#include <winsock2.h>
#include <ws2tcpip.h>

#include <iphlpapi.h>

#include "network_adapter_channel.h"

#include <algorithm>
#include <cctype>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "xgiwifi/windows_network_adapters";

std::string Ipv4FromSockaddr(const SOCKADDR* address) {
  if (address == nullptr || address->sa_family != AF_INET) {
    return "";
  }

  const auto* ipv4 = reinterpret_cast<const SOCKADDR_IN*>(address);
  const auto host_order = ntohl(ipv4->sin_addr.s_addr);
  if (host_order == 0 || (host_order & 0xFF000000) == 0x7F000000 ||
      (host_order & 0xFFFF0000) == 0xA9FE0000) {
    return "";
  }

  char buffer[INET_ADDRSTRLEN] = {};
  return InetNtopA(AF_INET, &ipv4->sin_addr, buffer, INET_ADDRSTRLEN) == nullptr
             ? ""
             : buffer;
}

std::string FormatMac(const IP_ADAPTER_ADDRESSES* adapter) {
  if (adapter->PhysicalAddressLength != 6) {
    return "";
  }

  std::ostringstream value;
  value << std::uppercase << std::hex << std::setfill('0');
  for (ULONG index = 0; index < adapter->PhysicalAddressLength; ++index) {
    if (index != 0) {
      value << ':';
    }
    value << std::setw(2)
          << static_cast<int>(adapter->PhysicalAddress[index]);
  }
  return value.str();
}

std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char character) {
                   return static_cast<char>(std::tolower(character));
                 });
  return value;
}

bool IsVirtual(const IP_ADAPTER_ADDRESSES* adapter,
               const std::string& searchable_label) {
  if (adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK ||
      adapter->IfType == IF_TYPE_TUNNEL || adapter->IfType == IF_TYPE_PPP) {
    return true;
  }

  const auto adapter_name =
      adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
  const auto text = Lower(searchable_label + " " + adapter_name);
  for (const auto* marker : {"virtual", "hyper-v", "vmware", "virtualbox",
                             "vethernet", "vpn", "tap", "tun", "wsl",
                             "docker", "loopback"}) {
    if (text.find(marker) != std::string::npos) {
      return true;
    }
  }
  return false;
}

std::string Kind(const IP_ADAPTER_ADDRESSES* adapter) {
  if (adapter->IfType == IF_TYPE_IEEE80211) {
    return "wifi";
  }
  if (adapter->IfType == IF_TYPE_ETHERNET_CSMACD) {
    return "ethernet";
  }
  return "other";
}

flutter::EncodableList ListAdapters() {
  ULONG size = 16 * 1024;
  std::vector<unsigned char> buffer(size);
  auto* addresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  const ULONG flags = GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_ANYCAST |
                      GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;

  ULONG status =
      GetAdaptersAddresses(AF_INET, flags, nullptr, addresses, &size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(size);
    addresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status = GetAdaptersAddresses(AF_INET, flags, nullptr, addresses, &size);
  }
  if (status == ERROR_NO_DATA) {
    return {};
  }
  if (status != NO_ERROR) {
    throw std::runtime_error("GetAdaptersAddresses failed: " +
                             std::to_string(status));
  }

  flutter::EncodableList result;
  for (auto* adapter = addresses; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp) {
      continue;
    }

    std::string ipv4;
    for (auto* address = adapter->FirstUnicastAddress; address != nullptr;
         address = address->Next) {
      if (address->DadState != IpDadStatePreferred ||
          address->ValidLifetime == 0) {
        continue;
      }
      ipv4 = Ipv4FromSockaddr(address->Address.lpSockaddr);
      if (!ipv4.empty()) {
        break;
      }
    }
    if (ipv4.empty()) {
      continue;
    }

    std::string gateway;
    for (auto* value = adapter->FirstGatewayAddress; value != nullptr;
         value = value->Next) {
      gateway = Ipv4FromSockaddr(value->Address.lpSockaddr);
      if (!gateway.empty()) {
        break;
      }
    }

    const auto friendly_name = Utf8FromUtf16(adapter->FriendlyName);
    const auto description = Utf8FromUtf16(adapter->Description);
    const auto label = friendly_name.empty() ? description : friendly_name;
    const std::string adapter_id =
        adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
    if (adapter_id.empty()) {
      continue;
    }

    result.emplace_back(flutter::EncodableMap{
        {flutter::EncodableValue("id"), flutter::EncodableValue(adapter_id)},
        {flutter::EncodableValue("name"), flutter::EncodableValue(label)},
        {flutter::EncodableValue("systemName"),
         flutter::EncodableValue(friendly_name)},
        {flutter::EncodableValue("ipv4"), flutter::EncodableValue(ipv4)},
        {flutter::EncodableValue("macAddress"),
         flutter::EncodableValue(FormatMac(adapter))},
        {flutter::EncodableValue("gatewayIp"),
         flutter::EncodableValue(gateway)},
        {flutter::EncodableValue("kind"),
         flutter::EncodableValue(Kind(adapter))},
        {flutter::EncodableValue("isVirtual"),
         flutter::EncodableValue(
             IsVirtual(adapter, label + " " + description))},
    });
  }
  return result;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateNetworkAdapterChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "listAdapters") {
      result->NotImplemented();
      return;
    }

    try {
      result->Success(flutter::EncodableValue(ListAdapters()));
    } catch (const std::exception& error) {
      result->Error("ADAPTER_ENUMERATION_FAILED", error.what());
    }
  });
  return channel;
}
