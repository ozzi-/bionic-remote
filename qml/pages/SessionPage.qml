import QtQuick 2.0
import Sailfish.Silica 1.0

Page {
    id: page

    property string projectId: ""
    property string sessionId: ""

    property string sessionName: ""
    property bool sessionActive: false
    property bool loading: true
    property string errorText: ""

    property bool hasPending: false
    property string approvalTitle: ""
    property string approvalDesc: ""

    ListModel { id: entryModel }

    function refresh() {
        client.fetchTranscript(page.projectId, page.sessionId, 100)
    }

    Component.onCompleted: refresh()

    Timer {
        interval: 4000
        repeat: true
        running: true
        onTriggered: refresh()
    }

    Connections {
        target: client

        onTranscriptResult: {
            page.loading = false
            if (!ok) {
                page.errorText = error
                return
            }
            page.errorText = ""
            var data = JSON.parse(json)
            if (data.session) {
                page.sessionName = data.session.name || ""
                page.sessionActive = !!data.session.active
            }
            var ap = data.pendingApproval
            page.hasPending = !!ap
            if (ap) {
                page.approvalTitle = ap.title || ""
                page.approvalDesc = ap.description || ""
            } else {
                page.approvalTitle = ""
                page.approvalDesc = ""
            }
            var entries = data.entries || []
            entryModel.clear()
            for (var i = 0; i < entries.length; i++) {
                var e = entries[i]
                entryModel.append({
                    "kind": e.kind || "",
                    "text": e.text || "",
                    "tool": e.tool || ""
                })
            }
        }
    }

    PageHeader {
        title: page.sessionName !== "" ? page.sessionName : qsTr("Session")
        description: page.errorText !== "" ? qsTr("Connection error")
                  : (page.hasPending ? qsTr("Awaiting approval")
                  : (page.sessionActive ? qsTr("Agent active")
                  : (page.loading ? qsTr("Connecting…") : qsTr("Idle"))))
        IconButton {
            icon.source: "image://theme/icon-m-back"
            onClicked: pageStack.pop()
        }
    }

    ViewPlaceholder {
        visible: entryModel.count === 0
        text: page.errorText !== "" ? page.errorText
                                   : (page.loading ? qsTr("Loading…") : qsTr("Empty session"))
    }

    SilicaListView {
        id: list
        anchors.fill: parent
        model: entryModel

        header: Item {
            id: banner
            width: list.width
            height: bannerCol.implicitHeight + Theme.paddingMedium
            visible: page.hasPending

            Rectangle {
                anchors.fill: parent
                color: Theme.highlightBackgroundColor
                border.color: Theme.highlightColor
                border.width: 1
            }

            Column {
                id: bannerCol
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Theme.horizontalPageMargin
                    rightMargin: Theme.horizontalPageMargin
                }
                spacing: 2

                Label {
                    text: qsTr("Approval pending: ") + page.approvalTitle
                    elide: Text.ElideRight
                    width: parent.width
                }
                Label {
                    text: page.approvalDesc
                    visible: page.approvalDesc !== ""
                    wrapMode: Text.Wrap
                    width: parent.width
                    color: Theme.secondaryColor
                }
                Label {
                    text: qsTr("Approve or deny it in the Bionic desktop app")
                    color: Theme.secondaryColor
                    elide: Text.ElideRight
                    width: parent.width
                }
            }
        }

        delegate: ListItem {
            width: list.width
            contentHeight: entryCol.implicitHeight + Theme.paddingLarge * 2

            Column {
                id: entryCol
                anchors {
                    left: parent.left
                    right: parent.right
                    leftMargin: Theme.horizontalPageMargin
                    rightMargin: Theme.horizontalPageMargin
                    verticalCenter: parent.verticalCenter
                }
                spacing: 2

                Label {
                    id: roleLabel
                    text: roleText()
                    visible: roleLabel.text !== ""
                    elide: Text.ElideRight
                    width: parent.width
                    color: roleColor()
                }

                Label {
                    text: model.text
                    visible: model.text !== ""
                    wrapMode: Text.Wrap
                    width: parent.width
                    color: (model.kind === "tool_result" || model.kind === "system")
                           ? Theme.secondaryColor : Theme.primaryColor
                }

                function roleText() {
                    if (model.kind === "user")
                        return qsTr("You")
                    if (model.kind === "assistant")
                        return qsTr("Bionic")
                    if (model.kind === "tool_call")
                        return qsTr("Tool") + (model.tool !== "" ? ": " + model.tool : "")
                    if (model.kind === "tool_result")
                        return qsTr("Result")
                    if (model.kind === "approval")
                        return qsTr("Approval")
                    return ""
                }

                function roleColor() {
                    if (model.kind === "user")
                        return Theme.secondaryHighlightColor
                    if (model.kind === "assistant" || model.kind === "approval")
                        return Theme.highlightColor
                    return Theme.secondaryColor
                }
            }
        }
    }
}
