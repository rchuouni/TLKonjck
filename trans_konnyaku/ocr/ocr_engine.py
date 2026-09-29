"""
Memory-only OCR Engine using Windows Media OCR (WinRT API via winsdk) with fallback.
No image files or text files are saved to disk.
"""

import io
import re
import asyncio
from PIL import Image

try:
    import winsdk.windows.media.ocr as win_ocr
    import winsdk.windows.graphics.imaging as win_img
    import winsdk.windows.storage.streams as win_streams
    WINSDK_AVAILABLE = True
except ImportError:
    WINSDK_AVAILABLE = False


class OCREngine:
    def __init__(self, lang_tag: str = "ja"):
        self.lang_tag = lang_tag
        self._win_engine = None
        if WINSDK_AVAILABLE:
            self._init_winsdk_engine()

    def _init_winsdk_engine(self):
        try:
            self._win_engine = win_ocr.OcrEngine.try_create_from_user_profile_languages()
        except Exception:
            self._win_engine = None

    def recognize(self, pil_image: Image.Image) -> str:
        """
        インメモリの PIL Image から OCR を実行して正規化された文字列を返す。
        ディスク保存は一切行わない。
        """
        if WINSDK_AVAILABLE and self._win_engine:
            try:
                raw_text = asyncio.run(self._recognize_winsdk_async(pil_image))
                return self._normalize_text(raw_text)
            except Exception:
                pass
        return ""

    async def _recognize_winsdk_async(self, pil_image: Image.Image) -> str:
        buffer = io.BytesIO()
        pil_image.save(buffer, format="PNG")
        png_bytes = buffer.getvalue()

        writer = win_streams.DataWriter()
        writer.write_bytes(list(png_bytes))
        mem_stream = win_streams.InMemoryRandomAccessStream()
        await mem_stream.write_async(writer.detach_buffer())
        mem_stream.seek(0)

        decoder = await win_img.BitmapDecoder.create_async(mem_stream)
        software_bitmap = await decoder.get_software_bitmap_async()

        result = await self._win_engine.recognize_async(software_bitmap)
        return result.text

    def _normalize_text(self, text: str) -> str:
        if not text:
            return ""
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()
