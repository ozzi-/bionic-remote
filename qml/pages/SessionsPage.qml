import QtQuick 2.0
import Sailfish.Silica 1.0

Page {
    id: page

    property string projectId: ""
    property string projectName: ""
    property bool loading: true
    property string errorText: ""

    ListModel { id: sessionModel }

    function refresh() {
        client.fetchSessions(page.projectId)
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

        onSessionsResult: {
            page.loading = false
            if (!ok) {
                page.errorText = error
                return
            }
            page.errorText = ""
            var data = JSON.parse(json)
            var sessions = data.sessions || []
            sessionModel.clear()
            for (var i = 0; i < sessions.length; i++) {
                var s = sessions[i]
                sessionModel.append({
                    "id": s.id,
                    "name": s.name,
                    "updatedAt": s.updatedAt || 0,
                    "active": !!s.active,
                    "pending": !!s.pendingApproval
                })
            }
        }
    }

    function timeAgo(ms) {
        if (!ms)
            return qsTr("never")
        var diff = new Date().getTime() - ms
        if (diff < 60000)
            return qsTr("just now")
        if (diff < 3600000)
            return Math.floor(diff / 60000) + " " + qsTr("min ago")
        if (diff < 86400000)
            return Math.floor(diff / 3600000) + " " + qsTr("h ago")
        var d = new Date(ms)
        return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate()
    }

    PageHeader {
        title: page.projectName !== "" ? page.projectName : qsTr("Sessions")
        description: page.errorText !== "" ? qsTr("Connection error")
                                           : (page.loading ? qsTr("Connecting…") : qsTr("Connected"))
        IconButton {
            icon.source: "image://theme/icon-m-back"
            onClicked: pageStack.pop()
        }
    }

    ViewPlaceholder {
        visible: sessionModel.count === 0
        text: page.errorText !== "" ? page.errorText
                                   : (page.loading ? qsTr("Loading…") : qsTr("No sessions"))
    }

    SilicaListView {
        id: list
        anchors.fill: parent
        model: sessionModel

        delegate: ListItem {
            width: list.width
            contentHeight: innerCol.implicitHeight + Theme.paddingLarge * 2

            onClicked: pageStack.push(Qt.resolvedUrl("SessionPage.qml"), {
                "projectId": page.projectId,
                "sessionId": model.id
            })

            Column {
                id: innerCol
                anchors {
                    left: parent.left
                    right: parent.right
                    leftMargin: Theme.horizontalPageMargin
                    rightMargin: Theme.horizontalPageMargin
                    verticalCenter: parent.verticalCenter
                }
                spacing: 2

                Row {
                    id: nameRow
                    width: parent.width
                    spacing: Theme.paddingSmall
                    Rectangle {
                        id: stateDot
                        width: 10
                        height: 10
                        radius: 5
                        anchors.verticalCenter: parent.verticalCenter
                        color: model.active ? Theme.highlightColor
                                           : (model.pending ? Theme.secondaryHighlightColor : Theme.secondaryColor)
                    }
                    Label {
                        text: model.name
                        elide: Text.ElideRight
                        width: parent.width - stateDot.width - parent.spacing
                    }
                }
                Label {
                    text: (model.pending ? qsTr("awaiting approval · ") : "") + page.timeAgo(model.updatedAt)
                    color: model.pending ? Theme.highlightColor : Theme.secondaryColor
                    elide: Text.ElideRight
                }
            }
        }
    }
}
