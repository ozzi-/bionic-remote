import QtQuick 2.0
import Sailfish.Silica 1.0

CoverBackground {

    Connections {
        target: client

        onProjectsResult: {
            if (ok) {
                var data = JSON.parse(json)
                var active = 0
                var projects = data.projects || []
                for (var i = 0; i < projects.length; i++) {
                    if (projects[i].active)
                        active++
                }
                placeholder.text = active > 0 ? qsTr("%1 active").arg(active) : qsTr("Idle")
            } else {
                placeholder.text = qsTr("No connection")
            }
        }
    }

    CoverPlaceholder {
        id: placeholder
        text: qsTr("Waiting…")
        icon.source: "/usr/share/icons/hicolor/86x86/apps/harbour-bionic-remote.png"
    }
}
