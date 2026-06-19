import QtQuick
import QtQuick.Window

Window {
    id: root
    visible: true
    width: 1920
    height: 60
    color: "transparent" // Keeps background invisible except for our custom panels
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint

    // Main Top Bar Background
    Rectangle {
        id: topBar
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width * 0.95
        height: 40
        radius: 12
        color: "#AA000000" // Semi-transparent black

        // Left Side: App Indicators
        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 15
            spacing: 10

            Repeater {
                model: 4 // Placeholder for active app count
                Rectangle {
                    width: 24; height: 24; radius: 6; color: "white"
                    Text { text: "🗎"; anchors.centerIn: parent }
                }
            }
        }

        // Right Side: The Dynamic Island / Morphing Status
        Rectangle {
            id: dynamicIsland
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: 15

            // Dynamic width/height based on state
            width: state === "expanded" ? 250 : 150
            height: state === "expanded" ? 200 : 30
            radius: 8
            color: "#33FFFFFF"

            // Handle morphing states
            states: [
                State { name: "collapsed" },
                State { name: "expanded" }
            ]
            state: "collapsed" // Default state

            // Smoothly animate shape changes
            transitions: Transition {
                NumberAnimation { properties: "width,height"; duration: 200; easing.type: Easing.InOutQuad }
            }

            // Click behavior to trigger morphing
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    dynamicIsland.state = (dynamicIsland.state === "collapsed") ? "expanded" : "collapsed"
                }
            }

            // Status Text
            Text {
                anchors.top: parent.top
                anchors.topMargin: 6
                anchors.horizontalCenter: parent.horizontalCenter
                text: dynamicIsland.state === "expanded" ? "Detailed Controls" : "9:14 PM"
                color: "white"
            }
        }
    }
}