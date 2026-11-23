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
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight + Theme.paddingLarge

        // SFOS 5.1 layout contract: PageHeader MUST live in the view header.
        // As a plain Page child it floats top-right WITHOUT reserving space.
        // (QML-GOTCHAS.md)
        header: PageHeader {
            title: qsTr("Settings")
            IconButton {
                icon.source: "image://theme/icon-m-back"
                onClicked: pageStack.pop()
            }
        }

        Column {
            id: col
            x: Theme.horizontalPageMargin
            width: parent.width - 2 * Theme.horizontalPageMargin
            y: Theme.paddingMedium
            spacing: Theme.paddingMedium

            Label {
                text: qsTr("Bridge server")
                color: Theme.secondaryColor
            }
            TextField {
                text: page.serverInput
                onTextChanged: page.serverInput = text
                inputMethodHints: Qt.ImhUrlText
            }

            Label {
                text: qsTr("Token")
                color: Theme.secondaryColor
            }
            TextField {
                text: page.tokenInput
                onTextChanged: page.tokenInput = text
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
                text: qsTr("The bridge runs on the Arch machine as the bionic-remote user service (default http://192.168.178.32:8443).")
                color: Theme.secondaryColor
                wrapMode: Text.Wrap
                width: parent.width
            }
        }
    }
}
