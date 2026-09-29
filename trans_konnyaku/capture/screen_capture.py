"""
Memory-only Screen Capture Module using mss.
Captures designated window rectangular region without writing to disk.
"""

from PIL import Image
import mss

class ScreenCapture:
    def __init__(self):
        self._sct = mss.mss()

    def capture_region(self, x: int, y: int, width: int, height: int) -> Image.Image:
        """
        指定された矩形領域の画面をキャプチャし、ディスクに一切保存せず
        インメモリの PIL Image として返す。
        """
        if width <= 0 or height <= 0:
            raise ValueError(f"無効なキャプチャ領域サイズ: width={width}, height={height}")

        monitor = {
            "left": int(x),
            "top": int(y),
            "width": int(width),
            "height": int(height),
        }

        sct_img = self._sct.grab(monitor)
        img = Image.frombytes("RGB", sct_img.size, sct_img.bgra, "raw", "BGRX")
        return img
