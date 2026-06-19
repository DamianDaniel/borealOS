#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include "systemstatus.h"

int main(int argc, char *argv[]) {
    qputenv("QT_QPA_PLATFORM", "wayland");

    QGuiApplication app(argc, argv);
    QQmlApplicationEngine engine;



    const QUrl url(QStringLiteral("qrc:/qt/qml/qml/main.qml"));
    engine.load(url);

    return app.exec();
}