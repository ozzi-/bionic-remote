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
    property bool approvalSending: false
    property string approvalStatus: ""

    // Expanded state survives model rebuilds, keyed by entry signature.
    property var expandedSigs: ({})

    ListModel { id: entryModel }

    // Choice buttons for a pending approval (value + label), populated from
    // the bridge's pendingApproval.choices on each transcript refresh.
    ListModel { id: choiceModel }

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
    // User bubble: dark purple + white text in BOTH themes — deliberately
    // distinct from the assistant's neutral-gray bubble so it's obvious who
    // is who at a glance.
    property color userBubbleColor: "#4A2E63"
    property color userTextColor: "#FFFFFF"
    property color assistBubbleColor: darkMode ? "#202024" : "#F0F0F1"
    property color cardBgColor: darkMode ? "#1F1F23" : "#F5F5F6"
    property color cardBorderColor: darkMode ? "#3A3A41" : "#D9D9DE"
    property color brandColor: "#7171E8"

    // A Silica Button's natural height in this theme (~122 px measured on the
    // 1088x2260 stack) plus a small gap. NOTE: `Theme.controlHeight` does NOT
    // exist on this Qt 5.6 / Silica stack (not in the skill's verified-present
    // Theme list), so `Theme.controlHeight + n` evaluates to NaN and any row
    // math on it collapses — use this fixed constant instead.
    readonly property int buttonRowH: 136

    // ---------------- helpers ----------------

    function formatDuration(ms) {
        var s = Math.floor(Number(ms || 0) / 1000)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        if (h > 0)
            return h + "h " + m + "m"
        if (m > 0)
            return m + "m " + sec + "s"
        return sec + "s"
    }

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
                items.push({ "view": "user", "text": e.text || "", "html": e.html || "" })
                i++
                continue
            }
            if (kind === "assistant") {
                // Bionic's entry order stores the assistant reply FIRST and the
                // reasoning (thinking) right after it, so the thinking would
                // render below the reply. Bionic's convention (and the user)
                // wants thinking ABOVE the reply → emit the leading reasoning
                // card(s) before the assistant bubble, then consume them.
                var j = i + 1
                var lead = []
                while (j < entries.length && entries[j].kind === "reasoning") {
                    lead.push(entries[j].text || "")
                    j++
                }
                for (var r = 0; r < lead.length; r++) {
                    items.push({ "view": "thinking", "text": lead[r],
                                 "sig": "th|" + i + "|" + r + "|" + String(lead[r]).slice(0, 32) })
                }
                items.push({ "view": "assistant", "text": e.text || "", "html": e.html || "" })
                i = j
                continue
            }
            if (kind === "compacted") {
                // Expandable card: summary text (markdown) + "worked for" line.
                items.push({
                    "view": "compacted",
                    "text": e.summary || "",
                    "html": e.summaryHtml || "",
                    "subline": e.workedForMs ? formatDuration(e.workedForMs) : "",
                    "sig": "cp|" + i + "|" + String(e.summary || "").slice(0, 32)
                })
                i++
                continue
            }
            if (kind === "approval") {
                var title = e.title || qsTr("Approval")
                var desc = e.description || ""
                if (e.answered) {
                    items.push({ "view": "line",
                                 "text": title + (desc !== "" ? " — " + desc : "")
                                        + " — " + qsTr("answered"),
                                 "highlight": false })
                } else {
                    // Pending approval → interactive card in the CONTENT list
                    // (not the header). The header does not reflow to fit
                    // dynamically-appearing children on this Qt 5.6 stack, so the
                    // buttons must live where per-item height is explicit.
                    items.push({ "view": "approval",
                                 "title": title,
                                 "desc": desc,
                                 "sig": "ap|" + i })
                }
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

    function sendApproval(choice) {
        if (page.approvalSending || choice === "")
            return
        page.approvalSending = true
        page.approvalStatus = qsTr("Sending to Bionic…")
        client.approveChoice(page.projectId, page.sessionId, choice)
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
            choiceModel.clear()
            if (ap) {
                page.approvalTitle = ap.title || ""
                page.approvalDesc = ap.description || ""
                var cs = ap.choices || []
                for (var ci = 0; ci < cs.length; ci++) {
                    var cv = cs[ci]
                    choiceModel.append({ "value": cv.value || "",
                                         "label": cv.label || cv.value || "" })
                }
            } else {
                page.approvalTitle = ""
                page.approvalDesc = ""
            }
            if (!page.approvalSending)
                page.approvalStatus = ""
            var entries = data.entries || []
            var items = page.buildItems(entries)
            entryModel.clear()
            for (var i = 0; i < items.length; i++) {
                var it = items[i]
                entryModel.append({
                    "view": it.view,
                    "text": it.text || "",
                    "html": it.html || "",
                    "subline": it.subline || "",
                    "count": it.count || 0,
                    "sig": it.sig || "",
                    "highlight": it.highlight === true,
                    "expanded": (it.sig !== "" && page.expandedSigs[it.sig] === true),
                    "title": it.title || "",
                    "desc": it.desc || ""
                })
            }
        }

        onApproveResult: {
            page.approvalSending = false
            if (ok) {
                page.approvalStatus = qsTr("Sent to Bionic.")
                page.refresh()
            } else {
                page.approvalStatus = error !== "" ? error : qsTr("Failed")
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

        // `header` is a real SilicaListView (ListView) property — the header
        // Column reserves space at the top of the content. (Flickable has no
        // such property; assigning `header:` there kills page loading.)
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

            // NOTE: the pending-approval card is rendered in the CONTENT list
            // below (the `approval` delegate), not in this header. The
            // SilicaListView header does not reflow to fit dynamically-appearing
            // children on this Qt 5.6 stack, so a header banner never showed the
            // choice buttons. Keep only the PageHeader here.
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
                   : (model.view === "thinking" || model.view === "toolgroup"
                      || model.view === "compacted")
                     ? card.implicitHeight + 8
                     : (model.view === "approval"
                        ? approvalCard.implicitHeight + 12
                        : lineItem.implicitHeight + 10)

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
                    // Markdown rendered by the bridge as Qt-RichText-compatible HTML.
                    text: model.html !== "" ? model.html : model.text
                    textFormat: model.html !== "" ? Text.RichText : Text.PlainText
                    color: page.userTextColor
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
                    // Markdown rendered by the bridge as Qt-RichText-compatible HTML.
                    text: model.html !== "" ? model.html : model.text
                    textFormat: model.html !== "" ? Text.RichText : Text.PlainText
                    color: page.fgColor
                    font.pixelSize: Theme.fontSizeLarge
                    wrapMode: Text.Wrap
                }
            }

            // ---------- thinking / toolgroup card ----------
            Item {
                id: card
                visible: model.view === "thinking" || model.view === "toolgroup" || model.view === "compacted"
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
                    implicitHeight: Math.max(headerLabel.implicitHeight + 4
                                             + (sublineLabel.visible ? sublineLabel.implicitHeight + 2 : 0),
                                             expandBtn.height)
                    height: implicitHeight

                    Label {
                        id: headerLabel
                        anchors.left: parent.left
                        // Leave room for the toggle button on the right.
                        width: parent.width - 190
                        // Qt 5.6: qsTr() returns a QVariant — bare qsTr and string
                        // concatenation are safe, but calling methods on it (or
                        // wrapping in String()) throws and the label renders empty.
                        // Uppercase literals + concatenation = the proven pattern.
                        text: model.view === "thinking"
                             ? qsTr("THINKING")
                             : (model.view === "compacted" ? qsTr("COMPACTED")
                             : (model.count === 1 ? qsTr("1 TOOL CALL")
                                                  : model.count + " " + qsTr("TOOL CALLS")))
                        color: page.mutedColor
                        font.pixelSize: Theme.fontSizeSmall
                        font.letterSpacing: 0.03
                        elide: Text.ElideRight
                    }

                    Label {
                        id: sublineLabel
                        anchors { left: parent.left; top: headerLabel.bottom; topMargin: 2 }
                        width: parent.width - 190
                        text: model.subline !== "" ? qsTr("Worked for ") + model.subline : ""
                        visible: model.subline !== ""
                        color: page.mutedColor
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                    }

                    // Expand / Collapse toggle. MUST be a Silica Button, not a
                    // MouseArea: Silica's Button runs a DragFilter that hands a
                    // drag back to the list (onCanceled / preventStealing), so a
                    // flick that STARTS on the button still scrolls. A plain
                    // MouseArea grabs the touch — that is exactly why the old
                    // whole-card MouseArea made scrolling impossible (every
                    // scroll starting on a card toggled it instead).
                    Button {
                        id: expandBtn
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        width: 200
                        height: 64
                        text: card.cardExpanded ? qsTr("Collapse") : qsTr("Expand")
                        color: page.brandColor
                        onClicked: {
                            card.cardExpanded = !card.cardExpanded
                            page.setExpanded(model.sig, card.cardExpanded)
                        }
                    }

                }

                Text {
                    id: cardContent
                    visible: card.cardExpanded && (model.text !== "" || model.html !== "")
                    anchors {
                        left: parent.left
                        top: headerRow.bottom
                        topMargin: parent.cardPad
                        leftMargin: parent.cardPad
                    }
                    width: parent.width - 2 * parent.cardPad
                    // Compaction summaries are real content the user came to read →
                    // full foreground color; thinking/tool output stays muted.
                    text: model.html !== "" ? model.html : model.text
                    textFormat: model.html !== "" ? Text.RichText : Text.PlainText
                    color: model.view === "compacted" ? page.fgColor : page.mutedColor
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
                    implicitHeight: collapseBtn.height
                    height: implicitHeight
                    width: collapseBtn.width

                    // Real Button (see expandBtn above for why not a MouseArea).
                    Button {
                        id: collapseBtn
                        anchors.left: parent.left
                        width: 200
                        height: 64
                        text: qsTr("Collapse")
                        color: page.brandColor
                        onClicked: {
                            card.cardExpanded = false
                            page.setExpanded(model.sig, false)
                        }
                    }
                }

                // NOTE: the card body is deliberately NOT a tap target. Toggling
                // happens only via the expandBtn (header) and collapseBtn
                // (bottom) Buttons, so a touch anywhere else on the card —
                // including the start of a scroll — passes through to the list.
                // Do not re-add a whole-card MouseArea: it grabs the touch and
                // every scroll gesture starting on the card toggles the card
                // instead of scrolling (reported on phone, 0.1.0-12).
            }

            // ---------- approval card (interactive approve / deny) ----------
            // Lives in the CONTENT list with an explicit per-item height; the
            // choice buttons are laid out by index inside a plain Item.
            // ROOT CAUSE of the earlier blank button area: `Theme.controlHeight`
            // does NOT exist on this Qt 5.6 / Silica stack, so `Theme.\
            // controlHeight + n` collapsed to NaN and pushed buttons 2..N off-screen
            // (y = INT_MIN / 2*INT_MIN). Row height therefore uses the fixed
            // page.buttonRowH constant — never `Theme.controlHeight`.
            Item {
                id: approvalCard
                visible: model.view === "approval"
                width: parent.width - 2 * parent.mside
                anchors { left: parent.left; top: parent.top; leftMargin: parent.mside }

                property int apPad: 12
                readonly property int rowCount: choiceModel.count
                implicitHeight: apTitle.implicitHeight + 6
                               + (apDesc.visible ? apDesc.implicitHeight + 10 : 0)
                               + (rowCount > 0 ? rowCount * apCol.rowH : 0)
                               + (apStatus.visible ? apStatus.implicitHeight + 10 : 0)
                               + apPad * 2
                height: implicitHeight

                Rectangle {
                    anchors.fill: parent
                    radius: 12
                    color: page.darkMode ? "#26262E" : "#ECECF6"
                    border.color: page.brandColor
                    border.width: 1
                }

                // Vertical stack of title / desc / buttons / status, positioned
                // by running offsets (no Column, which is where the Repeater
                // failed to lay out).
                Item {
                    id: apCol
                    anchors { left: parent.left; top: parent.top; leftMargin: parent.apPad; topMargin: parent.apPad }
                    width: parent.width - 2 * parent.apPad
                    readonly property int rowH: page.buttonRowH

                    Label {
                        id: apTitle
                        width: parent.width
                        text: qsTr("Approval pending: ") + model.title
                        wrapMode: Text.Wrap
                        color: page.fgColor
                        font.pixelSize: Theme.fontSizeLarge
                    }

                    Label {
                        id: apDesc
                        anchors { left: parent.left; top: apTitle.bottom; topMargin: 6 }
                        width: parent.width
                        visible: model.desc !== ""
                        text: model.desc
                        wrapMode: Text.Wrap
                        color: page.mutedColor
                        font.pixelSize: Theme.fontSizeMedium
                    }

                    Item {
                        id: apButtons
                        anchors { left: parent.left; top: (apDesc.visible ? apDesc.bottom : apTitle.bottom); topMargin: 10 }
                        width: parent.width
                        height: choiceModel.count * apCol.rowH
                        visible: choiceModel.count > 0

                        Repeater {
                            model: choiceModel
                            delegate: Button {
                                width: parent.width
                                // Do NOT set `height: Theme.controlHeight` — that
                                // constant does not exist on this stack; leave the
                                // button at its natural implicitHeight.
                                anchors { left: parent.left; top: parent.top; topMargin: index * apCol.rowH }
                                text: model.label
                                enabled: !page.approvalSending
                                onClicked: page.sendApproval(model.value)
                            }
                        }
                    }

                    Label {
                        id: apStatus
                        anchors { left: parent.left; top: apButtons.bottom; topMargin: 10 }
                        width: parent.width
                        visible: page.approvalStatus !== ""
                        text: page.approvalStatus
                        color: page.brandColor
                        font.pixelSize: Theme.fontSizeMedium
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