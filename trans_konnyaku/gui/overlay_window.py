"""
Overlay Window UI for Translation Konjac.
"""

import time
from PySide6.QtCore import Qt, QPoint
from PySide6.QtGui import QColor, QPainter, QPen, QBrush, QCursor, QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QPushButton,
    QLabel,
    QTextEdit,
    QApplication,
)

from capture.screen_capture import ScreenCapture
from ocr.ocr_engine import OCREngine
from llm.translator import LocalTranslator
from gui.worker import TranslationWorker


class OverlayWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.SubWindow
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)

        self.resize(540, 340)
        self.setMinimumSize(260, 160)

        self._drag_pos: QPoint | None = None
        self._resizing = False
        self._resize_edge = None
        self._border_width = 8
        self._is_processing = False

        self.screen_capture = ScreenCapture()
        self.ocr_engine = OCREngine()
        self.translator = LocalTranslator()
        self.worker: TranslationWorker | None = None

        self.setMouseTracking(True)
        self.init_ui()

    def init_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(12, 12, 12, 12)
        main_layout.setSpacing(6)

        header_layout = QHBoxLayout()
        header_layout.setSpacing(8)

        self.title_label = QLabel("✨ 翻訳こんにゃく (Local Secure)")
        self.title_label.setStyleSheet("color: #FFFFFF; font-weight: bold; font-size: 12px;")
        header_layout.addWidget(self.title_label)

        header_layout.addStretch()

        self.btn_translate = QPushButton("🔍 翻訳 (Ctrl+T)")
        self.btn_translate.setStyleSheet(
            """
            QPushButton {
                background-color: #2E7D32;
                color: white;
                border: 1px solid #4CAF50;
                border-radius: 4px;
                padding: 4px 14px;
                font-weight: bold;
            }
            QPushButton:hover { background-color: #388E3C; }
            QPushButton:pressed { background-color: #1B5E20; }
            QPushButton:disabled { background-color: #555555; color: #888888; border-color: #666666; }
            """
        )
        self.btn_translate.clicked.connect(self.trigger_translation)
        header_layout.addWidget(self.btn_translate)

        self.btn_close = QPushButton("✕")
        self.btn_close.setFixedSize(24, 24)
        self.btn_close.setStyleSheet("background-color: #C62828; color: white; border-radius: 4px;")
        self.btn_close.clicked.connect(self.close)
        header_layout.addWidget(self.btn_close)

        main_layout.addLayout(header_layout)

        self.text_display = QTextEdit()
        self.text_display.setReadOnly(True)
        self.text_display.setPlaceholderText("このウィンドウを翻訳したい領域に重ねて「翻訳」を押してください。")
        self.text_display.setStyleSheet(
            """
            QTextEdit {
                background-color: rgba(18, 22, 32, 195);
                color: #FFFFFF;
                border: 1px solid rgba(0, 210, 255, 120);
                border-radius: 6px;
                font-family: 'Segoe UI', 'Yu Gothic UI', Meiryo, sans-serif;
                font-size: 13px;
                line-height: 1.5;
                padding: 8px;
            }
            """
        )
        main_layout.addWidget(self.text_display)

        self.status_label = QLabel("待機中: ドラッグで移動、端でリサイズ")
        self.status_label.setStyleSheet("color: #D0D0D0; font-size: 11px;")
        main_layout.addWidget(self.status_label)

        shortcut = QShortcut(QKeySequence("Ctrl+T"), self)
        shortcut.activated.connect(self.trigger_translation)

    def trigger_translation(self):
        if self._is_processing:
            return

        self._is_processing = True
        self.btn_translate.setEnabled(False)
        self.status_label.setText("画面キャプチャ準備中...")

        geo = self.geometry()
        x, y, w, h = geo.x(), geo.y(), geo.width(), geo.height()

        # ウィンドウ自体の写り込みを防ぐため非表示化
        self.hide()
        QApplication.processEvents()
        time.sleep(0.06)

        try:
            captured_image = self.screen_capture.capture_region(x, y, w, h)
        except Exception as e:
            self.show()
            self.status_label.setText(f"キャプチャエラー: {str(e)}")
            self.btn_translate.setEnabled(True)
            self._is_processing = False
            return

        self.show()
        QApplication.processEvents()

        self.status_label.setText("処理開始...")
        self.worker = TranslationWorker(captured_image, self.ocr_engine, self.translator)
        self.worker.status_updated.connect(self.on_status_updated)
        self.worker.translation_finished.connect(self.on_translation_finished)
        self.worker.error_occurred.connect(self.on_error_occurred)
        self.worker.start()

    def on_status_updated(self, status: str):
        self.status_label.setText(status)

    def on_translation_finished(self, ocr_length: int, translation: str):
        self.text_display.setPlainText(translation)
        self.status_label.setText(f"完了 (認識文字数: {ocr_length})")
        self.btn_translate.setEnabled(True)
        self._is_processing = False

    def on_error_occurred(self, err_msg: str):
        self.text_display.setPlainText(f"【処理失敗】\n{err_msg}")
        self.status_label.setText("エラーが発生しました")
        self.btn_translate.setEnabled(True)
        self._is_processing = False

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setBrush(QBrush(QColor(15, 20, 30, 95)))
        pen = QPen(QColor(0, 210, 255, 220))
        pen.setWidth(2)
        painter.setPen(pen)
        painter.drawRoundedRect(self.rect().adjusted(1, 1, -2, -2), 8, 8)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            margin = self._border_width
            rect = self.rect()
            pos = event.position().toPoint()
            on_left = pos.x() <= margin
            on_right = pos.x() >= rect.width() - margin
            on_top = pos.y() <= margin
            on_bottom = pos.y() >= rect.height() - margin

            if on_left or on_right or on_top or on_bottom:
                self._resizing = True
                self._resize_edge = (on_left, on_right, on_top, on_bottom)
                self._drag_pos = event.globalPosition().toPoint()
            else:
                self._drag_pos = event.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, event):
        pos = event.position().toPoint()
        margin = self._border_width
        rect = self.rect()

        if self._resizing and self._resize_edge:
            cur_global = event.globalPosition().toPoint()
            geo = self.geometry()
            on_left, on_right, on_top, on_bottom = self._resize_edge
            if on_right: geo.setRight(cur_global.x())
            elif on_left: geo.setLeft(cur_global.x())
            if on_bottom: geo.setBottom(cur_global.y())
            elif on_top: geo.setTop(cur_global.y())
            if geo.width() >= self.minimumWidth() and geo.height() >= self.minimumHeight():
                self.setGeometry(geo)
            return

        if self._drag_pos and not self._resizing:
            self.move(event.globalPosition().toPoint() - self._drag_pos)
            return

        on_left = pos.x() <= margin
        on_right = pos.x() >= rect.width() - margin
        on_top = pos.y() <= margin
        on_bottom = pos.y() >= rect.height() - margin
        if (on_left and on_top) or (on_right and on_bottom):
            self.setCursor(QCursor(Qt.CursorShape.SizeFDiagCursor))
        elif (on_right and on_top) or (on_left and on_bottom):
            self.setCursor(QCursor(Qt.CursorShape.SizeBDiagCursor))
        elif on_left or on_right:
            self.setCursor(QCursor(Qt.CursorShape.SizeHorCursor))
        elif on_top or on_bottom:
            self.setCursor(QCursor(Qt.CursorShape.SizeVerCursor))
        else:
            self.setCursor(QCursor(Qt.CursorShape.ArrowCursor))

    def mouseReleaseEvent(self, event):
        self._drag_pos = None
        self._resizing = False
        self._resize_edge = None
        self.setCursor(QCursor(Qt.CursorShape.ArrowCursor))
