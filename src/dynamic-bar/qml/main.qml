import QtQuick
import Quickshell
import org.borealos.components 1.0 // todo: change package name

ShellRoot {
    id: root

    PanelWindow {
        id: topBarWindow
        visible: true
        width: 1920
        height: 60
        color: "transparent"

        anchors {
            top: true
            left: true
            right: true
        }

        SystemStatus {
            id: sysStatus
        }

        // Main Top Bar Background
        Rectangle {
            id: topBar
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width * 0.95
            height: 40
            radius: 12
            color: "#AA000000"

            // Left Side: App Indicators
            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 15
                spacing: 10

                Repeater {
                    model: 4
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

                width: state === "expanded" ? 250 : 150
                height: state === "expanded" ? 200 : 30
                radius: 8
                color: "#33FFFFFF"

                states: [
                    State { name: "collapsed" },
                    State { name: "expanded" }
                ]
                state: "collapsed"

                transitions: Transition {
                    NumberAnimation { properties: "width,height"; duration: 200; easing.type: Easing.InOutQuad }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        dynamicIsland.state = (dynamicIsland.state === "collapsed") ? "expanded" : "collapsed"
                    }
                }


                Text {
                    anchors.top: parent.top
                    anchors.topMargin: 6
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "white"

                    // Uses a JavaScript ternary expression to evaluate which string to display
                    // based on whether the island is expanded or collapsed.
                    text: {
                        if (dynamicIsland.state === "expanded") {
                            // Check if the battery read failed (returns -1)
                            if (sysStatus.batteryLevel === -1) {
                                return "AC Power\n" + sysStatus.currentTime
                            } else {
                                return "Battery: " + sysStatus.batteryLevel + "%\n" + sysStatus.currentTime
                            }
                        } else {
                            // When collapsed, just show the current time string from C++
                            return sysStatus.currentTime
                        }
                    }

                    // Centers multi-line text nicely when expanded
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }
}