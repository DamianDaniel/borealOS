#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include "systemstatus.h"

int main(int argc, char *argv[]) {
    qputenv("QT_QPA_PLATFORM", "wayland");

    QGuiApplication app(argc, argv);
    QQmlApplicationEngine engine;

    // Quickshell is typically run using the 'qs' or 'quickshell' command.
    // To support running this application as a standalone executable while
    // using Quickshell types, the Quickshell QML plugin must be available
    // in the QML import path.

    const QUrl url(QStringLiteral("qrc:/org/borealos/components/qml/main.qml"));

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl)
            QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);

    engine.load(url);

    return app.exec();
}