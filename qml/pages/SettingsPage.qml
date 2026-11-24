import QtQuick 2.0
import Sailfish.Silica 1.0

Page {
    id: page

    property string serverInput: ""
    property string tokenInput: ""
    property string testResult: ""
    property bool testOk: false
    property bool testing: false

    Component.onCompleted: {
        page.serverInput = client.serverUrl()
        page.tokenInput = client.token()
    }

    Connections {
        target: client

        onHealthResult: {
            page.testing = false
            if (ok) {
                var data = JSON.parse(json)
                page.testOk = true
                page.testResult = (data.version || "bridge") + " · " + (data.projects || 0) + " " + qsTr("projects reachable")
            } else {
                page.testOk = false
                page.testResult = error
            }
        }
    }

    SilicaFlickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: header.height + col.implicitHeight + Theme.paddingLarge

        // SilicaFlickable (Flickable) has NO `header` property — assigning
        // one is a hard QML error ("Cannot assign to non-existent property
        // header") that aborts page loading ("Could not load page").
        // Official Silica pattern (see Silica's own ColorPickerPage.qml):
        // the header is a plain child item, the body anchors below it, and
        // contentHeight = header.height + body.
        // (Only SilicaListView/ListView has a real `header` property.)
        PageHeader {
            id: header
            title: qsTr("Settings")
            IconButton {
                icon.source: "image://theme/icon-m-back"
                onClicked: pageStack.pop()
            }
        }

        Column {
            id: col
            anchors {
                top: header.bottom
                topMargin: Theme.paddingMedium
                left: parent.left
                leftMargin: Theme.horizontalPageMargin
                right: parent.right
                rightMargin: Theme.horizontalPageMargin
            }
            width: parent.width - 2 * Theme.horizontalPageMargin
            spacing: Theme.paddingMedium

            Label {
                text: qsTr("Bridge server")
                color: Theme.secondaryColor
            }
            TextField {
                text: page.serverInput
                onTextChanged: page.serverInput = text
                // NOTE: no inputMethodHints here — on SFOS 5.x (Qt 5.6) the QML
                // `Qt` object only exposes Qt.ImhNone / Qt.ImhHiddenText; any
                // other Qt.Imh* value is undefined (non-fatal warning, lost hint).
            }

            Label {
                text: qsTr("Token")
                color: Theme.secondaryColor
            }
            TextField {
                text: page.tokenInput
                onTextChanged: page.tokenInput = text
                // Mask the token. SFOS 5.x (Qt 5.6): use echoMode (the Qt 5.14+
                // 'password' property does not exist on this stack).
                echoMode: TextInput.Password
            }

            Button {
                text: qsTr("Save")
                onClicked: {
                    client.setServerUrl(page.serverInput)
                    client.setToken(page.tokenInput)
                }
            }

            Button {
                text: page.testing ? qsTr("Testing…") : qsTr("Test connection")
                enabled: !page.testing
                onClicked: {
                    client.setServerUrl(page.serverInput)
                    client.setToken(page.tokenInput)
                    page.testing = true
                    page.testResult = ""
                    client.testConnection()
                }
            }

            Label {
                text: page.testResult
                visible: page.testResult !== ""
                wrapMode: Text.Wrap
                width: parent.width
                color: page.testOk ? Theme.highlightColor : Theme.errorColor
            }

            Label {
                text: qsTr("The bridge runs on the machine where Bionic runs (default port 8443), e.g. its LAN or Tailscale IP: http://<bridge-host>:8443")
                color: Theme.secondaryColor
                wrapMode: Text.Wrap
                width: parent.width
            }
        }
    }
}
