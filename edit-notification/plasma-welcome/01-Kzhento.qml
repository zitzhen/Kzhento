/*
 *  SPDX-FileCopyrightText: 2021 Felipe Kinoshita <kinofhek@gmail.com>
 *  SPDX-FileCopyrightText: 2022 Nate Graham <nate@kde.org>
 *  SPDX-FileCopyrightText: 2026 ZIT STUDIO
 *
 *  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 *
 *  Kzhento's first page for plasma-welcome, installed over the stock
 *  01-Kubuntu.qml by edit-notification/edit-welcome.sh.
 *
 *  The stock page is not a translation: its heading, its body and both of its
 *  images (the Kubuntu wordmark and a Donate badge) are written into the QML,
 *  and its gettext calls have no catalogue entry to override, because upstream
 *  ships no plasma-welcome .mo for the untranslated source language. Replacing
 *  the file is therefore the only way to change what that page says.
 *
 *  The original is kept next to this one as 01-Kubuntu.qml.zhento-orig so the
 *  stock page can be put back, and so an upgrade of plasma-welcome can be
 *  diffed against it.
 *
 *  The description keeps the i18nc calls: this file is installed at the same
 *  path as the page it replaces, so the translated strings other locales
 *  already have for that domain still apply where they match.
 */

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Qt5Compat.GraphicalEffects

import org.kde.plasma.welcome

GenericPage {
    heading: i18nc("@info:window", "Welcome to K-Zhento | Friendly Computing")
    description: i18nc("@info:usagetip",
    '<p>You are using the K-Zhento Linux distribution, built on Ubuntu and KDE
      Plasma. It is used by people around the world who value:</p>

    <ul>
      <li>The beautiful and intuitive KDE Plasma desktop and KDE apps</li>
      <li>The breadth and compatibility of the full Ubuntu
      archive</li>
      <li>Frequent security updates</li>
      <li>Current, reliable core apps for productivity, office, email,
      graphics, and music</li>
      <li>Hardware and commercial support tuned for K-Zhento</li>
    </ul>

    <p>K-Zhento is free software built on the work of the Ubuntu and KDE
    communities. Contributions from the community keep it moving forward.</p>
    ');

    RowLayout {
        Layout.fillWidth: true;
        anchors {
          left: parent.left
          right: parent.right
        }
        Image {
            id: features
            // Rendered from the Kzhento logo by edit-plymouth/render.py, which
            // is what edit-notification/edit-welcome.sh installs next to this
            // page. A file path rather than an icon name: the page wants the
            // wordmark at a fixed size, not a themed icon.
            source: "/usr/share/plasma/plasma-welcome/extra-pages/kzhento-logo.png"
            mipmap : true
            Layout.topMargin       : 0 - Kirigami.Units.gridUnit
            Layout.leftMargin      : Kirigami.Units.gridUnit * 3
            Layout.alignment       : Qt.AlignLeft + Qt.AlignVCenter
            Layout.preferredHeight : Kirigami.Units.gridUnit * 5
            Layout.preferredWidth  :
                ( this.implicitWidth / this.implicitHeight )
                * (Kirigami.Units.gridUnit * 5)

            HoverHandler {
                id: hoverhandler
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                onTapped: Qt.openUrlExternally("https://zitzhen.cn/")
            }
            QQC2.ToolTip {
                visible: hoverhandler.hovered
                text: i18nc("@action:button", "Visit the K-Zhento website.")
            }

            layer.enabled: true
            layer.effect: DropShadow {
                transparentBorder: true
                horizontalOffset: 0
                verticalOffset: 0
                radius: 15
                samples: 20
                color: Qt.rgba(0, 0, 0, 0.2)
            }
        }

        // The stock page fills the right-hand side with a Donate badge. There is
        // no K-Zhento donation campaign to point at, so the space is left empty
        // rather than filled with a link that would take the user somewhere
        // wrong.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
    }
}
