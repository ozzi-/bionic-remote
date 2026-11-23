import QtQuick 2.0
import Sailfish.Silica 1.0

Page {
    id: page

    // ---------------- data contract ----------------
    // The bridge emits entries with kind: user | assistant | reasoning |
    // tool_call | tool_result | system | approval. This page groups them into
    // "views": user/assistant bubbles, "thinking" cards (reasoning),
    // "toolgroup" cards (consecutive tool_call + tool_result runs) and
    // "line" (system / approval).

    property string projectId: ""
    property string sessionId: ""

    property string sessionName: ""
    property bool sessionActive: false
    property bool loading: true
    property string errorText: ""

    property bool hasPending: false
    property string approvalTitle: ""
    property string approvalDesc: ""

    // Expanded state survives model rebuilds, keyed by entry signature.
    property var expandedSigs: ({})

    ListModel { id: entryModel }

    // ---------------- theme ----------------
    // SOLID per-theme palette (neutral grays, Bionic-style) — verified on
    // the emulator: solid colors composite exactly as written, but
    // semi-transparent (Theme.rgba) colors composite DARKER than their
    // nominal alpha on this stack, so alpha-tinted surfaces are not
    // predictable. Key the palette on the system theme:
    //   Theme.colorScheme === 0  →  LightOnDark  (dark system)
    //   Theme.colorScheme === 1  →  DarkOnLight  (light system)
    // (0 = LightOnDark is the raw enum value; Theme.LightOnDark also works
    // — stock ApplicationWindow.qml does exactly this comparison.)
    //
    // GOTCHA (learned the hard way, cost a phone round-trip): the first
    // attempt used `Theme.colorScheme === Theme.Dark` — that constant does
    // NOT exist, so the comparison was always false and the page silently
    // rendered the light palette in every theme. The working constants are
    // LightOnDark / DarkOnLight only.
    readonly property bool darkMode: Theme.colorScheme === 0
    property color bgColor: darkMode ? "#18181B" : "#FCFCFC"
    property color fgColor: darkMode ? "#F5F5F6" : "#18181B"
    property color mutedColor: darkMode ? "#A1A1AA" : "#52525B"
    property color userBubbleColor: darkMode ? "#2E2E33" : "#E4E4E6"
    property color assistBubbleColor: darkMode ? "#202024" : "#F0F0F1"
    property color cardBgColor: darkMode ? "#1F1F23" : "#F5F5F6"
    property color cardBorderColor: darkMode ? "#3A3A41" : "#D9D9DE"
    property color brandColor: "#7171E8"

    // ---------------- helpers ----------------

    function setExpanded(sig, value) {
        if (sig === "" || sig === undefined)
            return
        if (value)
            page.expandedSigs[sig] = true
        else
            delete page.expandedSigs[sig]
    }

    function formatToolCalls(calls) {
        var out = ""
        for (var i = 0; i < calls.length; i++) {
            var c = calls[i]
            out += c.tool
            if (c.args && c.args.length > 0)
                out += "\n" + c.args
            if (c.result && c.result.length > 0)
                out += "\n—\n" + c.result
            if (i < calls.length - 1)
                out += "\n\n"
        }
        return out
    }

    function buildItems(entries) {
        var items = []
        var i = 0
        while (i < entries.length) {
            var e = entries[i]
            var kind = e.kind || ""
            if (kind === "tool_call" || kind === "tool_result") {
                var calls = []
                var cur = null
                while (i < entries.length
                       && (entries[i].kind === "tool_call" || entries[i].kind === "tool_result")) {
                    if (entries[i].kind === "tool_call") {
                        cur = { tool: entries[i].tool || "tool",
                                args: entries[i].args || "",
                                result: "" }
                        calls.push(cur)
                    } else {
                        // tool_result (possibly orphaned by window slicing)
                        if (cur) {
                            cur.result = entries[i].text || ""
                        } else {
                            cur = { tool: "result", args: "", result: entries[i].text || "" }
                            calls.push(cur)
                        }
                    }
                    i++
                }
                var first = calls.length > 0 ? calls[0] : null
                items.push({
                    "view": "toolgroup",
                    "count": calls.length,
                    "text": formatToolCalls(calls),
                    "sig": "tg|" + calls.length + "|" + (first ? first.tool : "")
                           + "|" + (first ? String(first.args).slice(0, 32) : "")
                })
                continue
            }
            if (kind === "reasoning") {
                items.push({
                    "view": "thinking",
                    "text": e.text || "",
                    "sig": "th|" + i + "|" + String(e.text || "").slice(0, 32)
                })
                i++
                continue
            }
            if (kind === "user") {
                items.push({ "view": "user", "text": e.text || "" })
                i++
                continue
            }
            if (kind === "assistant") {
                items.push({ "view": "assistant", "text": e.text || "" })
                i++
                continue
            }
            if (kind === "approval") {
                var title = e.title || qsTr("Approval")
                var desc = e.description || ""
                var state = e.answered ? qsTr("answered") : qsTr("pending")
                items.push({ "view": "line",
                             "text": title + (desc !== "" ? " — " + desc : "")
                                    + " (" + state + ")",
                             "highlight": e.answered ? false : true })
                i++
                continue
            }
            items.push({ "view": "line", "text": e.text || "", "highlight": false })
            i++
        }
        return items
    }

    function refresh() {
        client.fetchTranscript(page.projectId, page.sessionId, 150)
    }

    Component.onCompleted: refresh()

    // Soft polling: only while the session is active AND this page is shown.
    Timer {
        id: pollTimer
        interval: 2500
        repeat: true
        running: page.active && page.sessionActive
        onTriggered: page.refresh()
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
            var items = page.buildItems(entries)
            entryModel.clear()
            for (var i = 0; i < items.length; i++) {
                var it = items[i]
                entryModel.append({
                    "view": it.view,
                    "text": it.text || "",
                    "count": it.count || 0,
                    "sig": it.sig || "",
                    "highlight": it.highlight === true,
                    "expanded": (it.sig !== "" && page.expandedSigs[it.sig] === true)
                })
            }
        }
    }

    // ---------------- UI ----------------

    // Chat-body background: solid per-theme color so bubbles and cards sit
    // on a predictable surface regardless of the system wallpaper.
    Rectangle {
        anchors.fill: parent
        color: page.bgColor
    }

    SilicaListView {
        id: list
        anchors.fill: parent
        clip: true
        model: entryModel

        // SFOS 5.1 layout contract: PageHeader MUST live in the list header.
        // As a plain Page child it floats top-right WITHOUT reserving space,
        // so the first entry renders on top of it. (QML-GOTCHAS.md)
        header: Column {
            width: list.width
            spacing: 0

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

            Item {
                id: banner
                width: parent.width
                height: page.hasPending ? bannerCol.implicitHeight + Theme.paddingMedium * 2 : 0
                visible: page.hasPending

            Rectangle {
                anchors.fill: parent
                color: page.darkMode ? "#26262E" : "#ECECF6"
                border.color: page.brandColor
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
                width: parent.width - 2 * Theme.horizontalPageMargin
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
        }

        ViewPlaceholder {
            visible: entryModel.count === 0
            text: page.errorText !== "" ? page.errorText
                                       : (page.loading ? qsTr("Loading…") : qsTr("Empty session"))
        }

        delegate: Item {
            id: delegate
            width: list.width
            height: (model.view === "user" || model.view === "assistant")
                   ? (model.view === "user" ? userBubble.implicitHeight : assistBubble.implicitHeight) + 10
                   : (model.view === "thinking" || model.view === "toolgroup")
                     ? card.implicitHeight + 8
                     : lineItem.implicitHeight + 10

            property real mside: 14

            // ---------- user bubble (right) ----------
            Item {
                id: userBubble
                visible: model.view === "user"
                width: parent.width - 2 * parent.mside
                anchors { left: parent.left; top: parent.top; leftMargin: parent.mside }
                implicitHeight: uText.implicitHeight + 24
                height: implicitHeight

                Rectangle {
                    anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                    width: Math.min(uText.width + 28, parent.width)
                    radius: 18
                    color: page.userBubbleColor
                }
                Text {
                    id: uText
                    anchors { right: parent.right; rightMargin: 14; top: parent.top; topMargin: 12 }
                    width: Math.min(uText.implicitWidth, parent.width - 28)
                    text: model.text
                    color: page.fgColor
                    font.pixelSize: Theme.fontSizeLarge
                    wrapMode: Text.Wrap
                }
            }

            // ---------- assistant bubble (left) ----------
            Item {
                id: assistBubble
                visible: model.view === "assistant"
                width: parent.width - 2 * parent.mside
                anchors { left: parent.left; top: parent.top; leftMargin: parent.mside }
                implicitHeight: aText.implicitHeight + 24
                height: implicitHeight

                Rectangle {
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width: Math.min(aText.width + 28, parent.width)
                    radius: 18
                    color: page.assistBubbleColor
                }
                Text {
                    id: aText
                    anchors { left: parent.left; leftMargin: 14; top: parent.top; topMargin: 12 }
                    width: Math.min(aText.implicitWidth, parent.width - 28)
                    text: model.text
                    color: page.fgColor
                    font.pixelSize: Theme.fontSizeLarge
                    wrapMode: Text.Wrap
                }
            }

            // ---------- thinking / toolgroup card ----------
            Item {
                id: card
                visible: model.view === "thinking" || model.view === "toolgroup"
                width: parent.width - 2 * parent.mside
                anchors { left: parent.left; top: parent.top; leftMargin: parent.mside }
                property int cardPad: 10
                property bool cardExpanded: model.expanded === true
                implicitHeight: headerRow.implicitHeight + cardPad * 2
                               + (cardExpanded ? (cardContent.implicitHeight + cardPad
                                                  + collapseRow.implicitHeight + cardPad) : 0)
                height: implicitHeight

                Rectangle {
                    anchors.fill: parent
                    radius: 10
                    color: page.cardBgColor
                    border.color: page.cardBorderColor
                    border.width: 1
                }

                Item {
                    id: headerRow
                    anchors {
                        left: parent.left
                        top: parent.top
                        leftMargin: parent.cardPad
                        topMargin: parent.cardPad
                    }
                    width: parent.width - 2 * parent.cardPad
                    implicitHeight: headerLabel.implicitHeight + 4
                    height: implicitHeight

                    Label {
                        id: headerLabel
                        anchors.left: parent.left
                        width: parent.width - 28
                        // Qt 5.6: qsTr() returns a QVariant — bare qsTr and string
                        // concatenation are safe, but calling methods on it (or
                        // wrapping in String()) throws and the label renders empty.
                        // Uppercase literals + concatenation = the proven pattern.
                        text: model.view === "thinking"
                             ? qsTr("THINKING")
                             : (model.count === 1 ? qsTr("1 TOOL CALL")
                                                  : model.count + " " + qsTr("TOOL CALLS"))
                        color: page.mutedColor
                        font.pixelSize: Theme.fontSizeSmall
                        font.letterSpacing: 0.03
                        elide: Text.ElideRight
                    }

                    Label {
                        anchors.right: parent.right
                        text: card.cardExpanded ? "▴" : "▾"
                        color: page.mutedColor
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    MouseArea {
                        anchors.fill: parent
                        onPressed: {
                            card.cardExpanded = !card.cardExpanded
                            page.setExpanded(model.sig, card.cardExpanded)
                        }
                    }
                }

                Text {
                    id: cardContent
                    visible: card.cardExpanded && model.text !== ""
                    anchors {
                        left: parent.left
                        top: headerRow.bottom
                        topMargin: parent.cardPad
                        leftMargin: parent.cardPad
                    }
                    width: parent.width - 2 * parent.cardPad
                    text: model.text
                    color: page.mutedColor
                    font.pixelSize: Theme.fontSizeMedium
                    wrapMode: Text.Wrap
                }

                Item {
                    id: collapseRow
                    visible: card.cardExpanded
                    anchors {
                        right: parent.right
                        top: cardContent.visible ? cardContent.bottom : headerRow.bottom
                        topMargin: parent.cardPad
                        rightMargin: parent.cardPad
                    }
                    implicitHeight: collapseLabel.implicitHeight
                    height: implicitHeight
                    width: collapseLabel.implicitWidth

                    Label {
                        id: collapseLabel
                        text: qsTr("Collapse")
                        color: page.brandColor
                        font.pixelSize: Theme.fontSizeMedium
                    }

                    MouseArea {
                        anchors.fill: parent
                        onPressed: {
                            card.cardExpanded = false
                            page.setExpanded(model.sig, false)
                        }
                    }
                }
            }

            // ---------- system / approval line ----------
            Item {
                id: lineItem
                visible: model.view === "line"
                width: parent.width - 2 * parent.mside
                anchors { left: parent.left; top: parent.top; leftMargin: parent.mside }
                implicitHeight: lineText.implicitHeight + 4
                height: implicitHeight

                Text {
                    id: lineText
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width
                    text: model.text
                    color: model.highlight ? page.brandColor : page.mutedColor
                    font.pixelSize: Theme.fontSizeSmall
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }
            }
        }
    }

}