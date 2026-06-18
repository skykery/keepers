"""macOS desktop launcher: Flask server + WKWebView window via pywebview.

Used as the PyInstaller entry point. Dev users can still run `webapp.py` directly for a browser-based session.
"""

import socket
import threading
import time
import urllib.request

import webview

import webapp


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for_server(url: str, timeout: float = 30.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"Server at {url} did not start within {timeout}s")


class NativeApi:
    """Exposed to the page as window.pywebview.api."""

    def __init__(self):
        self.window = None

    def pick_folder(self) -> str:
        if self.window is None:
            return ""
        result = self.window.create_file_dialog(webview.FOLDER_DIALOG, allow_multiple=False)
        if not result:
            return ""
        return result[0] if isinstance(result, (list, tuple)) else result


def main():
    port = _free_port()
    url = f"http://127.0.0.1:{port}"

    def serve():
        webapp.app.run(host="127.0.0.1", port=port, threaded=True, use_reloader=False)

    threading.Thread(target=serve, daemon=True).start()
    _wait_for_server(url)

    api = NativeApi()
    window = webview.create_window(
        "Keepers",
        url,
        width=1400,
        height=900,
        min_size=(900, 600),
        js_api=api,
    )
    api.window = window
    webview.start()


if __name__ == "__main__":
    main()
