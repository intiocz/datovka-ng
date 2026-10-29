#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// The last window position and size, kept in the registry so they survive
// restarts and updates.
constexpr wchar_t kPlacementKey[] = L"Software\\Datovka NG";
constexpr wchar_t kPlacementValue[] = L"WindowPlacement";

}  // namespace

void SaveWindowPlacement(HWND hwnd) {
  WINDOWPLACEMENT wp{sizeof(wp)};
  if (!::GetWindowPlacement(hwnd, &wp)) {
    return;
  }
  ::RegSetKeyValueW(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue,
                    REG_BINARY, &wp, sizeof(wp));
}

void RestoreWindowPlacement(HWND hwnd) {
  WINDOWPLACEMENT wp{};
  DWORD size = sizeof(wp);
  if (::RegGetValueW(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue,
                     RRF_RT_REG_BINARY, nullptr, &wp, &size) != ERROR_SUCCESS ||
      size != sizeof(wp) || wp.length != sizeof(wp)) {
    return;
  }
  // Only the position: the window is shown once Flutter draws its first frame.
  wp.showCmd = SW_HIDE;
  wp.flags = 0;
  ::SetWindowPlacement(hwnd, &wp);
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_CLOSE:
      SaveWindowPlacement(hwnd);
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
