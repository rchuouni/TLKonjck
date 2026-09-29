"""
Translation Konjac (翻訳こんにゃく) - Main Entry Point
"""

import sys
from PySide6.QtWidgets import QApplication
from gui.overlay_window import OverlayWindow

def main():
    app = QApplication(sys.argv)
    app.setApplicationName("TranslationKonjac")
    app.setOrganizationName("SecureLocalTools")

    window = OverlayWindow()
    window.show()

    sys.exit(app.exec())

if __name__ == "__main__":
    main()
