import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import org.borealos.components 1.0

ShellRoot {
    PanelWindow {
        id: root
        visible: true
        
        anchors {
            top: true
            left: true
            right: true
        }
        
        height: 60
        color: "transparent"
        
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "BorealDynamicBar"

        SystemStatus {
            id: sysStatus
        }

        // Main Top Bar
        Rectangle {
            id: topBar
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 40
            radius: 12
            color: "#AA000000"

            // Task Bar (Left/Center Side)
            Row {
                id: taskBar
                anchors.left: parent.left
                anchors.leftMargin: 15
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10

                Repeater {
                    model: ToplevelManager.toplevels
                    delegate: Rectangle {
                        width: 120
                        height: 30
                        radius: 6
                        color: modelData.activated ? "#66FFFFFF" : "#33FFFFFF"

                        Row {
                            anchors.fill: parent
                            anchors.margins: 5
                            spacing: 5
                            
                            Image {
                                source: modelData.icon || ""
                                width: 20
                                height: 20
                                anchors.verticalCenter: parent.verticalCenter
                                visible: modelData.icon && modelData.icon.toString() !== ""
                            }

                            Text {
                                text: modelData.title
                                color: "white"
                                width: (modelData.icon && modelData.icon.toString() !== "") ? parent.width - (parent.spacing + 20) : parent.width - 5
                                elide: Text.ElideRight
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.RightButton) {
                                    modelData.close();
                                } else {
                                    modelData.activate();
                                }
                            }
                        }
                    }
                }
            }

            // Right Side
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

                    text: {
                        if (dynamicIsland.state === "expanded") {
                            if (sysStatus.batteryLevel === -1) {
                                return "AC Power\n" + sysStatus.currentTime
                            } else {
                                return "Battery: " + sysStatus.batteryLevel + "%\n" + sysStatus.currentTime
                            }
                        } else {
                            return sysStatus.currentTime
                        }
                    }

                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }
}
