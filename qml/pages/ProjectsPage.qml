import QtQuick 2.0
import Sailfish.Silica 1.0

Page {
    id: page

    property bool loading: true
    property string connectionError: ""

    ListModel { id: projectModel }

    function refresh() {
        page.loading = true
        client.fetchProjects()
    }

    Component.onCompleted: refresh()

    Timer {
        interval: 5000
        repeat: true
        running: true
        onTriggered: client.fetchProjects()
    }

    Connections {
        target: client

        onProjectsResult: {
            page.loading = false
            if (!ok) {
                page.connectionError = error
                return
            }
            page.connectionError = ""
            var data = JSON.parse(json)
            var projects = data.projects || []
            projects.sort(function (a, b) {
                var av = a.lastActivity || 0
                var bv = b.lastActivity || 0
                return bv === av ? 0 : (bv > av ? 1 : -1)
            })
            projectModel.clear()
            for (var i = 0; i < projects.length; i++) {
                var p = projects[i]
                projectModel.append({
                    "id": p.id,
                    "name": p.name,
                    "sessions": p.sessionCount || 0,
                    "active": !!p.active,
                    "lastActivity": p.lastActivity || 0
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
        title: qsTr("Projects")
        description: page.connectionError !== "" ? qsTr("Connection error")
                                                 : (page.loading ? qsTr("Connecting…") : qsTr("Connected"))
        MenuItem {
            text: qsTr("Settings")
            onClicked: pageStack.push(Qt.resolvedUrl("SettingsPage.qml"))
        }
    }

    BusyIndicator {
        anchors.centerIn: parent
        running: page.loading && projectModel.count === 0
    }

    ViewPlaceholder {
        visible: projectModel.count === 0 && !page.loading
        text: page.connectionError !== "" ? page.connectionError : qsTr("No projects found")
    }

    SilicaListView {
        id: list
        anchors.fill: parent
        model: projectModel

        PullDownMenu {
            MenuItem {
                text: qsTr("Refresh")
                onClicked: refresh()
            }
            MenuItem {
                text: qsTr("Settings")
                onClicked: pageStack.push(Qt.resolvedUrl("SettingsPage.qml"))
            }
        }

        delegate: ListItem {
            width: list.width
            contentHeight: innerCol.implicitHeight + Theme.paddingLarge * 2

            onClicked: pageStack.push(Qt.resolvedUrl("SessionsPage.qml"), {
                "projectId": model.id,
                "projectName": model.name
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
                        id: activeDot
                        width: 10
                        height: 10
                        radius: 5
                        anchors.verticalCenter: parent.verticalCenter
                        color: model.active ? Theme.highlightColor : Theme.secondaryColor
                    }
                    Label {
                        text: model.name
                        elide: Text.ElideRight
                        width: parent.width - activeDot.width - parent.spacing
                    }
                }
                Label {
                    text: (model.sessions + " " + qsTr("sessions") + " · " + page.timeAgo(model.lastActivity))
                    color: Theme.secondaryColor
                    elide: Text.ElideRight
                }
            }
        }
    }
}
