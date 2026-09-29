"""
Background QThread Worker for Asynchronous OCR and LLM Translation.
"""

from PySide6.QtCore import QThread, Signal
from PIL import Image
from ocr.ocr_engine import OCREngine
from llm.translator import LocalTranslator

class TranslationWorker(QThread):
    translation_finished = Signal(int, str)
    status_updated = Signal(str)
    error_occurred = Signal(str)

    def __init__(self, image: Image.Image, ocr_engine: OCREngine, translator: LocalTranslator):
        super().__init__()
        self.image = image
        self.ocr_engine = ocr_engine
        self.translator = translator

    def run(self):
        try:
            self.status_updated.emit("文字認識中 (OCR)...")
            ocr_text = self.ocr_engine.recognize(self.image)

            if not ocr_text or not ocr_text.strip():
                self.translation_finished.emit(0, "（認識可能なテキストが見つかりませんでした）")
                return

            self.status_updated.emit(f"ローカルLLMで翻訳中 ({len(ocr_text)} 文字)...")
            translation = self.translator.translate(ocr_text)
            self.translation_finished.emit(len(ocr_text), translation)

        except Exception as e:
            self.error_occurred.emit(f"処理エラー: {str(e)}")
